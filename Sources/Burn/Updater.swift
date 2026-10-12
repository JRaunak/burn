import AppKit
import Foundation

/// Mirrors install.sh: the prebuilt release asset, else a source build of the same tag.
/// With the daily check off, Burn only touches the network when the user clicks Check now.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repo = "JRaunak/burn"
    nonisolated static let installCommand = "curl -fsSL https://raw.githubusercontent.com/\(repo)/master/install.sh | bash"

    enum Phase: Equatable { case idle, checking, current(String), available(String), downloading, building, failed(String) }

    @Published private(set) var phase = Phase.idle
    @Published var daily = UserDefaults.standard.bool(forKey: "update.daily") {
        didSet {
            UserDefaults.standard.set(daily, forKey: "update.daily")
            schedule()
        }
    }
    private var scheduler: NSBackgroundActivityScheduler?

    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var busy: Bool { [.checking, .downloading, .building].contains(phase) }

    var line: String {
        switch phase {
        case .idle: "Burn v\(version)"
        case .checking: "Checking…"
        case .current: "Up to date (v\(version))"
        case .available(let tag): LoginItem.installed ? "\(tag) available" : "\(tag) available. Only a copy in Applications updates itself."
        case .downloading: "Downloading…"
        case .building: "Building from source, about a minute…"
        case .failed(let e): e
        }
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
        let last = UserDefaults.standard.object(forKey: "update.checked") as? Date ?? .distantPast
        if daily, last.timeIntervalSinceNow < -20 * 3600 { await check() }
    }

    func check() async {
        guard !busy else { return }
        phase = .checking
        do {
            let tag = try await Self.latestTag()
            UserDefaults.standard.set(Date(), forKey: "update.checked")
            phase = Self.isNewer(tag, than: version) ? .available(tag) : .current(tag)
        } catch {
            phase = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    func update(to tag: String) async {
        guard !busy, LoginItem.installed else { return }
        let target = Bundle.main.bundleURL
        do {
            // On the target's volume, so the swap is a rename.
            let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? FileManager.default.removeItem(at: work) }
            phase = .downloading
            let app: URL
            do {
                app = try await Self.prebuilt(tag, in: work)
            } catch let download {
                phase = .building
                do {
                    app = try await Self.fromSource(tag, in: work)
                } catch {
                    throw Failure("download: \(download.localizedDescription); source build: \(error.localizedDescription)")
                }
            }
            try Self.install(app, over: target)
        } catch {
            phase = .failed("Update failed (\(error.localizedDescription)). To reinstall by hand: \(Self.installCommand)")
            return
        }
        do { try Self.relaunch(target) } catch { phase = .failed("Updated to \(tag). Quit and reopen Burn to finish.") }
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

    nonisolated static func prebuilt(_ tag: String, in work: URL) async throws -> URL {
        #if arch(arm64)
        let archive = work.appendingPathComponent("Burn.tar.gz"), dir = work.appendingPathComponent("prebuilt")
        try await download("https://github.com/\(repo)/releases/download/\(tag)/Burn.tar.gz", to: archive)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", dir.path], log: work)
        let app = dir.appendingPathComponent("Burn.app")
        try verify(app, tag: tag)
        return app
        #else
        throw Failure("releases are built for Apple silicon only")
        #endif
    }

    nonisolated static func fromSource(_ tag: String, in work: URL) async throws -> URL {
        do { try await run("/usr/bin/xcode-select", ["-p"], log: work) } catch {
            throw Failure("it needs the Command Line Tools: xcode-select --install")
        }
        let archive = work.appendingPathComponent("source.tar.gz"), src = work.appendingPathComponent("src")
        try await download("https://codeload.github.com/\(repo)/tar.gz/refs/tags/\(tag)", to: archive)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", src.path, "--strip-components", "1"], log: work)
        try await run("/bin/bash", [src.appendingPathComponent("build.sh").path], log: work,
                      env: ["BURN_VERSION": String(tag.drop { $0 == "v" })])
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

    private nonisolated static func download(_ url: String, to file: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: URL(string: url)!)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure("\(URL(string: url)?.host ?? url) returned \(code)") }
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    /// Output goes to a file because a full pipe would stall build.sh; its last line is the error.
    private nonisolated static func run(_ tool: String, _ args: [String], log dir: URL, env: [String: String] = [:]) async throws {
        let log = dir.appendingPathComponent("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        p.standardOutput = out
        p.standardError = out
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            p.terminationHandler = { p in
                try? out.close()
                guard p.terminationStatus != 0 else { return c.resume() }
                let last = (try? String(contentsOf: log, encoding: .utf8))?
                    .split(separator: "\n").last.map(String.init) ?? ""
                c.resume(throwing: Failure("\((tool as NSString).lastPathComponent) exited \(p.terminationStatus): \(last)"))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}
