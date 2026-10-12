import Foundation
import Testing
@testable import Burn

@Suite struct UpdaterTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnupdater-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A Burn.app skeleton with the given identifier and version.
    private func app(_ name: String, id: String = "local.burn", version: String = "0.6", executable: Bool = true) throws -> URL {
        let app = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if executable {
            let bin = app.appendingPathComponent("Contents/MacOS/Burn").path
            FileManager.default.createFile(atPath: bin, contents: Data(name.utf8), attributes: [.posixPermissions: 0o755])
        }
        return app
    }

    @Test(arguments: [
        ("https://github.com/JRaunak/burn/releases/tag/v0.5", "v0.5"),
        ("https://github.com/JRaunak/burn/releases/tag/v0.10", "v0.10"),
        ("/JRaunak/burn/releases/tag/v1.2.3", "v1.2.3"),
    ])
    func tagFromRedirect(location: String, tag: String) {
        #expect(Updater.tag(fromLocation: location) == tag)
    }

    @Test(arguments: [
        "https://github.com/JRaunak/burn/releases",
        "https://github.com/JRaunak/burn/releases/tag/",
        "https://github.com/JRaunak/burn/tree/tag/v0.5",
        "https://github.com/JRaunak/burn/releases/tag/nightly",
    ])
    func noTag(location: String) {
        #expect(Updater.tag(fromLocation: location) == nil)
    }

    @Test(arguments: [
        ("v0.10", "0.9", true), ("v0.6", "0.5", true), ("v1.0", "0.99", true), ("v0.5.1", "0.5", true),
        ("v0.5", "0.5", false), ("v0.5", "0.5.0", false), ("v0.5", "0.6", false), ("v0.9", "0.10", false),
        ("v0.6", "garbage", false), ("v0.6", "", false),
    ])
    func comparison(tag: String, version: String, newer: Bool) {
        #expect(Updater.isNewer(tag, than: version) == newer)
    }

    @Test func verifyAcceptsMatchingApp() throws {
        try Updater.verify(app("Burn.app"), tag: "v0.6")
    }

    @Test func verifyRejectsWrongIdVersionOrExecutable() throws {
        #expect(throws: Updater.Failure.self) { try Updater.verify(app("a.app", id: "com.other"), tag: "v0.6") }
        #expect(throws: Updater.Failure.self) { try Updater.verify(app("b.app", version: "0.5"), tag: "v0.6") }
        #expect(throws: Updater.Failure.self) { try Updater.verify(app("c.app", executable: false), tag: "v0.6") }
        #expect(throws: Updater.Failure.self) { try Updater.verify(dir.appendingPathComponent("missing.app"), tag: "v0.6") }
    }

    @Test func installSwapsBundleAndClearsQuarantine() throws {
        let old = try app("Installed.app", version: "0.5")
        let new = try app("New.app")
        let bin = new.appendingPathComponent("Contents/MacOS/Burn").path
        #expect(setxattr(bin, "com.apple.quarantine", "0081;0;Test;", 12, 0, 0) == 0)

        try Updater.install(new, over: old)

        #expect(try String(contentsOf: old.appendingPathComponent("Contents/MacOS/Burn"), encoding: .utf8) == "New.app")
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(getxattr(old.appendingPathComponent("Contents/MacOS/Burn").path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
        try Updater.verify(old, tag: "v0.6")
    }
}

/// Real downloads and a real source build into a temp dir. BURN_UPDATER_E2E=1 scripts/test.sh --filter UpdaterNetwork
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURN_UPDATER_E2E"] != nil), .serialized)
struct UpdaterNetworkTests {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("burnupdater-e2e-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    @Test func latestAndPrebuilt() async throws {
        let tag = try await Updater.latestTag()
        let app = try await Updater.prebuilt(tag, in: work)
        print("prebuilt", tag, app.path)
        #expect(getxattr(work.appendingPathComponent("Burn.tar.gz").path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
    }

    @Test(.timeLimit(.minutes(10))) func sourceBuild() async throws {
        let tag = try await Updater.latestTag()
        let app = try await Updater.fromSource(tag, in: work)
        print("source", tag, app.path)
    }
}
