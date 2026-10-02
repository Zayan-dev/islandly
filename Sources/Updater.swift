import AppKit

/// Keeps Islandly up to date with the GitHub checkout it was installed from.
///
/// Checking is a `git fetch` in that folder a few times a day (nothing about you is sent, and it can be turned off).
/// Updating only happens when you click: `git pull`, a rebuild on this Mac, then `install.sh` swaps the app and
/// relaunches it. No downloads of pre-built binaries, so what runs is always what's in the repo.
final class UpdateModel: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(count: Int, changes: [String])
        case updating(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The "update ready" card is showing (from a new version being found, or an update you started).
    @Published private(set) var offer = false
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck") }
    }
    /// A check you started found nothing new (new versions show the update card instead).
    var onResult: ((Int) -> Void)?

    /// The git checkout Islandly was built from, if it can be found.
    let repo: URL?
    /// Commit this copy was built from (stamped into Info.plist by build.sh).
    let installedCommit = Bundle.main.object(forInfoDictionaryKey: "IslandlyCommit") as? String

    private static let checkEvery: TimeInterval = 6 * 3600
    private var nextCheck = Date().addingTimeInterval(45)   // shortly after launch, then every 6 h
    private let queue = DispatchQueue(label: "islandly.updater", qos: .utility)

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true
        repo = Self.findRepo()
    }

    var canUpdate: Bool { repo != nil }
    var isAvailable: Bool { if case .available = state { return true }; return false }
    var availableChanges: [String] { if case .available(_, let changes) = state { return changes }; return [] }

    /// "Later" (or Close after a failure): the green arrow stays; the card comes back for the next new version.
    func dismissOffer() {
        offer = false
        if case .failed = state { state = .idle; nextCheck = Date().addingTimeInterval(60) }
    }
    var isUpdating: Bool { if case .updating = state { return true }; return false }
    /// The island shows its update button only when there's something to act on.
    var showsButton: Bool {
        switch state {
        case .available, .updating, .failed: return true
        default: return false
        }
    }
    var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return installedCommit.map { "Islandly \(version) (\($0.prefix(7)))" } ?? "Islandly \(version)"
    }

    /// Called every second by the island; does real work only when a check is due.
    func tick(_ now: Date) {
        guard autoCheck, repo != nil, now >= nextCheck, !isUpdating, state != .checking else { return }
        check()
    }

    func check(userInitiated: Bool = false) {
        guard let repo, !isUpdating else { return }
        nextCheck = Date().addingTimeInterval(Self.checkEvery)
        let previous = state
        if userInitiated { state = .checking }
        let base = installedCommit
        queue.async {
            let result = Self.newCommits(in: repo, since: base)
            DispatchQueue.main.async {
                guard !self.isUpdating else { return }
                switch result {
                case .success(let changes) where changes.isEmpty:
                    self.state = userInitiated ? .upToDate : .idle
                    if userInitiated { self.onResult?(0) }
                case .success(let commits):
                    let changes = commits.map(\.subject)
                    self.state = .available(count: changes.count, changes: Array(changes.prefix(5)))
                    // Announce each new upstream head once, not on every check.
                    let head = commits.first?.hash ?? ""
                    if userInitiated || UserDefaults.standard.string(forKey: "updateAnnounced") != head {
                        UserDefaults.standard.set(head, forKey: "updateAnnounced")
                        self.offer = true
                    }
                case .failure(let message):
                    // A background check failing (offline, etc.) isn't worth bothering anyone about.
                    self.state = userInitiated ? .failed(message) : previous
                }
            }
        }
    }

    /// Pull, rebuild, then hand over to install.sh, which replaces the app and relaunches it.
    func update() {
        guard let repo, !isUpdating else { return }
        offer = true   // the card shows progress until the restart
        state = .updating("Downloading the latest version…")
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        queue.async {
            let pull = Self.git(["pull", "--ff-only", "--quiet"], in: repo)
            guard pull.ok else {
                return self.fail("Couldn't pull the update (local changes in \(repo.path)?): \(pull.lastLine)")
            }
            DispatchQueue.main.async { self.state = .updating("Building on your Mac (about a minute)…") }
            let build = Self.run("/bin/bash", ["./build.sh"], in: repo, env: ["ARCHS": arch])
            guard build.ok else { return self.fail("Build failed: \(build.lastLine)") }

            DispatchQueue.main.async {
                self.state = .updating("Installing and restarting…")
                if self.runsFromCheckout {
                    relaunchApp()
                    return
                }
                // install.sh quits this copy, swaps in the new build and opens it; run it detached so it
                // outlives us. It installs next to the running app when that's an Applications folder.
                let appDir = Bundle.main.bundleURL.deletingLastPathComponent().path
                var env = "SKIP_BUILD=1"
                if appDir.hasSuffix("Applications") { env += " ISLANDLY_APP_DIR=\(Self.quote(appDir))" }
                let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Islandly-update.log").path
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.currentDirectoryURL = repo
                process.arguments = ["-c", "sleep 1; \(env) ./scripts/install.sh > \(Self.quote(log)) 2>&1"]
                do {
                    try process.run()
                    NSApp.terminate(nil)
                } catch {
                    self.state = .failed("Couldn't start the installer: \(error.localizedDescription)")
                }
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.state = .failed(message) }
    }

    // MARK: Git

    private enum CheckResult { case success([(hash: String, subject: String)]), failure(String) }

    /// Subjects of the commits upstream has that this build doesn't, newest first.
    private static func newCommits(in repo: URL, since installed: String?) -> CheckResult {
        let fetch = git(["fetch", "--quiet"], in: repo)
        guard fetch.ok else { return .failure("Couldn't reach GitHub: \(fetch.lastLine)") }
        // Compare against what's installed; fall back to the checkout if this build predates the stamp.
        var base = "HEAD"
        if let installed, git(["cat-file", "-e", "\(installed)^{commit}"], in: repo).ok { base = installed }
        let log = git(["log", "--format=%H %s", "\(base)..@{upstream}"], in: repo)
        guard log.ok else { return .failure("This checkout doesn't track a GitHub branch.") }
        return .success(log.output.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
        })
    }

    private static func git(_ args: [String], in repo: URL) -> (ok: Bool, output: String, lastLine: String) {
        run("/usr/bin/git", args, in: repo, env: ["GIT_TERMINAL_PROMPT": "0"], timeout: 60)
    }

    private static func run(_ path: String, _ args: [String], in dir: URL, env: [String: String] = [:],
                            timeout: TimeInterval = 600) -> (ok: Bool, output: String, lastLine: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (false, "", error.localizedDescription) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        let output = String(decoding: data, as: UTF8.self)
        let last = output.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
        return (process.terminationStatus == 0, output, String(last.prefix(160)))
    }

    private static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Finding the checkout

    /// Running straight from the checkout (`./build.sh && open build/Islandly.app`): rebuild in place, no install.
    private var runsFromCheckout: Bool {
        guard let repo else { return false }
        return Bundle.main.bundleURL.standardizedFileURL == repo.appendingPathComponent("build/Islandly.app").standardizedFileURL
    }

    /// install.sh records the checkout's path; older installs are found through the `notch` command's symlink,
    /// and a copy run from `build/` knows its checkout is two folders up.
    private static func findRepo() -> URL? {
        var candidates: [URL] = [Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()]
        if let saved = UserDefaults.standard.string(forKey: "sourcePath") { candidates.append(URL(fileURLWithPath: saved)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for bin in ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"] {
            let link = "\(bin)/notch"
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link) {
                let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: bin)).standardizedFileURL
                candidates.append(resolved.deletingLastPathComponent().deletingLastPathComponent())
            }
        }
        return candidates.first { url in
            let fm = FileManager.default
            return fm.fileExists(atPath: url.appendingPathComponent(".git").path)
                && fm.fileExists(atPath: url.appendingPathComponent("build.sh").path)
                && fm.fileExists(atPath: url.appendingPathComponent("scripts/install.sh").path)
        }
    }
}

