import Foundation
import os
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

@Suite struct UpdaterTextTests {
    typealias Phase = Updater.Phase

    @Test(arguments: [
        (Phase.checking, "Checking…"),
        (.checkFailed("offline"), "Couldn't check for updates: offline"),
        (.available("v0.7"), "v0.7 is available"),
        (.downloading("v0.7", .init(received: 3_100_000, expected: 8_400_000)), "Downloading v0.7, 3.1 MB of 8.4 MB"),
        (.downloading("v0.7", .init(received: 3_100_000)), "Downloading v0.7, 3.1 MB"),
        (.downloading("v0.7", .init()), "Downloading v0.7, 0 bytes"),
        (.source("v0.7", .init(received: 1_200_000, expected: 2_000_000)), "Getting v0.7 source, 1.2 MB"),
        (.compiling("v0.7", nil), "Compiling v0.7"),
        (.compiling("v0.7", .init(n: 412, m: 980, stable: true)), "Compiling v0.7, step 412 of 980"),
        (.compiling("v0.7", .init(n: 16, m: 21, stable: false)), "Compiling v0.7, step 16 of 21"),
        (.assembling("v0.7"), "Assembling Burn.app"),
        (.installing("v0.7"), "Installing v0.7…"),
        (.failed("v0.7", "tar exited 1: bad"), "Update failed: tar exited 1: bad"),
        (.relaunchFailed("v0.7"), "Updated to v0.7. Quit and reopen Burn to finish."),
    ])
    func caption(phase: Phase, text: String) {
        #expect(Updater.caption(phase, installed: true, checked: nil, prebuiltFailed: false) == text)
    }

    @Test func captionDependsOnCheckInstallAndFallback() {
        let now = Date()
        let at = now.formatted(date: .omitted, time: .shortened)
        #expect(Updater.caption(.idle, installed: true, checked: nil, prebuiltFailed: false) == "Not checked yet")
        #expect(Updater.caption(.idle, installed: true, checked: now, prebuiltFailed: false, now: now) == "Last checked today at \(at)")
        #expect(Updater.caption(.current, installed: true, checked: now, prebuiltFailed: false, now: now) == "Up to date. Last checked today at \(at)")
        #expect(Updater.caption(.available("v0.7"), installed: false, checked: now, prebuiltFailed: false)
            == "v0.7 is available. Only a copy in Applications can update itself.")
        #expect(Updater.caption(.source("v0.7", .init(received: 1_200_000)), installed: true, checked: nil, prebuiltFailed: true)
            == "Download failed. Getting v0.7 source, 1.2 MB")
    }

    @Test func lastChecked() throws {
        let cal = Calendar.current
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 5)))
        let morning = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 0, minute: 1)))
        let lateYesterday = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 23, minute: 59)))
        let older = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 14, minute: 32)))
        #expect(Updater.lastChecked(morning, now: now) == "today at \(morning.formatted(date: .omitted, time: .shortened))")
        #expect(Updater.lastChecked(lateYesterday, now: now) == "yesterday at \(lateYesterday.formatted(date: .omitted, time: .shortened))")
        #expect(Updater.lastChecked(older, now: now) == older.formatted(date: .abbreviated, time: .shortened))
    }

    @Test(arguments: [
        ("[28\u{2009}/\u{2009}139]", 28, 139), ("[137\u{2009}/\u{2009}139] Burn-product", 137, 139),
        ("[28 / 139]", 28, 139), ("[412/980] Compiling Burn Updater.swift", 412, 980),
    ])
    func step(line: String, n: Int, m: Int) throws {
        let s = try #require(Updater.step(line[...]))
        #expect(s.0 == n && s.1 == m)
    }

    @Test(arguments: ["[Planning deferred tasks]", "Building for production...", "Build complete! (29.74 secs)", " [1/2]", "[1/]"])
    func noStep(line: String) {
        #expect(Updater.step(line[...]) == nil)
    }

    @Test func barWaitsForAStableTotal() {
        var s: Updater.Step?
        var bars: [Double?] = []
        for (n, m) in [(16, 21), (17, 22), (28, 139), (29, 139), (100, 139), (101, 150), (102, 150), (138, 139), (5, 0), (6, 0)] {
            s = Updater.advance(s, n, m)
            #expect(s?.n == n && s?.m == m)
            bars.append(s?.fraction)
        }
        let expected: [Double?] = [nil, nil, nil, 29.0 / 139, 100.0 / 139, nil, 102.0 / 150, nil, nil, nil]
        #expect(bars == expected)
    }

    @Test func linesAcrossChunks() {
        var rest = Data()
        #expect(Updater.lines(&rest, adding: Data("[1 / 3]\n[2 ".utf8)) == ["[1 / 3]"])
        #expect(Updater.lines(&rest, adding: Data("/ 3]".utf8)) == [])
        #expect(Updater.lines(&rest, adding: Data("\r\nBuild complete!\n".utf8)) == ["[2 / 3]", "Build complete!"])
        #expect(rest.isEmpty)
    }

    @Test func announcesOutcomesOnly() {
        #expect(UpdaterRow.announces(from: .checking, to: .current))
        #expect(UpdaterRow.announces(from: .checking, to: .available("v0.7")))
        #expect(UpdaterRow.announces(from: .assembling("v0.7"), to: .installing("v0.7")))
        #expect(UpdaterRow.announces(from: .checking, to: .checkFailed("x")))
        #expect(UpdaterRow.announces(from: .downloading("v0.7", .init()), to: .failed("v0.7", "x")))
        #expect(!UpdaterRow.announces(from: .compiling("v0.7", nil), to: .available("v0.7")))
        #expect(!UpdaterRow.announces(from: .downloading("v0.7", .init()), to: .downloading("v0.7", .init(received: 1))))
    }
}

@Suite struct UpdaterRunTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnupdater-run-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @Test func streamsLinesAndReportsTheLastOnFailure() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let error = await #expect(throws: Updater.Failure.self) {
            try await Updater.run("/bin/bash", ["-c", "for i in 1 2 3; do echo \"[$i / 3]\"; done; echo boom >&2; exit 4"], log: dir) { l in
                seen.withLock { $0.append(String(l)) }
            }
        }
        #expect(seen.withLock { $0 } == ["[1 / 3]", "[2 / 3]", "[3 / 3]", "boom"])
        #expect(error?.errorDescription == "bash exited 4: boom")
    }

    @Test(.timeLimit(.minutes(1))) func cancelEndsTheWholeProcessGroup() async throws {
        let marker = "burn-cancel-\(UUID().uuidString)"
        let task = Task { try await Updater.run("/bin/bash", ["-c", "exec -a \(marker) sleep 30 & wait"], log: dir) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(pgrep(marker))
        let cancelled = ContinuousClock.now
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(cancelled.duration(to: .now) < .seconds(5))
        #expect(!pgrep(marker))
    }

    private func pgrep(_ pattern: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", pattern]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

/// Real downloads and a real source build into a temp dir. BURN_UPDATER_E2E=1 scripts/test.sh --filter UpdaterNetwork
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BURN_UPDATER_E2E"] != nil), .serialized)
struct UpdaterNetworkTests {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("burnupdater-e2e-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    let events = OSAllocatedUnfairLock(initialState: [Updater.Event]())

    private var record: @Sendable (Updater.Event) -> Void { { [events] e in events.withLock { $0.append(e) } } }

    @Test func latestAndPrebuilt() async throws {
        let tag = try await Updater.latestTag()
        let app = try await Updater.prebuilt(tag, in: work, report: record)
        let seen = events.withLock { $0 }
        print("prebuilt", tag, app.path, seen)
        #expect(getxattr(work.appendingPathComponent("Burn.tar.gz").path, "com.apple.quarantine", nil, 0, 0, 0) == -1)
        #expect(seen.contains { if case .bytes(let n, _) = $0 { n > 100_000 } else { false } })
    }

    @Test(.timeLimit(.minutes(10))) func sourceBuild() async throws {
        let tag = try await Updater.latestTag()
        let app = try await Updater.fromSource(tag, in: work, report: record)
        let seen = events.withLock { $0 }
        print("source", tag, app.path, seen.count, "events", seen.suffix(3))
        #expect(seen.contains { if case .step = $0 { true } else { false } })
        #expect(seen.contains { if case .assembling = $0 { true } else { false } })
    }

    @Test(.timeLimit(.minutes(5))) func cancelStopsTheBuild() async throws {
        let tag = try await Updater.latestTag()
        let (steps, step) = AsyncStream.makeStream(of: Void.self)
        let task = Task { [work] in
            try await Updater.fromSource(tag, in: work) { if case .step = $0 { step.yield() } }
        }
        for await _ in steps { break }
        let cancelled = ContinuousClock.now
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(cancelled.duration(to: .now) < .seconds(5))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", work.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 1, "something from the build is still running")
    }
}
