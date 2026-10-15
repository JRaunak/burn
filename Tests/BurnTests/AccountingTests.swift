import Foundation
import SQLite3
import Testing
@testable import Burn

private let bundledPricing = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("../../Resources/pricing.json").standardized
private let t0 = 1_791_500_000.0

/// A throwaway directory with its own usage.db and pricing.json.
private final class Fixture {
    let dir: URL
    let db: DB

    init(pricing: Data? = nil, reportedIsFinal: Bool = false, setup: ((URL) throws -> Void)? = nil) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("burntest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (pricing ?? Data(contentsOf: bundledPricing)).write(to: dir.appendingPathComponent("pricing.json"))
        try setup?(dir.appendingPathComponent("usage.db"))
        db = try DB(url: dir.appendingPathComponent("usage.db"))
        let p = Pricing(dir: dir, reportedIsFinal: reportedIsFinal)
        p.reloadIfChanged(into: db)
        if let e = p.error { throw DBError(description: e) }
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var total: Double {
        Q.summary(db, Filter(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4e9))).cost
    }

    func counted() throws -> Int {
        try db.run("SELECT COUNT(*) FROM messages m WHERE \(Sources.clause)").first?.int(0) ?? -1
    }

    func value(_ sql: String, _ args: [Any?] = []) throws -> Any? {
        try db.run(sql, args).first?[0]
    }

    func store(_ rows: UsageRow...) throws {
        try db.transaction { try db.store(rows) }
    }
}

/// The 68fa8723 request: Opus 5.5, every cache write 1-hour.
private func transcript(_ mid: String, rid: String?, ts: Double = t0, output: Int = 4, premium: Bool = true,
                        model: String = "claude-opus-5-5", input: Int = 2, cacheWrite: Int = 26080,
                        cacheWrite1h: Int = 26080, cacheRead: Int = 0) -> UsageRow {
    UsageRow(id: "cc:" + mid, source: Sources.transcripts, session: "s1", project: "p", model: model, ts: ts,
             input: input, output: output, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h, cacheRead: cacheRead,
             requestID: rid, premium: premium)
}

private func telemetry(_ rid: String?, ts: Double = t0 + 1.3, output: Int = 4, cost: Double? = 0.208728,
                       input: Int = 2, cacheWrite: Int = 26080, cacheRead: Int = 0) -> UsageRow {
    UsageRow(id: "otel:" + (rid ?? "s1:\(ts):\(output)"), source: Sources.otel, session: "s1", model: "claude-opus-5-5", ts: ts,
             input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead, requestID: rid, cost: cost, premium: true)
}

private func assistantLine(_ mid: String, rid: String?, ts: String = "2026-10-09T10:00:00.000Z", output: Int,
                           input: Int = 2, cacheWrite: Int, split: (Int, Int)?, model: String = "claude-opus-5-5") throws -> String {
    var usage: [String: Any] = ["input_tokens": input, "output_tokens": output,
                                "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": 0]
    if let (m5, h1) = split {
        usage["cache_creation"] = ["ephemeral_5m_input_tokens": m5, "ephemeral_1h_input_tokens": h1]
    }
    var line: [String: Any] = ["type": "assistant", "timestamp": ts, "sessionId": "s1", "cwd": "/tmp/proj",
                               "message": ["id": mid, "model": model, "usage": usage]]
    line["requestId"] = rid
    return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
}

private func otlp(_ records: [[String: Any]]) throws -> Data {
    let logs = records.map { ["attributes": attributes($0)] }
    return try JSONSerialization.data(withJSONObject: ["resourceLogs": [["scopeLogs": [["logRecords": logs]]]]])
}

private func attributes(_ a: [String: Any]) -> [[String: Any]] {
    a.map { k, v -> [String: Any] in
        let value: [String: Any] = v is Double ? ["doubleValue": v] : ["stringValue": "\(v)"]
        return ["key": k, "value": value]
    }
}

private func apiRequest(_ rid: String, cost: Double, micros: Int? = nil) -> [String: Any] {
    var a: [String: Any] = ["event.name": "claude_code.api_request", "model": "claude-opus-5-5", "session.id": "s1",
                            "event.timestamp": "2026-10-09T10:00:01.300Z", "request_id": rid, "cost_usd": cost,
                            "input_tokens": 2, "output_tokens": 4, "cache_read_tokens": 0, "cache_creation_tokens": 26080]
    a["cost_usd_micros"] = micros
    return a
}

@Suite struct CacheDurations {
    @Test func mixed5mAnd1hInOneRecord() throws {
        let f = try Fixture()
        // Sonnet 4.5: 1000 input at 3, 10 output at 15, 3000 5-minute writes at 3.75, 2000 1-hour writes at 6.
        try f.store(transcript("m", rid: nil, output: 10, premium: false, model: "claude-sonnet-4-5", input: 1000,
                               cacheWrite: 5000, cacheWrite1h: 2000))
        #expect(abs(f.total - (1000 * 3 + 10 * 15 + 3000 * 3.75 + 2000 * 6) / 1e6) < 1e-12)
    }

    @Test func transcriptLinesFillTheSplitAndRequestID() throws {
        let f = try Fixture()
        let file = f.dir.appendingPathComponent("s1.jsonl")
        try ([try assistantLine("msg_a", rid: "req-a", output: 4, cacheWrite: 300, split: (100, 200)),
              try assistantLine("msg_b", rid: nil, output: 4, cacheWrite: 300, split: nil)].joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        TranscriptSource(db: f.db).ingest(file)
        let rows = try f.db.run("SELECT id, cache_write, cache_write_1h, request_id FROM messages ORDER BY id")
        #expect(rows.map { $0.str(0) } == ["cc:msg_a", "cc:msg_b"])
        #expect(rows[0].int(1) == 300 && rows[0].int(2) == 200 && rows[0].str(3) == "req-a")
        // No breakdown: every write is 5-minute.
        #expect(rows[1].int(1) == 300 && rows[1].int(2) == 0 && rows[1][3] == nil)
    }

    // Claude Code 2.1.300 added the split; older versions send only the total.
    @Test(arguments: [
        (["cache_creation_5m_tokens": 1000, "cache_creation_1h_tokens": 25080], 26080, 25080),
        ([:], 26080, 0),
        (["cache_creation_tokens": nil, "cache_creation_5m_tokens": 1000, "cache_creation_1h_tokens": 25080], 26080, 25080),
    ] as [([String: Int?], Int, Int)])
    func telemetrySplit(extra: [String: Int?], cacheWrite: Int, cacheWrite1h: Int) throws {
        var a = apiRequest("r1", cost: 0.5)
        for (k, v) in extra { a[k] = v }
        let row = OTelSource(db: try Fixture().db, endpoints: Endpoints()).row(["attributes": attributes(a)])
        #expect(row?.cacheWrite == cacheWrite)
        #expect(row?.cacheWrite1h == cacheWrite1h)
    }

    @Test func noBreakdownPricesEveryWriteAt5m() throws {
        let f = try Fixture()
        try f.store(transcript("m", rid: nil, premium: false, cacheWrite1h: 0))
        #expect(abs(f.total - 0.130488) < 1e-12)
    }

    @Test func missingCacheWrite1hFallsBackToTwiceInput() throws {
        let json = #"{"regionalPremium": 1.1, "models": {"claude-opus-5-5": {"input": 4, "output": 20, "cacheWrite": 5, "cacheRead": 0.2}}}"#
        let f = try Fixture(pricing: Data(json.utf8))
        try f.store(transcript("m", rid: nil, premium: false))
        #expect(abs(f.total - 0.208728) < 1e-12)
    }

    struct HaikuCase: Sendable {
        let input: Int, output: Int, cacheWrite: Int, cacheWrite1h: Int, expected: Double
    }

    @Test(arguments: [
        // Prompt 110K is over the tier: 50K input at 0.5, 1K output at 2.5, 40K 5-minute at 0.625, 20K 1-hour at 1.
        HaikuCase(input: 50000, output: 1000, cacheWrite: 60000, cacheWrite1h: 20000, expected: 0.0725),
        // Prompt 4K: 1K input at 0.1, 100 output at 0.5, 2K 5-minute at 0.125, 1K 1-hour at 0.2.
        HaikuCase(input: 1000, output: 100, cacheWrite: 3000, cacheWrite1h: 1000, expected: 0.0006),
    ])
    func haiku55TierWith1hWrites(_ c: HaikuCase) throws {
        let f = try Fixture()
        try f.store(transcript("m", rid: nil, output: c.output, premium: false, model: "claude-haiku-5-5",
                               input: c.input, cacheWrite: c.cacheWrite, cacheWrite1h: c.cacheWrite1h))
        #expect(abs(f.total - c.expected) < 1e-12)
    }
}

@Suite struct Merge {
    @Test func regression68fa8723() throws {
        let f = try Fixture()
        try f.store(transcript("m", rid: "e3c015d5", premium: false))
        #expect(abs(f.total - 0.208728) < 1e-12)
        try f.db.run("UPDATE messages SET premium = 1")
        #expect(abs(f.total - 0.2296008) < 1e-12)
        try f.store(telemetry("e3c015d5"))
        #expect(try f.counted() == 1)
        #expect(try f.value("SELECT cost FROM messages WHERE id = 'cc:m'") as? Double == 0.208728)
        #expect(abs(f.total - 0.2296008) < 1e-12)
    }

    @Test(arguments: [true, false])
    func eitherArrivalOrder(telemetryFirst: Bool) throws {
        let f = try Fixture()
        let (t, o) = (transcript("m", rid: "r1", cacheWrite1h: 0), telemetry("r1", cost: 0.3))
        if telemetryFirst { try f.store(o); try f.store(t) } else { try f.store(t); try f.store(o) }
        #expect(try f.counted() == 1)
        #expect(abs(f.total - 0.33) < 1e-12)
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:r1'") as? String == "cc:m")
    }

    @Test func streamingAroundTelemetryWithRequestID() throws {
        let f = try Fixture()
        try f.store(transcript("m", rid: "r1", output: 1))
        try f.store(telemetry("r1", output: 900, cost: 0.4))
        try f.store(transcript("m", rid: "r1", output: 600), transcript("m", rid: "r1", output: 850))
        #expect(try f.counted() == 1)
        #expect(abs(f.total - 0.44) < 1e-12)
    }

    @Test func streamingNeverLeavesAStaleGuess() throws {
        let f = try Fixture()
        try f.store(transcript("m", rid: nil, output: 1))
        try f.store(telemetry("r1", output: 50, cost: 0.4))
        #expect(try f.counted() == 2)
        try f.store(transcript("m", rid: nil, output: 50))
        #expect(try f.counted() == 1)
        #expect(abs(f.total - 0.44) < 1e-12)
        try f.store(transcript("m", rid: nil, output: 60))
        #expect(try f.counted() == 2)
        #expect(try f.value("SELECT cost FROM messages WHERE id = 'cc:m'") == nil)
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:r1'") == nil)
    }

    @Test func exactMatchTakesTheRowFromAGuess() throws {
        let f = try Fixture()
        try f.store(transcript("old", rid: nil))
        try f.store(telemetry("r1"))
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:r1'") as? String == "cc:old")
        try f.store(transcript("new", rid: "r1", ts: t0 + 1))
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:r1'") as? String == "cc:new")
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'cc:old'") == nil)
        #expect(try f.counted() == 2)
    }

    @Test func repeatedOTLPDeliveryAndTranscriptReread() throws {
        let f = try Fixture()
        let source = TranscriptSource(db: f.db)
        let otel = OTelSource(db: f.db, endpoints: source.endpoints)
        let body = try otlp([apiRequest("r1", cost: 0.2)])
        #expect(otel.ingest(body) && otel.ingest(body))
        let file = f.dir.appendingPathComponent("s1.jsonl")
        try (try assistantLine("msg_a", rid: "r1", output: 4, cacheWrite: 26080, split: (0, 26080)) + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        source.ingest(file)
        let once = f.total
        try f.db.run("DELETE FROM files")
        source.ingest(file)
        #expect(otel.ingest(body))
        #expect(try f.value("SELECT COUNT(*) FROM messages") as? Int == 2)
        #expect(try f.counted() == 1)
        #expect(f.total == once)
        let premium = try f.value("SELECT premium FROM messages WHERE id = 'cc:msg_a'") as? Int == 1
        #expect(abs(once - 0.2 * (premium ? 1.1 : 1)) < 1e-12)
    }

    @Test func identicalTokensDistinctRequestIDs() throws {
        let f = try Fixture()
        try f.store(transcript("a", rid: "r1"), transcript("b", rid: "r2", ts: t0 + 2))
        try f.store(telemetry("r2", ts: t0 + 1, cost: 0.2), telemetry("r1", ts: t0 + 3, cost: 0.1))
        #expect(try f.counted() == 2)
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:r1'") as? String == "cc:a")
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:r2'") as? String == "cc:b")
        #expect(abs(f.total - 0.33) < 1e-12)
    }

    @Test func differingRequestIDsNeverGuess() throws {
        let f = try Fixture()
        try f.store(transcript("a", rid: "r1"), telemetry("r2"))
        #expect(try f.counted() == 2)
    }

    @Test func identicalTokensNoRequestIDsFarApart() throws {
        let f = try Fixture()
        try f.store(transcript("a", rid: nil), transcript("b", rid: nil, ts: t0 + 600))
        #expect(try f.counted() == 2)
        try f.store(telemetry(nil, ts: t0 + 601, cost: 0.2), telemetry(nil, ts: t0 + 1, cost: 0.1))
        #expect(try f.counted() == 2)
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:s1:\(t0 + 1):4'") as? String == "cc:a")
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:s1:\(t0 + 601):4'") as? String == "cc:b")
        #expect(abs(f.total - 0.33) < 1e-12)
    }

    @Test func closeIdenticalRequestsPairOneToOne() throws {
        let f = try Fixture()
        try f.store(transcript("a", rid: nil), transcript("b", rid: nil, ts: t0 + 5))
        try f.store(telemetry("r1", ts: t0 + 4, cost: 0.1))
        try f.store(telemetry("r2", ts: t0 + 6, cost: 0.2))
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'cc:b'") as? String == "otel:r1")
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'cc:a'") as? String == "otel:r2")
        #expect(try f.counted() == 2)
        #expect(abs(f.total - 0.33) < 1e-12)
    }

    @Test func outsideTheWindowNeverGuesses() throws {
        let f = try Fixture()
        try f.store(transcript("a", rid: nil), telemetry("r1", ts: t0 + DB.matchWindow + 1))
        #expect(try f.counted() == 2)
    }

    @Test func zeroCostTelemetryWins() throws {
        let f = try Fixture()
        try f.store(transcript("m", rid: "r1"), telemetry("r1", cost: 0))
        #expect(try f.counted() == 1)
        #expect(f.total == 0)
        let row = OTelSource(db: f.db, endpoints: Endpoints()).row(["attributes": attributes(apiRequest("r1", cost: 0.5, micros: 0))])
        #expect(row?.cost == 0)
        #expect(row?.requestID == "r1")
    }

    @Test func unmatchedTelemetryCountsAtItsOwnCost() throws {
        let f = try Fixture()
        try f.store(telemetry("r1", cost: 0.5))
        #expect(abs(f.total - 0.55) < 1e-12)
    }

    @Test func customClaudeCodePricingIsFinal() throws {
        let f = try Fixture(reportedIsFinal: true)
        try f.store(transcript("m", rid: "r1"), telemetry("r1", cost: 0.5), transcript("n", rid: nil, ts: t0 + 999))
        #expect(abs(f.total - (0.5 + 0.208728 * 1.1)) < 1e-12)
    }
}

@Suite struct Migration {
    @Test func step4FromVersion3() throws {
        let f = try Fixture { url in
            var h: OpaquePointer?
            #expect(sqlite3_open(url.path, &h) == SQLITE_OK)
            defer { sqlite3_close(h) }
            #expect(sqlite3_exec(h, """
            CREATE TABLE messages(id TEXT PRIMARY KEY, source TEXT NOT NULL, session TEXT NOT NULL DEFAULT '',
                project TEXT NOT NULL DEFAULT '', model TEXT NOT NULL, ts REAL NOT NULL, sidechain INTEGER NOT NULL DEFAULT 0,
                agent TEXT NOT NULL DEFAULT '', input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
                cache_write INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0, cost REAL,
                premium INTEGER NOT NULL DEFAULT 0, dup INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX messages_src_ts ON messages(source, ts);
            CREATE INDEX messages_match ON messages(session, source, output);
            CREATE TABLE sessions(id TEXT PRIMARY KEY, project TEXT NOT NULL, cwd TEXT NOT NULL DEFAULT '', first_ts REAL NOT NULL, last_ts REAL NOT NULL);
            CREATE TABLE files(path TEXT PRIMARY KEY, inode INTEGER NOT NULL, offset INTEGER NOT NULL);
            CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TRIGGER messages_dup_cc AFTER INSERT ON messages BEGIN SELECT 1; END;
            INSERT INTO files VALUES('/x.jsonl', 1, 99);
            INSERT INTO messages(id, source, session, model, ts, input, output, cache_write, cost, premium, dup) VALUES
                ('cc:m', 'transcripts', 's1', 'claude-opus-5-5', \(t0), 2, 4, 26080, NULL, 1, 0),
                ('otel:e3c015d5-3fd0', 'otel', 's1', 'claude-opus-5-5', \(t0 + 1.3), 2, 4, 26080, 0.208728, 1, 1),
                ('otel:s1:\(t0 + 50):7', 'otel', 's1', 'claude-opus-5-5', \(t0 + 50), 2, 7, 26080, 0.1, 1, 0);
            PRAGMA user_version = 3;
            """, nil, nil, nil) == SQLITE_OK)
        }
        let cols = try f.db.run("PRAGMA table_info(messages)").map { $0.str(1) }
        #expect(cols.contains("request_id") && cols.contains("cache_write_1h") && cols.contains("partner") && !cols.contains("dup"))
        #expect(try f.value("PRAGMA user_version") as? Int == 4)
        #expect(try f.value("SELECT COUNT(*) FROM files") as? Int == 0)
        #expect(try f.value("SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'") as? Int == 0)
        #expect(try f.value("SELECT request_id FROM messages WHERE id = 'otel:e3c015d5-3fd0'") as? String == "e3c015d5-3fd0")
        #expect(try f.value("SELECT request_id FROM messages WHERE id = 'otel:s1:\(t0 + 50):7'") == nil)
        #expect(try f.value("SELECT partner FROM messages WHERE id = 'otel:e3c015d5-3fd0'") as? String == "cc:m")
        #expect(try f.value("SELECT COUNT(*) FROM messages WHERE source = 'otel'") as? Int == 2)
        #expect(abs(f.total - (0.208728 + 0.1) * 1.1) < 1e-12)
        // Reopening runs no step again.
        _ = try DB(url: f.dir.appendingPathComponent("usage.db"))
    }

    /// Runs only when pointed at a disposable copy: BURN_MIGRATION_DB=/tmp/copy.db swift test --filter liveCopy
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BURN_MIGRATION_DB"] != nil))
    func liveCopy() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURN_MIGRATION_DB"]!)
        let db = try DB(url: url)
        let pricingDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BURN_MIGRATION_PRICING_DIR"] ?? url.deletingLastPathComponent().path)
        let source = TranscriptSource(db: db)
        Pricing(dir: pricingDir, reportedIsFinal: source.endpoints.customPricing).reloadIfChanged(into: db)
        source.scanAll()
        let today = Calendar.current.startOfDay(for: Date())
        let report = try db.queue.sync { () -> String in
            let counts = try db.run("SELECT source, COUNT(*), COUNT(partner), COUNT(request_id), SUM(cache_write_1h) FROM messages GROUP BY 1")
            let all = Q.summary(db, Filter(from: Date(timeIntervalSince1970: 0)))
            let day = Q.summary(db, Filter(from: today))
            let row = try db.run("SELECT m.id, \(Q.cost) \(Q.from) WHERE m.request_id = 'e3c015d5-3fd0-4134-ba14-92212d628dbf' AND \(Sources.clause)")
            return "\(counts)\nall-time \(all.cost) today \(day.cost)\n68fa8723 \(row)"
        }
        print(report)
    }
}
