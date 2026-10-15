import AppKit
import Foundation
import os

/// Mirrors install.sh: the prebuilt release asset, else a source build of the same tag.
/// With the daily check off, Burn only touches the network when the user clicks Check now.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "JRaunak/burn"
    nonisolated static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(repo)/master/install.sh | bash"

    enum Phase: Equatable {
        case idle, checking, current
        case checkFailed(String)
        case available(String)
        case downloading(String, Bytes)
        case source(String, Bytes)
        case compiling(String, Step?)
        case assembling(String), installing(String)
        case failed(String, String)
        case relaunchFailed(String)
    }

    struct Bytes: Equatable {
        var received: Int64 = 0
        var expected: Int64?
    }

    /// swift build's total grows while it plans (21, 22, then 139), so the bar waits until two steps agree on it.
    struct Step: Equatable {
        let n, m: Int
        let stable: Bool

        var fraction: Double? { stable && m > 0 ? min(Double(n) / Double(m), 1) : nil }
    }

    enum Event: Sendable { case bytes(Int64, Int64?), compiling, step(Int, Int), assembling }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var checked = UserDefaults.standard.object(forKey: "update.checked") as? Date
    /// Why the prebuilt download failed, shown as help while the source fallback runs.
    @Published private(set) var prebuiltError: String?
    @Published var daily = UserDefaults.standard.bool(forKey: "update.daily") {
        didSet {
            UserDefaults.standard.set(daily, forKey: "update.daily")
            schedule()
        }
    }
    private var scheduler: NSBackgroundActivityScheduler?
    private var job: Task<Void, Never>?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var busy: Bool {
        switch phase {
        case .checking, .downloading, .source, .compiling, .assembling, .installing: true
        default: false
        }
    }

    var caption: String {
        Self.caption(phase, installed: LoginItem.installed, checked: checked, prebuiltFailed: prebuiltError != nil)
    }

    func start() { schedule() }

    /// The system picks the moment, so there's no timer of Burn's own, and launch catches up on a missed day.
    private func schedule() {
        scheduler?.invalidate()
        scheduler = nil
        guard daily else { return }
        let s = NSBackgroundActivityScheduler(identifier: "local.burn.update")
        s.repeats = true
        s.interval = 24 * 3600
        s.tolerance = 3600
        s.schedule { done in
            Task { @MainActor in
                await Updater.shared.checkIfDue()
                done(.finished)
            }
        }
        scheduler = s
        Task { await checkIfDue() }
    }

    private func checkIfDue() async {
        if daily, (checked ?? .distantPast).timeIntervalSinceNow < -20 * 3600 { await check() }
    }

    func check() async {
        guard !busy else { return }
        phase = .checking
        do {
            let tag = try await Self.latestTag()
            checked = Date()
            UserDefaults.standard.set(checked, forKey: "update.checked")
            phase = Self.isNewer(tag, than: version) ? .available(tag) : .current
        } catch {
            phase = .checkFailed(error.localizedDescription)
        }
    }

    func update(to tag: String) {
        guard !busy, LoginItem.installed else { return }
        prebuiltError = nil
        job = Task { await perform(tag) }
    }

    func cancel() { job?.cancel() }

    private func perform(_ tag: String) async {
        let target = Bundle.main.bundleURL
        let report: @Sendable (Event) -> Void = { [weak self] e in Task { @MainActor in self?.apply(e) } }
        do {
            // On the target's volume, so the swap is a rename.
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let app = try await fetch(tag, in: work, report: report)
            phase = .installing(tag)
            try Self.install(app, over: target)
        } catch {
            phase = Task.isCancelled ? .available(tag) : .failed(tag, error.localizedDescription)
            return
        }
        do { try Self.relaunch(target) } catch { phase = .relaunchFailed(tag) }
    }

    private func fetch(_ tag: String, in work: URL, report: @escaping @Sendable (Event) -> Void) async throws -> URL {
        #if arch(arm64)
        phase = .downloading(tag, Bytes())
        do { return try await Self.prebuilt(tag, in: work, report: report) } catch where !Task.isCancelled {
            prebuiltError = error.localizedDescription
        }
        #endif
        phase = .source(tag, Bytes())
        do { return try await Self.fromSource(tag, in: work, report: report) } catch where !Task.isCancelled {
            throw Failure(prebuiltError.map { "download: \($0); source build: \(error.localizedDescription)" } ?? error.localizedDescription)
        }
    }

    /// Events can arrive after the step they belong to; any that don't fit the current phase are dropped.
    private func apply(_ e: Event) {
        switch (phase, e) {
        case let (.downloading(t, _), .bytes(r, x)): phase = .downloading(t, Bytes(received: r, expected: x))
        case let (.source(t, _), .bytes(r, x)): phase = .source(t, Bytes(received: r, expected: x))
        case let (.source(t, _), .compiling): phase = .compiling(t, nil)
        case let (.compiling(t, s), .step(n, m)): phase = .compiling(t, Self.advance(s, n, m))
        case let (.compiling(t, _), .assembling): phase = .assembling(t)
        default: break
        }
    }

    // MARK: Text

    nonisolated static func caption(_ phase: Phase, installed: Bool, checked: Date?, prebuiltFailed: Bool, now: Date = Date()) -> String {
        let last = checked.map { "Last checked \(lastChecked($0, now: now))" }
        switch phase {
        case .idle: return last ?? "Not checked yet"
        case .checking: return "Checking…"
        case .current: return last.map { "Up to date. \($0)" } ?? "Up to date"
        case .checkFailed(let e): return "Couldn't check for updates: \(e)"
        case .available(let t):
            return installed ? "\(t) is available" : "\(t) is available. Only a copy in Applications can update itself."
        case let .downloading(t, b):
            let size = b.expected.map { "\(bytes(b.received)) of \(bytes($0))" } ?? bytes(b.received)
            return "Downloading \(t), \(size)"
        case let .source(t, b): return "\(prebuiltFailed ? "Download failed. " : "")Getting \(t) source, \(bytes(b.received))"
        case let .compiling(t, s): return s.map { "Compiling \(t), step \($0.n) of \($0.m)" } ?? "Compiling \(t)"
        case .assembling: return "Assembling Burn.app"
        case .installing(let t): return "Installing \(t)…"
        case let .failed(_, reason): return "Update failed: \(reason)"
        case .relaunchFailed(let t): return "Updated to \(t). Quit and reopen Burn to finish."
        }
    }

    nonisolated static func lastChecked(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated static func bytes(_ n: Int64) -> String { n.formatted(.byteCount(style: .file, spellsOutZero: false)) }

    nonisolated static func advance(_ s: Step?, _ n: Int, _ m: Int) -> Step {
        Step(n: n, m: m, stable: s?.m == m)
    }

    /// swift build prints "[28/139]" per step when its output isn't a terminal; Swift 6.4 puts thin spaces round the slash.
    nonisolated static func step(_ line: Substring) -> (Int, Int)? {
        guard let m = line.prefixMatch(of: #/\[(\d+)\s*/\s*(\d+)\]/#), let n = Int(m.1), let of = Int(m.2) else { return nil }
        return (n, of)
    }

    /// Moves every complete line out of rest, which keeps the unfinished tail between chunks.
    nonisolated static func lines(_ rest: inout Data, adding chunk: Data) -> [Substring] {
        rest.append(chunk)
        guard let end = rest.lastIndex(where: { $0 == 10 || $0 == 13 }) else { return [] }
        let text = String(decoding: rest[..<end], as: UTF8.self)
        rest.removeSubrange(..<rest.index(after: end))
        return text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
    }

    // MARK: Steps

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// releases/latest redirects to .../releases/tag/<tag>.
    nonisolated static func tag(fromLocation location: String) -> String? {
        guard let parts = URL(string: location)?.pathComponents, let i = parts.firstIndex(of: "tag"),
              i > 0, parts[i - 1] == "releases", i + 1 < parts.count, numbers(parts[i + 1]) != nil else { return nil }
        return parts[i + 1]
    }

    nonisolated static func numbers(_ version: String) -> [Int]? {
        let parts = version.drop { $0 == "v" }.split(separator: ".", omittingEmptySubsequences: false)
        let n = parts.compactMap { Int($0) }
        return n.isEmpty || n.count != parts.count ? nil : n
    }

    nonisolated static func isNewer(_ tag: String, than version: String) -> Bool {
        guard var a = numbers(tag), var b = numbers(version) else { return false }
        let n = max(a.count, b.count)
        a += Array(repeating: 0, count: n - a.count)
        b += Array(repeating: 0, count: n - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    nonisolated static func latestTag() async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/\(repo)/releases/latest")!)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect())
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let tag = tag(fromLocation: location) else { throw Failure("GitHub didn't point to a release") }
        return tag
    }

    nonisolated static func prebuilt(_ tag: String, in work: URL, report: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> URL {
        let archive = work.appendingPathComponent("Burn.tar.gz"), dir = work.appendingPathComponent("prebuilt")
        try await download("https://github.com/\(repo)/releases/download/\(tag)/Burn.tar.gz", to: archive, report: report)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", dir.path], log: work)
        let app = dir.appendingPathComponent("Burn.app")
        try verify(app, tag: tag)
        return app
    }

    nonisolated static func fromSource(_ tag: String, in work: URL, report: @escaping @Sendable (Event) -> Void = { _ in }) async throws -> URL {
        do { try await run("/usr/bin/xcode-select", ["-p"], log: work) } catch {
            throw Failure("it needs the Command Line Tools: xcode-select --install")
        }
        let archive = work.appendingPathComponent("source.tar.gz"), src = work.appendingPathComponent("src")
        try await download("https://codeload.github.com/\(repo)/tar.gz/refs/tags/\(tag)", to: archive, report: report)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", src.path, "--strip-components", "1"], log: work)
        report(.compiling)
        let throttle = Throttle()
        try await run("/bin/bash", [src.appendingPathComponent("build.sh").path], log: work,
                      env: ["BURN_VERSION": String(tag.drop { $0 == "v" })]) { line in
            if line.contains("Build complete!") {
                report(.assembling)
            } else if let (n, m) = step(line), throttle.ready() {
                report(.step(n, m))
            }
        }
        let app = src.appendingPathComponent("build/Burn.app")
        try verify(app, tag: tag)
        return app
    }

    nonisolated static func verify(_ app: URL, tag: String) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Failure("no Burn.app in the download") }
        guard info["CFBundleIdentifier"] as? String == "local.burn" else { throw Failure("the downloaded app isn't Burn") }
        let got = info["CFBundleShortVersionString"] as? String ?? "?"
        guard got == String(tag.drop { $0 == "v" }) else { throw Failure("the downloaded app is v\(got), not \(tag)") }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Burn").path)
        else { throw Failure("the downloaded app has no executable") }
    }

    nonisolated static func install(_ app: URL, over target: URL) throws {
        let paths = [app.path] + (FileManager.default.subpaths(atPath: app.path) ?? []).map { app.path + "/" + $0 }
        for p in paths { removexattr(p, "com.apple.quarantine", XATTR_NOFOLLOW) }
        _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
    }

    /// The shell outlives Burn and opens the new bundle once this process is gone; open would
    /// otherwise just activate the exiting one.
    static func relaunch(_ app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", "\(ProcessInfo.processInfo.processIdentifier)", app.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private nonisolated static func download(_ url: String, to file: URL, report: @escaping @Sendable (Event) -> Void) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: URL(string: url)!, delegate: Watch(report))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure("\(URL(string: url)?.host ?? url) returned \(code)") }
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    /// Output is drained as it arrives because a full pipe would stall build.sh; the log's last line is the error.
    /// Cancelling signals the whole process group, since bash alone would leave swift build running.
    nonisolated static func run(_ tool: String, _ args: [String], log dir: URL, env: [String: String] = [:],
                                line: (@Sendable (Substring) -> Void)? = nil) async throws {
        let log = dir.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.standardOutput = pipe
        p.standardError = pipe
        let rest = OSAllocatedUnfairLock(initialState: Data())
        // The status is read once both the process and its output have ended, so the log is complete.
        let ended = DispatchGroup()
        ended.enter()
        ended.enter()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            guard !chunk.isEmpty else {
                h.readabilityHandler = nil
                return ended.leave()
            }
            try? out.write(contentsOf: chunk)
            guard let line else { return }
            for l in rest.withLock({ lines(&$0, adding: chunk) }) { line(l) }
        }
        p.terminationHandler = { _ in ended.leave() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                ended.notify(queue: .global()) {
                    try? out.close()
                    guard p.terminationStatus != 0 else { return c.resume() }
                    let last = (try? String(contentsOf: log, encoding: .utf8))?
                        .split(separator: "\n").last.map(String.init) ?? ""
                    c.resume(throwing: Failure("\((tool as NSString).lastPathComponent) exited \(p.terminationStatus): \(last)"))
                }
                do {
                    try p.run()
                    // Process puts the child in a group of its own, so this can't reach Burn.
                    if Task.isCancelled { killpg(p.processIdentifier, SIGTERM) }
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    c.resume(throwing: error)
                }
            }
        } onCancel: {
            if p.processIdentifier > 0 { killpg(p.processIdentifier, SIGTERM) }
        }
    }
}

/// Caps progress updates at ten a second so the main actor stays mostly idle.
private struct Throttle: Sendable {
    private let last = OSAllocatedUnfairLock(initialState: UInt64(0))

    func ready() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return last.withLock {
            guard now &- $0 >= 100_000_000 else { return false }
            $0 = now
            return true
        }
    }
}

/// The async download call has no progress of its own, so this observes the task it creates.
/// Its progress object counts percent, not bytes, so the byte counters are watched instead.
private final class Watch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Updater.Event) -> Void
    let throttle = Throttle()
    // Set once in didCreateTask, before any bytes arrive, and kept until the task releases its delegate.
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @Sendable (Updater.Event) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.observe(\.countOfBytesReceived) { [report, throttle] t, _ in
            let expected = t.countOfBytesExpectedToReceive
            if throttle.ready() { report(.bytes(t.countOfBytesReceived, expected > 0 ? expected : nil)) }
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
