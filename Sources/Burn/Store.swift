import Foundation
import SwiftUI

struct Filter: Equatable {
    enum Agent: String, CaseIterable { case all = "All", main = "Main agent", sub = "Subagents" }
    var from = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    /// nil means through today, so a window left open past midnight keeps including today.
    var to: Date?
    var project = ""
    var session = ""
    var model = ""
    var agent = Agent.all

    /// `to` is inclusive of that whole local day.
    func sql() -> (String, [Any?]) {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to ?? Date()))!
        var w = [Sources.clause, "m.ts >= ?", "m.ts < ?"]
        var args: [Any?] = [Calendar.current.startOfDay(for: from).timeIntervalSince1970, end.timeIntervalSince1970]
        if !project.isEmpty { w.append("m.project = ?"); args.append(project) }
        if !session.isEmpty { w.append("m.session = ?"); args.append(session) }
        if !model.isEmpty { w.append("m.model = ?"); args.append(model) }
        if agent != .all { w.append("m.sidechain = ?"); args.append(agent == .sub) }
        return (w.joined(separator: " AND "), args)
    }
}

struct Slice: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let cost: Double
}

struct DayCost: Identifiable {
    var id: String { "\(day)\(model)" }
    let day: Date
    let model: String
    let cost: Double
}

struct SessionRow: Identifiable {
    let id: String
    let project: String
    let start: Date
    let messages: Int
    let subagentShare: Double
    let cost: Double
    let unpricedTokens: Int
}

struct Summary: Equatable {
    var cost = 0.0
    var tokens = 0
    var unpricedTokens = 0
    var unpricedModels: [String] = []
}

enum Q {
    static let from = "FROM messages m LEFT JOIN prices p ON p.model = m.model"
    private static let tiered = "(p.tier_tokens IS NOT NULL AND m.input + m.cache_write + m.cache_read > p.tier_tokens)"
    private static func tokenCost(_ t: String) -> String {
        "(m.input*p.\(t)input + m.output*p.\(t)output + (m.cache_write - m.cache_write_1h)*p.\(t)cache_write"
            + " + m.cache_write_1h*p.\(t)cache_write_1h + m.cache_read*p.\(t)cache_read)/1e6"
    }
    /// Reported costs are telemetry's, priced at list like Burn's own, so the premium applies once either way.
    static let cost = """
        (CASE WHEN m.cost IS NOT NULL
            THEN m.cost * CASE WHEN m.premium = 1 THEN COALESCE(p.reported_mult, (SELECT reported_mult FROM prices LIMIT 1), 1) ELSE 1 END
            ELSE CASE WHEN \(tiered) THEN \(tokenCost("t_")) ELSE \(tokenCost("")) END
                * CASE WHEN m.premium = 1 THEN COALESCE(p.mult, 1) ELSE 1 END END)
        """
    static let tokens = "(m.input + m.output + m.cache_write + m.cache_read)"
    static let unpriced = "CASE WHEN m.cost IS NULL AND p.model IS NULL THEN \(tokens) ELSE 0 END"

    static func summary(_ db: DB, _ f: Filter) -> Summary {
        let (w, a) = f.sql()
        var s = Summary()
        if let r = try? db.run("""
            SELECT COALESCE(SUM(\(cost)),0), COALESCE(SUM(\(tokens)),0), COALESCE(SUM(\(unpriced)),0),
                   group_concat(DISTINCT CASE WHEN m.cost IS NULL AND p.model IS NULL THEN m.model END)
            \(from) WHERE \(w)
            """, a).first {
            s.cost = r.dbl(0); s.tokens = r.int(1); s.unpricedTokens = r.int(2)
            s.unpricedModels = r.str(3).split(separator: ",").map(String.init).sorted()
        }
        return s
    }

    /// Top rows plus an "Other" row, so the list adds up to the total.
    static func breakdown(_ db: DB, _ f: Filter, by column: String, limit: Int = 6) -> [Slice] {
        let (w, a) = f.sql()
        let rows = (try? db.run("SELECT \(column), COALESCE(SUM(\(cost)),0) AS c \(from) WHERE \(w) GROUP BY 1 ORDER BY c DESC", a)) ?? []
        let slices = rows.map { Slice(name: $0.str(0), cost: $0.dbl(1)) }
        guard slices.count > limit else { return slices }
        let rest = slices[(limit - 1)...].reduce(0) { $0 + $1.cost }
        return Array(slices.prefix(limit - 1)) + [Slice(name: "Other", cost: rest)]
    }

    private static let day = "strftime('%Y-%m-%d', m.ts, 'unixepoch', 'localtime')"

    private static func dayFormatter() -> DateFormatter {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt
    }

    /// Fully unpriced model-days are left out rather than drawn as $0.
    static func daily(_ db: DB, _ f: Filter) -> [DayCost] {
        let (w, a) = f.sql()
        let fmt = dayFormatter()
        let rows = (try? db.run("""
        SELECT \(day), m.model, SUM(\(cost)) AS c
        \(from) WHERE \(w) GROUP BY 1, 2 HAVING c IS NOT NULL ORDER BY 1
        """, a)) ?? []
        return rows.compactMap { r in fmt.date(from: r.str(0)).map { DayCost(day: $0, model: r.str(1), cost: r.dbl(2)) } }
    }

    /// Local start-of-day dates that have unpriced tokens.
    static func unpricedDays(_ db: DB, _ f: Filter) -> Set<Date> {
        let (w, a) = f.sql()
        let fmt = dayFormatter()
        let rows = (try? db.run("SELECT DISTINCT \(day) \(from) WHERE \(w) AND m.cost IS NULL AND p.model IS NULL", a)) ?? []
        return Set(rows.compactMap { fmt.date(from: $0.str(0)) })
    }

    static func sessionCount(_ db: DB, _ f: Filter) -> Int {
        let (w, a) = f.sql()
        return (try? db.run("SELECT COUNT(DISTINCT m.session) FROM messages m WHERE \(w)", a))?.first?.int(0) ?? 0
    }

    static func sessions(_ db: DB, _ f: Filter) -> [SessionRow] {
        let (w, a) = f.sql()
        let rows = (try? db.run("""
        SELECT m.session, MAX(m.project), MIN(m.ts), COUNT(*),
               COALESCE(SUM(CASE WHEN m.sidechain=1 THEN \(cost) ELSE 0 END),0),
               COALESCE(SUM(\(cost)),0), COALESCE(SUM(\(unpriced)),0)
        \(from) WHERE \(w) GROUP BY m.session ORDER BY 6 DESC LIMIT 500
        """, a)) ?? []
        return rows.map { r in
            let c = r.dbl(5)
            return SessionRow(id: r.str(0), project: r.str(1), start: Date(timeIntervalSince1970: r.dbl(2)),
                              messages: r.int(3), subagentShare: c > 0 ? r.dbl(4) / c : 0, cost: c, unpricedTokens: r.int(6))
        }
    }

    static func distinct(_ db: DB, _ column: String) -> [String] {
        ((try? db.run("SELECT DISTINCT m.\(column) \(from) WHERE \(Sources.clause) AND m.\(column) != '' ORDER BY 1")) ?? []).map { $0.str(0) }
    }
}

final class AppModel: ObservableObject {
    @Published var today = Summary()
    @Published var month = Summary()
    @Published var todayProjects: [Slice] = []
    @Published var todayModels: [Slice] = []
    @Published var todayAgents: [Slice] = []
    @Published var errors: [String] = []
    /// True while transcripts are being read from scratch, when totals are still partial.
    @Published var scanning = false
    /// Separate object so a frame tick redraws only the menu-bar label.
    let flame = FlameFrame()
    let notifier = Notifier()
    @Published private(set) var telemetry = Telemetry.Status(line: "")
    @Published var telemetryError: String?

    let db: DB
    let pricing: Pricing
    let transcripts: TranscriptSource
    private(set) var otel: OTelSource?
    private var timer: Timer?
    private let refreshQueue = DispatchQueue(label: "burn.refresh", qos: .utility)
    private var pending = false
    private var flicker: Timer?
    private var cool: Timer?
    private var lastUsage: Double = 0
    private var flickeredFor: Double = 0
    /// Main thread. Errors from outside the sources, kept across refreshes.
    private var reported: [String] = []

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Burn")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do { db = try DB(url: dir.appendingPathComponent("usage.db")) } catch { fatalError("\(error)") }
        transcripts = TranscriptSource(db: db)
        pricing = Pricing(dir: dir, reportedIsFinal: transcripts.endpoints.customPricing)
        notifier.report = { [weak self] in self?.report($0) }

        transcripts.start { [weak self] in self?.refresh() }
        checkTelemetry()
        // Cheap SQL; also rolls "today" over at local midnight.
        timer = Self.common(Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() })
        refresh()
    }

    func report(_ error: String) {
        DispatchQueue.main.async {
            self.reported.append(error)
            self.errors.append(error)
        }
    }

    /// The listener runs exactly while settings.json points Claude Code's logs at it.
    func checkTelemetry() {
        let s: Telemetry.Status
        do {
            s = Telemetry.status(env: try Telemetry.read()?["env"] as? [String: Any] ?? [:], managed: Telemetry.managedEnv())
        } catch {
            s = Telemetry.Status(line: error.localizedDescription)
        }
        if telemetry != s { telemetry = s }
        if s.listening, otel == nil {
            let o = OTelSource(db: db, endpoints: transcripts.endpoints)
            o.start { [weak self] in self?.refresh() }
            otel = o
        } else if !s.listening, let o = otel {
            o.stop()
            otel = nil
            refresh()
        }
    }

    func changeTelemetry(_ action: Telemetry.Action) {
        do {
            let root = try Telemetry.read()
            let plan = Telemetry.plan(action, root: root, record: Settings.telemetryRecord)
            guard !plan.changes.isEmpty, confirm(plan.changes) else { return }
            try Telemetry.write(plan.root)
            Settings.telemetryRecord = plan.record
            telemetryError = nil
        } catch {
            telemetryError = "Couldn't change ~/.claude/settings.json: \(error.localizedDescription)"
        }
        checkTelemetry()
    }

    private func confirm(_ changes: [String]) -> Bool {
        let a = NSAlert()
        a.messageText = "Change ~/.claude/settings.json?"
        a.informativeText = changes.joined(separator: "\n") + "\n\nBurn backs the file up first, then rewrites it with its keys sorted, so other settings may move but keep their values. This applies to Claude Code sessions started after this."
        a.addButton(withTitle: "Change")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Coalesces bursts of FSEvents into one query pass.
    func refresh() {
        refreshQueue.async {
            guard !self.pending else { return }
            self.pending = true
            self.refreshQueue.asyncAfter(deadline: .now() + 0.5) { self.compute() }
        }
    }

    private func compute() {
        pending = false
        let now = Date()
        let amounts = Settings.alertAmounts
        var t = Filter()
        t.from = Period.day.start(now)
        var m = t
        m.from = Period.month.start(now)
        var w = t
        w.from = Period.week.start(now)
        let result = db.queue.sync { () -> (Summary, Summary, [Slice], [Slice], [Slice], String?, Summary?) in
            pricing.reloadIfChanged(into: db)
            return (Q.summary(db, t), Q.summary(db, m),
                    Q.breakdown(db, t, by: "m.project"),
                    Q.breakdown(db, t, by: "m.model"),
                    Q.breakdown(db, t, by: "CASE WHEN m.sidechain=1 THEN 'Subagents' ELSE 'Main agent' END"), pricing.error,
                    amounts[.week] == nil ? nil : Q.summary(db, w))
        }
        let latest = db.queue.sync {
            [Sources.transcripts, Sources.otel].map { (try? db.run("SELECT MAX(ts) FROM messages WHERE source = ?", [$0]))?.first?.dbl(0) ?? 0 }.max() ?? 0
        }
        let scanning = transcripts.scanning
        let earlier = [result.5, transcripts.lastError]
        DispatchQueue.main.async {
            let errs = (earlier + [self.otel?.lastError]).compactMap { $0 } + self.reported
            // Assigning equal values still fires objectWillChange and re-renders the popover.
            if self.today != result.0 { self.today = result.0 }
            if self.month != result.1 { self.month = result.1 }
            if self.todayProjects != result.2 { self.todayProjects = result.2 }
            if self.todayModels != result.3 { self.todayModels = result.3 }
            if self.todayAgents != result.4 { self.todayAgents = result.4 }
            if self.errors != errs { self.errors = errs }
            if self.scanning != scanning { self.scanning = scanning }
            self.lastUsage = latest
            self.updateFlicker()
            var spent: [Period: Summary] = [.day: result.0, .month: result.1]
            spent[.week] = result.6
            let old = Settings.alertsFired
            let (due, fired) = Alerts.check(now: now, cal: .current, amounts: amounts, spent: spent, fired: old)
            if fired != old { Settings.alertsFired = fired }
            due.forEach(self.notifier.send)
            self.chime(due)
        }
    }

    func testAlert() {
        let due = Alerts.Due.sample
        notifier.test(due)
        chime([due])
    }

    private func chime(_ due: [Alerts.Due]) {
        guard !due.isEmpty else { return }
        if let s = Settings.alertSound { NSSound(named: s)?.play() }
    }

    /// One flicker cycle each time new usage lands. On macOS 26 every status-item image change
    /// redraws all menu-bar replicants, so continuous animation cost about 8% CPU.
    private func updateFlicker() {
        let now = Date().timeIntervalSince1970
        cool?.invalidate()
        flame.lit = now - lastUsage < Self.litFor
        if flame.lit {
            cool = Self.common(Timer(timeInterval: Self.litFor - (now - lastUsage), repeats: false) { [weak self] _ in
                self?.flame.lit = false
            })
        }
        guard lastUsage > flickeredFor, flicker == nil else { return }
        let first = flickeredFor == 0
        flickeredFor = lastUsage
        guard !first, now - lastUsage < 60, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        flame.index = 0
        flicker = Self.common(Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, let i = self.flame.index else { return }
            if i + 1 < FlameGlyph.frames.count {
                self.flame.index = i + 1
            } else {
                t.invalidate()
                self.flicker = nil
                self.flame.index = nil
            }
        })
    }

    /// Default-mode timers pause while a menu, like the Source picker, is tracking.
    private static func common(_ t: Timer) -> Timer {
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    /// Pauses between tool calls are shorter than this, so the icon doesn't blink grey mid-session.
    private static let litFor: Double = 120
}

final class FlameFrame: ObservableObject {
    /// Set while a flicker cycle plays.
    @Published var index: Int?
    /// Colour while spend is landing, monochrome otherwise.
    @Published var lit = false

    var image: NSImage {
        if let i = index { return FlameGlyph.frames[i] }
        return lit ? FlameGlyph.lit : FlameGlyph.idle
    }
}

enum Settings {
    private static let d = UserDefaults.standard

    /// What Burn's telemetry setup changed in settings.json, so Remove undoes only that.
    static var telemetryRecord: [String: String] {
        get { d.dictionary(forKey: "telemetry.added") as? [String: String] ?? [:] }
        set { newValue.isEmpty ? d.removeObject(forKey: "telemetry.added") : d.set(newValue, forKey: "telemetry.added") }
    }

    /// "alert.day" and so on; a missing key means that alert is off.
    static var alertAmounts: [Period: Double] {
        Dictionary(uniqueKeysWithValues: Period.allCases.compactMap { p in (d.object(forKey: "alert." + p.rawValue) as? Double).map { (p, $0) } })
    }
    static let defaultSound = "Glass"
    static let systemSounds = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    /// Empty means None.
    static var alertSound: String? {
        let s = d.string(forKey: "alert.sound") ?? defaultSound
        return s.isEmpty ? nil : s
    }
    static var alertsFired: [String] {
        get { d.stringArray(forKey: "alerts.fired") ?? [] }
        set { d.set(newValue, forKey: "alerts.fired") }
    }
}
