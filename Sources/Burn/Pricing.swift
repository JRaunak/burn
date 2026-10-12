import Foundation

/// pricing.json lives in Application Support so it can be edited; edits are picked up on the next refresh.
final class Pricing {
    let url: URL
    /// Not nil, so a missing pricing.json is reported on the first load instead of skipped.
    private var loadedMTime: Date? = .distantPast
    private(set) var error: String?
    private let reportedIsFinal: Bool

    /// `reportedIsFinal`: Claude Code prices telemetry with its own table, so reported costs get no premium.
    init(dir: URL, reportedIsFinal: Bool,
         bundled: URL = Bundle.main.url(forResource: "pricing", withExtension: "json") ?? URL(fileURLWithPath: "Resources/pricing.json")) {
        self.reportedIsFinal = reportedIsFinal
        url = dir.appendingPathComponent("pricing.json")
        Self.merge(bundled: bundled, into: url, base: dir.appendingPathComponent("pricing.bundled.json"))
    }

    /// Brings a new bundled table into the user's file: entries still equal to `base`, the bundle last merged, follow the bundle;
    /// edits, nulls and deletions stay. Without `base` (installs from before it existed) every existing entry counts as edited.
    static func merge(bundled: URL, into user: URL, base: URL) {
        guard let data = try? Data(contentsOf: bundled), let new = object(data),
              let newModels = new["models"] as? [String: Any] else { return }
        if FileManager.default.fileExists(atPath: user.path) {
            let baseData = try? Data(contentsOf: base)
            guard baseData != data else { return }
            // An unparseable file is left for reloadIfChanged to report; base stays old so the merge retries next launch.
            guard let mine = (try? Data(contentsOf: user)).flatMap(object),
                  var models = mine["models"] as? [String: Any] else { return }
            let old = baseData.flatMap(object)
            func take(_ new: Any?, _ mine: Any?, _ old: Any?) -> Any? {
                guard let new else { return mine }
                guard let mine else { return old == nil ? new : nil }
                return (old as? NSObject)?.isEqual(mine) == true ? new : mine
            }
            let oldModels = old.map { $0["models"] as? [String: Any] ?? [:] }
            for (k, v) in newModels { models[k] = take(v, models[k], oldModels?[k]) }
            var merged = mine
            merged["models"] = models
            // Without base, a missing regionalPremium may be a deliberate deletion, so only models are added.
            merged["regionalPremium"] = old == nil ? mine["regionalPremium"]
                : take(new["regionalPremium"], mine["regionalPremium"], old?["regionalPremium"])
            merged["note"] = new["note"] ?? mine["note"]
            if !NSDictionary(dictionary: merged).isEqual(to: mine) {
                guard let out = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                      (try? out.write(to: user, options: .atomic)) != nil else { return }
            }
        } else {
            guard (try? data.write(to: user, options: .atomic)) != nil else { return }
        }
        try? data.write(to: base, options: .atomic)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func reloadIfChanged(into db: DB) {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard mtime != loadedMTime else { return }
        loadedMTime = mtime
        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = root["models"] as? [String: Any] else {
                throw DBError(description: "pricing.json needs a \"models\" object")
            }
            let mult = (root["regionalPremium"] as? NSNumber)?.doubleValue ?? 1
            try db.transaction {
                try db.run("DELETE FROM prices")
                for (model, value) in models {
                    guard let p = value as? [String: Any] else { continue }
                    func n(_ o: [String: Any], _ k: String) throws -> Double {
                        guard let v = o[k] as? NSNumber else { throw DBError(description: "\(model) is missing \(k)") }
                        return v.doubleValue
                    }
                    // A missing cacheWrite1h is the documented 2x input, so older pricing.json files stay right.
                    func prices(_ o: [String: Any]) throws -> [Any?] {
                        let input = try n(o, "input")
                        return [input, try n(o, "output"), try n(o, "cacheWrite"),
                                (o["cacheWrite1h"] as? NSNumber)?.doubleValue ?? 2 * input, try n(o, "cacheRead")]
                    }
                    let tierArgs: [Any?] = try (p["above"] as? [String: Any]).map { [try n($0, "tokens")] + (try prices($0)) }
                        ?? [nil, nil, nil, nil, nil, nil]
                    try db.run("""
                    INSERT INTO prices(model, input, output, cache_write, cache_write_1h, cache_read, note,
                        tier_tokens, t_input, t_output, t_cache_write, t_cache_write_1h, t_cache_read, mult, reported_mult)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [normalizeModel(model)] + (try prices(p)) + [p["source"] as? String ?? ""] + tierArgs
                        + [mult, reportedIsFinal ? 1 : mult])
                }
            }
            error = nil
        } catch {
            self.error = "pricing.json: \(error)"
        }
    }
}
