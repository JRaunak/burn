import Foundation
import Testing
@testable import Burn

@Suite struct PricingMergeTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnpricing-\(UUID().uuidString)")
    var user: URL { dir.appendingPathComponent("pricing.json") }
    var base: URL { dir.appendingPathComponent("pricing.bundled.json") }
    var bundled: URL { dir.appendingPathComponent("bundle.json") }

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func write(_ json: String, to url: URL) throws {
        try Data(json.utf8).write(to: url)
    }

    /// Writes the old bundle as base and the new one as bundled, merges, and returns the user's file.
    private func merge(user mine: String, old: String?, new: String) throws -> [String: Any] {
        try write(mine, to: user)
        if let old { try write(old, to: base) }
        try write(new, to: bundled)
        Pricing.merge(bundled: bundled, into: user, base: base)
        #expect(try Data(contentsOf: base) == Data(new.utf8))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: user)) as? [String: Any])
    }

    private func models(_ root: [String: Any]) -> [String: Any] { root["models"] as? [String: Any] ?? [:] }
    private func input(_ root: [String: Any], _ model: String) -> Double? {
        ((models(root)[model] as? [String: Any])?["input"] as? NSNumber)?.doubleValue
    }

    private let v1 = #"{"note": "v1", "regionalPremium": 1.1, "models": {"a": {"input": 1}, "b": {"input": 2}}}"#

    @Test func newModelAdded() throws {
        let new = #"{"note": "v2", "regionalPremium": 1.1, "models": {"a": {"input": 1}, "b": {"input": 2}, "c": {"input": 3}}}"#
        let out = try merge(user: v1, old: v1, new: new)
        #expect(input(out, "c") == 3)
        #expect(out["note"] as? String == "v2")
    }

    @Test func untouchedValuesFollowTheBundle() throws {
        let new = #"{"note": "v1", "regionalPremium": 1.2, "models": {"a": {"input": 1.5}, "b": {"input": 2}}}"#
        let out = try merge(user: v1, old: v1, new: new)
        #expect(input(out, "a") == 1.5)
        #expect((out["regionalPremium"] as? NSNumber)?.doubleValue == 1.2)
    }

    @Test func editsNullsAndDeletionsStay() throws {
        let mine = #"{"note": "mine", "regionalPremium": 1, "models": {"a": {"input": 9}, "b": null}}"#
        let old = #"{"note": "v1", "regionalPremium": 1.1, "models": {"a": {"input": 1}, "b": {"input": 2}, "d": {"input": 4}}}"#
        let new = #"{"note": "v2", "regionalPremium": 1.2, "models": {"a": {"input": 1.5}, "b": {"input": 2.5}, "d": {"input": 5}}}"#
        let out = try merge(user: mine, old: old, new: new)
        #expect(input(out, "a") == 9)
        #expect(models(out)["b"] is NSNull)
        #expect(models(out)["d"] == nil)
        #expect((out["regionalPremium"] as? NSNumber)?.doubleValue == 1)
        #expect(out["note"] as? String == "v2")
    }

    @Test func firstRunAddsMissingModelsOnly() throws {
        let mine = #"{"note": "v0", "models": {"a": {"input": 1}, "b": null}}"#
        let new = #"{"note": "v2", "regionalPremium": 1.2, "models": {"a": {"input": 1.5}, "b": {"input": 2}, "c": {"input": 3}}}"#
        let out = try merge(user: mine, old: nil, new: new)
        #expect(input(out, "a") == 1)
        #expect(models(out)["b"] is NSNull)
        #expect(input(out, "c") == 3)
        #expect(out["regionalPremium"] == nil)
    }

    @Test func noWriteWhenNothingChanged() throws {
        let mine = #"{"models":{"a":{"input":9}},"note":"v1","regionalPremium":1.1}"#
        // Same bundle as base: skipped before the user's file is read.
        _ = try merge(user: mine, old: v1, new: v1)
        #expect(try Data(contentsOf: user) == Data(mine.utf8))
        // New bundle, but every difference is the user's own.
        let new = #"{"note": "v1", "regionalPremium": 1.1, "models": {"a": {"input": 1.5}}}"#
        _ = try merge(user: mine, old: v1, new: new)
        #expect(try Data(contentsOf: user) == Data(mine.utf8))
    }

    @Test func unparseableUserFileIsLeftAlone() throws {
        try write(v1, to: base)
        try write(#"{"models": {"a": "#, to: user)
        try write(#"{"models": {"a": {"input": 1}, "c": {"input": 3}}}"#, to: bundled)
        Pricing.merge(bundled: bundled, into: user, base: base)
        #expect(try Data(contentsOf: user) == Data(#"{"models": {"a": "#.utf8))
        #expect(try Data(contentsOf: base) == Data(v1.utf8))
    }

    @Test func missingUserFileGetsTheBundle() throws {
        try write(v1, to: bundled)
        Pricing.merge(bundled: bundled, into: user, base: base)
        #expect(try Data(contentsOf: user) == Data(v1.utf8))
        #expect(try Data(contentsOf: base) == Data(v1.utf8))
    }
}
