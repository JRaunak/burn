import Foundation

struct UsageRow {
    var id: String
    var source: String
    var session = ""
    var project = ""
    var model: String
    var ts: Double
    var sidechain = false
    var agent = ""
    var input = 0
    var output = 0
    /// All cache writes; `cacheWrite1h` of them were 1-hour writes, the rest 5-minute.
    var cacheWrite = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var requestID: String?
    /// Set only when the source itself reports USD (OpenTelemetry). Otherwise cost comes from `prices`.
    var cost: Double?
    /// Served from a regional or US-only endpoint, which costs pricing.json's regionalPremium more.
    var premium = false
}

/// Status a source writes on its own queue and the refresh queue and views read.
@propertyWrapper
final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(wrappedValue: T) { value = wrappedValue }
    var wrappedValue: T {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

protocol UsageSource: AnyObject {
    var id: String { get }
    var lastError: String? { get }
    /// `onChange` is called off the main thread after new rows land.
    func start(onChange: @escaping () -> Void)
    func stop()
}

enum Sources {
    static let transcripts = "transcripts"
    static let otel = "otel"

    static let caveat = "Every transcript request, plus the telemetry requests no transcript holds, which are the calls Claude Code doesn't write to transcripts."

    /// Every transcript row plus the telemetry rows not merged into one (see `DB.merge`).
    static let clause = "(m.source = 'transcripts' OR (m.source = 'otel' AND m.partner IS NULL))"
}

extension DB {
    /// Largest telemetry-after-transcript gap seen on request-id pairs was 67 s, the median 1.3 s.
    static let matchWindow = 120.0

    /// Upserts, then merges each touched row with its counterpart from the other source.
    func store(_ rows: [UsageRow]) throws {
        var seen = Set<String>()
        for r in rows { try upsert(r) }
        for r in rows where seen.insert(r.id).inserted { try merge(r.id) }
    }

    /// Streaming writes repeat a message id while output_tokens grows, so keep the largest.
    private func upsert(_ r: UsageRow) throws {
        try run("""
        INSERT INTO messages(id,source,session,project,model,ts,sidechain,agent,input,output,cache_write,cache_write_1h,cache_read,cost,premium,request_id)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            project = excluded.project,
            output = MAX(messages.output, excluded.output),
            cache_write_1h = excluded.cache_write_1h,
            cost = COALESCE(excluded.cost, messages.cost),
            premium = excluded.premium,
            request_id = COALESCE(excluded.request_id, messages.request_id)
        """, [r.id, r.source, r.session, r.project, r.model, r.ts, r.sidechain, r.agent,
              r.input, r.output, r.cacheWrite, r.cacheWrite1h, r.cacheRead, r.cost, r.premium, r.requestID])
    }

    /// A request seen in both sources counts once, as the transcript row (it knows project and agent)
    /// carrying telemetry's cost; the telemetry row points back through `partner` and drops out of
    /// `Sources.clause`. Pairs match on request id. A transcript row without one may pair with a
    /// telemetry row of the same session, model and token counts within `matchWindow`, nearest first.
    /// Re-run whenever either row changes, so a pairing streaming has invalidated is undone.
    func merge(_ id: String) throws {
        guard let row = try run("SELECT source, request_id, partner FROM messages WHERE id = ?", [id]).first else { return }
        let rid = row[1] as? String, current = row[2] as? String
        guard row.str(0) == Sources.transcripts else {
            if let t = current { return try merge(t) }
            if let rid, let t = try run("SELECT id FROM messages WHERE request_id = ? AND source = 'transcripts'", [rid]).first {
                return try merge(t.str(0))
            }
            if let t = try nearest(to: id, in: Sources.transcripts) { try link(t, id) }
            return
        }
        var want: String?
        var stolenFrom: String?
        if let rid {
            if let o = try run("""
                SELECT o.id, t.id, t.request_id FROM messages o LEFT JOIN messages t ON t.id = o.partner
                WHERE o.request_id = ? AND o.source = 'otel'
                """, [rid]).first {
                let holder = o[1] as? String
                // An exact match takes the row from a guessed pairing, never from another exact one.
                if holder == nil || holder == id || o[2] == nil {
                    want = o.str(0)
                    if let h = holder, h != id { stolenFrom = h }
                }
            }
        } else {
            want = try nearest(to: id, in: Sources.otel)
        }
        guard want != current else {
            if let want { try link(id, want) }
            return
        }
        if let current { try unlink(id, current) }
        if let h = stolenFrom, let w = want { try unlink(h, w) }
        if let want { try link(id, want) }
        for released in [current, stolenFrom] { if let r = released { try merge(r) } }
    }

    /// The unpaired row in `source` matching `id` by session, model and tokens, nearest in time.
    /// Transcript rows with a request id only pair by that id.
    private func nearest(to id: String, in source: String) throws -> String? {
        try run("""
        SELECT c.id FROM messages r JOIN messages c
            ON c.session = r.session AND c.source = ? AND c.output = r.output AND c.model = r.model
            AND c.input = r.input AND c.cache_write = r.cache_write AND c.cache_read = r.cache_read
        WHERE r.id = ? AND r.session != '' AND ABS(c.ts - r.ts) <= ?
            AND (c.partner IS NULL OR c.partner = r.id)
            AND (CASE WHEN r.source = 'transcripts' THEN r.request_id ELSE c.request_id END) IS NULL
        ORDER BY ABS(c.ts - r.ts) LIMIT 1
        """, [source, id, Self.matchWindow]).first?.str(0)
    }

    /// Telemetry's cost wins whenever it reported one, including 0.
    private func link(_ transcript: String, _ otel: String) throws {
        try run("UPDATE messages SET partner = ?, cost = (SELECT cost FROM messages WHERE id = ?) WHERE id = ?", [otel, otel, transcript])
        try run("UPDATE messages SET partner = ? WHERE id = ?", [transcript, otel])
    }

    private func unlink(_ transcript: String, _ otel: String) throws {
        try run("UPDATE messages SET partner = NULL, cost = NULL WHERE id = ?", [transcript])
        try run("UPDATE messages SET partner = NULL WHERE id = ?", [otel])
    }
}

private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String) -> Double? {
    (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
}

/// "us.anthropic.claude-haiku-4-5-20251001-v1:0" and "claude-haiku-4-5-20251001" both become "claude-haiku-4-5".
func normalizeModel(_ raw: String) -> String {
    var m = raw.lowercased()
    if let slash = m.lastIndex(of: "/") { m = String(m[m.index(after: slash)...]) }
    m = m.replacingOccurrences(of: "[1m]", with: "")
    m = m.replacing(#/^(us|eu|apac|global|jp|au|ca)\./#, with: "")
    m = m.replacing(#/^anthropic\./#, with: "")
    m = m.replacing(#/-v\d+(:\d+)?$/#, with: "")
    m = m.replacing(#/-\d{8}$/#, with: "")
    return m
}

/// Works out whether a request paid the regional / US-only premium, per provider:
/// Bedrock from the inference profile prefix (us., eu., ...), the Claude API from usage.inference_geo,
/// Vertex from CLOUD_ML_REGION. Transcripts carry only the short model name, so Bedrock profile IDs are
/// learned from Claude Code's settings and env, and from cost-state records as they're read.
final class Endpoints {
    static let regionalPrefix = #/^(us|eu|apac|jp|au|ca)\./#

    enum Provider: String { case bedrock, vertex, anthropic }

    /// Written by the transcript queue, read by Settings on the main thread.
    private var ids: [String: String] = [:]
    private let lock = NSLock()
    private var bedrockIDs: [String: String] { lock.withLock { ids } }
    private let vertexRegion: String?
    /// The provider Claude Code is configured for, for sources that don't say (telemetry).
    let configured: Provider
    /// settings.json `modelPricing`: telemetry's cost_usd then comes from the user's table, not list price.
    let customPricing: Bool

    init() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let settings = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let env = (settings["env"] as? [String: String] ?? [:]).merging(ProcessInfo.processInfo.environment) { file, _ in file }
        vertexRegion = env["CLOUD_ML_REGION"]
        customPricing = settings["modelPricing"] != nil
        let named = (settings["modelProvider"] as? String)?.lowercased()
        configured = named == "bedrock" || env["CLAUDE_CODE_USE_BEDROCK"] == "1" ? .bedrock
            : named == "vertex" || env["CLAUDE_CODE_USE_VERTEX"] == "1" ? .vertex : .anthropic
        let ids = [settings["model"] as? String] + ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                                                   "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"].map { env[$0] }
        for case let id? in ids { learn(id) }
    }

    func learn(_ fullID: String) {
        lock.withLock { ids[normalizeModel(fullID)] = fullID }
    }

    static func provider(messageID: String) -> Provider {
        if messageID.hasPrefix("msg_bdrk_") { return .bedrock }
        if messageID.hasPrefix("msg_vrtx_") { return .vertex }
        return .anthropic
    }

    static func isRegional(_ fullID: String) -> Bool { fullID.contains(regionalPrefix) }

    func premium(provider: Provider, model: String, geo: String?) -> Bool {
        switch provider {
        case .anthropic:
            return geo == "us"
        case .vertex:
            return vertexRegion.map { $0 != "global" } ?? false
        case .bedrock:
            let known = bedrockIDs
            if let id = known[normalizeModel(model)] { return Self.isRegional(id) }
            // An unseen model most likely uses the same kind of profile as the ones Claude Code is configured with.
            return !known.isEmpty && known.values.allSatisfy(Self.isRegional)
        }
    }

    /// For Settings: which premium rule applied, in words.
    var summary: String {
        let profiles = bedrockIDs.values.sorted().joined(separator: ", ")
        return profiles.isEmpty ? "No Bedrock profiles seen" : "Bedrock profiles: \(profiles)"
    }
}
