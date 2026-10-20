import CoreServices
import Foundation

final class TranscriptSource: UsageSource {
    let id = Sources.transcripts
    @Locked private(set) var lastError: String?
    @Locked private(set) var scanning = false

    private let db: DB
    let endpoints = Endpoints()
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let queue = DispatchQueue(label: "burn.transcripts", qos: .utility)
    private var stream: FSEventStreamRef?
    private var onChange: () -> Void = {}

    init(db: DB) { self.db = db }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        queue.async { self.scanAll() }
        watch()
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    func rescanFromZero() {
        queue.async {
            self.db.queue.sync { _ = try? self.db.run("DELETE FROM files") }
            self.scanAll()
        }
    }

    private func watch() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let me = Unmanaged<TranscriptSource>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let changed = list.prefix(count).filter { $0.hasSuffix(".jsonl") }
            guard !changed.isEmpty else { return }
            var any = false
            for p in Set(changed) { any = me.ingest(URL(fileURLWithPath: p)) || any }
            if any { me.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else {
            lastError = "Couldn't watch \(root.path)"
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func scanAll() {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        // Only a scan with nothing stored yet shows as indexing; a launch-time catch-up is quick.
        scanning = db.queue.sync { (try? db.run("SELECT COUNT(*) FROM files"))?.first?.int(0) ?? 0 } == 0
        if scanning { onChange() }
        defer { scanning = false; onChange() }
        for case let url as URL in e where url.pathExtension == "jsonl" { ingest(url) }
        // The first full scan leaves hundreds of MB of freed large blocks cached by malloc.
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Reads whatever was appended since the stored offset. Returns true if rows were written.
    @discardableResult
    func ingest(_ url: URL) -> Bool {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.intValue else { return false }

        let stored = db.queue.sync { (try? db.run("SELECT inode, offset FROM files WHERE path=?", [path]))?.first }
        var offset = 0
        if let s = stored, s.int(0) == inode, s.int(1) <= size { offset = s.int(1) }
        guard offset < size, let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }

        let isSubagentFile = path.contains("/subagents/")
        let projectDir = projectDir(of: url)
        var rows: [UsageRow] = []
        var carry = Data()
        var consumed = offset
        do {
            try fh.seek(toOffset: UInt64(offset))
            while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
                carry.append(chunk)
                guard let nl = carry.lastIndex(of: 0x0A) else { continue }
                let complete = carry[carry.startIndex...nl]
                for line in complete.split(separator: 0x0A) {
                    if let r = parse(Data(line), subagentFile: isSubagentFile, projectDir: projectDir) {
                        rows.append(r)
                    }
                }
                consumed += complete.count
                carry = Data(carry[carry.index(after: nl)...])
            }
        } catch {
            lastError = "\(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }

        db.queue.sync {
            do {
                try db.transaction {
                    try db.store(rows)
                    for r in rows where !r.session.isEmpty {
                        try db.run("""
                        INSERT INTO sessions(id,project,first_ts,last_ts) VALUES(?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET project=excluded.project, first_ts=MIN(first_ts,excluded.first_ts), last_ts=MAX(last_ts,excluded.last_ts)
                        """, [r.session, r.project, r.ts, r.ts])
                    }
                    // Telemetry can arrive before its session's transcript, or have copied a since-corrected name.
                    for (session, project) in Dictionary(rows.lazy.filter { !$0.session.isEmpty }.map { ($0.session, $0.project) }, uniquingKeysWith: { a, _ in a }) {
                        try db.run("UPDATE messages SET project=? WHERE source='otel' AND session=?", [project, session])
                    }
                    try db.run("""
                    INSERT INTO files(path,inode,offset) VALUES(?,?,?)
                    ON CONFLICT(path) DO UPDATE SET inode=excluded.inode, offset=excluded.offset
                    """, [path, inode, consumed])
                }
            } catch {
                lastError = "\(url.lastPathComponent): \(error)"
            }
        }
        return !rows.isEmpty
    }

    private static let usageMarker = Data("\"usage\"".utf8)
    private static let costStateMarker = Data("\"type\":\"cost-state\"".utf8)
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)

    private func parse(_ line: Data, subagentFile: Bool, projectDir: String) -> UsageRow? {
        // cost-state is the one place transcripts name the full Bedrock profile, e.g. us.anthropic.claude-opus-5-5[1m].
        if line.range(of: Self.costStateMarker) != nil,
           let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           let usage = d["modelUsage"] as? [String: Any] {
            usage.keys.forEach(endpoints.learn)
            return nil
        }
        guard line.range(of: Self.usageMarker) != nil, line.range(of: Self.assistantMarker) != nil,
              let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              d["type"] as? String == "assistant",
              let m = d["message"] as? [String: Any],
              let mid = m["id"] as? String,
              let u = m["usage"] as? [String: Any],
              let model = m["model"] as? String, model != "<synthetic>",
              let ts = (d["timestamp"] as? String).flatMap(parseISO) else { return nil }

        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        return UsageRow(
            id: "cc:" + mid,
            source: id,
            session: d["sessionId"] as? String ?? d["session_id"] as? String ?? "",
            project: Self.project(cwd: d["cwd"] as? String ?? "", projectDir: projectDir),
            model: normalizeModel(model),
            ts: ts,
            sidechain: subagentFile || (d["isSidechain"] as? Bool ?? false),
            agent: d["attributionAgent"] as? String ?? d["agentId"] as? String ?? "",
            input: n("input_tokens"),
            output: n("output_tokens"),
            cacheWrite: n("cache_creation_input_tokens"),
            // Lines without the cache_creation breakdown count every write as 5-minute.
            cacheWrite1h: ((u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? NSNumber)?.intValue ?? 0,
            cacheRead: n("cache_read_input_tokens"),
            requestID: d["requestId"] as? String,
            premium: endpoints.premium(provider: Endpoints.provider(messageID: mid), model: model, geo: u["inference_geo"] as? String)
        )
    }

    /// The top-level directory under `root`, which Claude Code names after the session's launch directory.
    private func projectDir(of url: URL) -> String {
        var dir = url.deletingLastPathComponent()
        while dir.deletingLastPathComponent().path != root.path, dir.path.count > root.path.count {
            dir = dir.deletingLastPathComponent()
        }
        return dir.lastPathComponent
    }

    /// The launch directory's name: the cwd or its ancestor that encodes to `projectDir`, every character
    /// outside [A-Za-z0-9] becoming "-". Otherwise "-Users-me-Desktop-Burn" gives "Burn", lossy for names with "-".
    static func project(cwd: String, projectDir: String) -> String {
        let path = Array(cwd.utf16), dir = Array(projectDir.utf16)
        func encoded(_ c: UInt16) -> UInt16 { c < 128 && isalnum(Int32(c)) != 0 ? c : 0x2D }
        if path.count >= dir.count, path.count == dir.count || path[dir.count] == 0x2F,
           zip(path, dir).allSatisfy({ encoded($0) == $1 }),
           let name = String(decoding: path[..<dir.count], as: UTF16.self).split(separator: "/").last {
            return String(name)
        }
        return projectDir.split(separator: "-").last.map(String.init) ?? projectDir
    }
}
