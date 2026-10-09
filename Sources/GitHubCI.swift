import AppKit
import CryptoKit
import SwiftUI

// GitHub Actions in the notch: runs you trigger show a progress ring beside the notch, and the island flashes
// ✅ / ❌ (with the failing job and step) when they finish. Uses your own `gh` CLI login, so there's nothing to
// set up and no token is stored by Islandly. Only GitHub's API is contacted.
// It notices your own `git push` instantly (macOS file-change events on the repo's remote refs, no disk scanning),
// so idle polling can stay slow: every 5 minutes, every 15 s right after a push, every 8 s while a run is going.
// No `gh`, or not logged in? One click sets it up: Islandly downloads the official GitHub CLI for itself (checksum
// verified, no admin password, no Homebrew), then opens GitHub's login page with the one-time code ready to paste.

struct CIRun: Identifiable, Equatable {
    let id: Int
    let repo: String        // owner/name
    let workflow: String
    let branch: String
    let title: String
    let url: URL?
    let started: Date
    var status: String      // queued, in_progress, completed…
    var conclusion: String?
    var updated: Date
    var progress: Double = 0
    var failedStep: String?

    var repoName: String { repo.split(separator: "/").last.map(String.init) ?? repo }
    var isActive: Bool { status != "completed" }
    var succeeded: Bool { conclusion == "success" }
    var duration: TimeInterval { (isActive ? Date() : updated).timeIntervalSince(started) }
}

final class GitHubCI: ObservableObject {
    @Published private(set) var running: [CIRun] = []
    /// `gh` is installed but not logged in.
    @Published private(set) var needsLogin = false
    /// One-click setup in progress (shown as a card in the notch).
    enum SetupStep: Equatable { case installing, waiting(code: String), done, failed(String) }
    @Published private(set) var setup: SetupStep?

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "ciEnabled")
            if enabled { lastPoll = .distantPast } else { running = []; pushes.stop() }
        }
    }

    var onStart: ((CIRun) -> Void)?
    var onFinish: ((CIRun) -> Void)?

    /// Islandly's own copy, installed by the one-click setup when there's no `gh` on the Mac.
    static let privateGh = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Islandly/bin/gh").path
    private(set) static var ghPath = findGh()
    private static func findGh() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh", privateGh].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var available: Bool { ghPath != nil }
    /// No `gh` yet, or it isn't logged in: the one-click setup applies.
    var wantsSetup: Bool { !Self.available || needsLogin }

    private var loginProcess: Process?
    private let pushes = PushWatcher()
    /// A push was just seen: look a few seconds from now (GitHub needs a moment to create the run).
    private var pollAt: Date?

    private let launched = Date()
    private var login: String?
    private var announced: Set<Int> = []     // started runs already shown
    private var finished: Set<Int> = []      // finished runs already shown
    private var lastPoll = Date.distantPast
    /// A repo was pushed to in the last few minutes: look more often, a run is probably about to start.
    private var hot = false
    private var busy = false
    private let queue = DispatchQueue(label: "app.islandly.ci", qos: .utility)

    init() {
        enabled = UserDefaults.standard.object(forKey: "ciEnabled") as? Bool ?? true
        pushes.onPush = { [weak self] in self?.pushDetected() }
    }

    private var lastPushSeen = Date.distantPast

    private func pushDetected() {
        // One push touches several ref files, which can arrive as two event batches: count it once.
        guard enabled, !needsLogin, Date().timeIntervalSince(lastPushSeen) > 10 else { return }
        lastPushSeen = Date()
        hot = true
        let soon = Date().addingTimeInterval(4)
        if pollAt == nil || soon < pollAt! { pollAt = soon }
    }

    /// Called once a second. Polls every 60 s, every 15 s right after a push, every 8 s while a run is going.
    func tick(_ now: Date) {
        guard enabled, let gh = Self.ghPath, !busy else { return }
        guard setup == nil || setup == .done else { return }
        // Idle (and not logged in) every 5 minutes; pushes are caught by the watcher instead.
        let interval: TimeInterval = needsLogin ? 300 : (!running.isEmpty ? 8 : (hot ? 15 : 300))
        let pushed = pollAt.map { now >= $0 } ?? false
        guard pushed || now.timeIntervalSince(lastPoll) >= interval else { return }
        pollAt = nil
        busy = true
        lastPoll = now
        let known = running.map(\.repo)
        let knownLogin = login
        queue.async { [weak self] in
            guard let self else { return }
            let result = Self.fetch(gh: gh, login: knownLogin, alsoCheck: known, since: self.launched.addingTimeInterval(-15 * 60))
            DispatchQueue.main.async {
                self.busy = false
                self.apply(result)
            }
        }
    }

    private func apply(_ outcome: Outcome) {
        guard enabled else { return }
        let result: FetchResult
        switch outcome {
        case .notLoggedIn: needsLogin = true; pushes.stop(); return
        case .offline: return
        case .ok(let r): result = r
        }
        needsLogin = false
        pushes.start()
        login = result.login
        hot = result.hot
        var active: [CIRun] = []
        for run in result.runs {
            if run.isActive {
                active.append(run)
                if !announced.contains(run.id) {
                    announced.insert(run.id)
                    onStart?(run)
                }
            } else if !finished.contains(run.id) {
                finished.insert(run.id)
                // Runs that ended before Islandly started aren't news.
                if running.contains(where: { $0.id == run.id }) || run.updated > launched {
                    onFinish?(run)
                }
            }
        }
        running = active.sorted { $0.started > $1.started }
    }

    // MARK: GitHub API (through `gh api`, off the main thread)

    enum Outcome { case ok(FetchResult), notLoggedIn, offline }

    struct FetchResult {
        let login: String
        let runs: [CIRun]
        let hot: Bool
    }

    private static func fetch(gh: String, login: String?, alsoCheck: [String], since: Date) -> Outcome {
        guard let login = login ?? (api(gh, "user") as? [String: Any])?["login"] as? String else {
            return run(gh, ["auth", "status", "-h", "github.com"]) == 0 ? .offline : .notLoggedIn
        }
        guard let repos = api(gh, "user/repos?sort=pushed&per_page=8") as? [[String: Any]] else { return .offline }
        let now = Date()
        var names = Set(alsoCheck)
        var hot = false
        for repo in repos {
            guard let name = repo["full_name"] as? String, let pushed = date(repo["pushed_at"]) else { continue }
            if now.timeIntervalSince(pushed) < 20 * 60 { names.insert(name) }
            if now.timeIntervalSince(pushed) < 4 * 60 { hot = true }
        }
        var runs: [CIRun] = []
        for repo in names.sorted().prefix(6) {
            guard let body = api(gh, "repos/\(repo)/actions/runs?per_page=6&actor=\(login)") as? [String: Any],
                  let list = body["workflow_runs"] as? [[String: Any]] else { continue }
            for item in list {
                guard let id = item["id"] as? Int, let created = date(item["created_at"]), created >= since else { continue }
                var run = CIRun(id: id, repo: repo,
                                workflow: item["name"] as? String ?? "CI",
                                branch: item["head_branch"] as? String ?? "",
                                title: item["display_title"] as? String ?? "",
                                url: (item["html_url"] as? String).flatMap(URL.init(string:)),
                                started: date(item["run_started_at"]) ?? created,
                                status: item["status"] as? String ?? "queued",
                                conclusion: item["conclusion"] as? String,
                                updated: date(item["updated_at"]) ?? now)
                if run.isActive || run.conclusion == "failure" {
                    // Progress = finished steps; on failure, the first step that failed.
                    if let jobs = (api(gh, "repos/\(repo)/actions/runs/\(id)/jobs") as? [String: Any])?["jobs"] as? [[String: Any]] {
                        var done = 0, total = 0
                        for job in jobs {
                            let steps = job["steps"] as? [[String: Any]] ?? []
                            total += max(steps.count, 1)
                            done += steps.isEmpty ? (job["status"] as? String == "completed" ? 1 : 0)
                                                  : steps.filter { $0["status"] as? String == "completed" }.count
                            if run.failedStep == nil, job["conclusion"] as? String == "failure" {
                                let step = steps.first { $0["conclusion"] as? String == "failure" }?["name"] as? String
                                run.failedStep = [job["name"] as? String, step].compactMap { $0 }.joined(separator: " › ")
                            }
                        }
                        run.progress = total > 0 ? Double(done) / Double(total) : 0
                    }
                }
                runs.append(run)
            }
        }
        return .ok(FetchResult(login: login, runs: runs, hot: hot))
    }

    private static func run(_ gh: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: One-click setup

    func startSetup() {
        guard setup == nil || setup == .done || { if case .failed = setup { return true }; return false }() else { return }
        enabled = true
        if let gh = Self.ghPath {
            login(gh)
            return
        }
        setup = .installing
        queue.async { [weak self] in
            let result = Self.installGh()
            DispatchQueue.main.async {
                guard let self, self.setup == .installing else { return }
                switch result {
                case .success(let gh):
                    Self.ghPath = Self.findGh()
                    self.login(gh)
                case .failure(let error):
                    self.setup = .failed(error.message)
                }
            }
        }
    }

    func cancelSetup() {
        loginProcess?.terminate()
        loginProcess = nil
        setup = nil
    }

    func finishSetup() { setup = nil }

    /// `gh auth login --web` without a terminal prints a one-time code and waits until it's approved on github.com.
    /// Islandly shows the code (and copies it), opens the page, and moves on when gh exits.
    private func login(_ gh: String) {
        setup = .waiting(code: "")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "login", "--web", "-h", "github.com", "--skip-ssh-key"]
        var env = ProcessInfo.processInfo.environment
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = input
        var shown = false
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !shown, let range = text.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) else { return }
            shown = true
            let code = String(text[range])
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loginProcess === process else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                self.setup = .waiting(code: code)
                Self.openDevicePage()
            }
        }
        process.terminationHandler = { [weak self] p in
            output.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.loginProcess === p else { return }
                self.loginProcess = nil
                if p.terminationStatus == 0 {
                    self.needsLogin = false
                    self.login = nil
                    self.lastPoll = .distantPast
                    self.setup = .done
                    NSSound(named: "Hero")?.play()
                } else {
                    self.setup = .failed("The GitHub login didn't finish. The code may have expired.")
                }
            }
        }
        do {
            try process.run()
            loginProcess = process
            input.fileHandleForWriting.write(Data("\n".utf8))
        } catch {
            setup = .failed("Couldn't start the GitHub CLI.")
        }
    }

    static func openDevicePage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/login/device")!)
    }

    struct SetupError: Error { let message: String }

    /// Downloads the official GitHub CLI release for this Mac into Islandly's folder and checks its SHA-256
    /// against the release's published checksums.
    private static func installGh() -> Result<String, SetupError> {
        func get(_ url: URL) -> Data? {
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue("Islandly", forHTTPHeaderField: "User-Agent")
            var result: Data?
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
                done.signal()
            }.resume()
            done.wait()
            return result
        }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        guard let data = get(URL(string: "https://api.github.com/repos/cli/cli/releases/latest")!),
              let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = release["assets"] as? [[String: Any]] else {
            return .failure(SetupError(message: "Couldn't reach GitHub. Check your internet and try again."))
        }
        func asset(_ test: (String) -> Bool) -> (name: String, url: URL)? {
            for a in assets {
                if let name = a["name"] as? String, test(name),
                   let link = a["browser_download_url"] as? String, let url = URL(string: link),
                   url.host == "github.com" { return (name, url) }
            }
            return nil
        }
        guard let zip = asset({ $0.hasSuffix("_macOS_\(arch).zip") }),
              let sums = asset({ $0.hasSuffix("_checksums.txt") }),
              let sumsData = get(sums.url), let zipData = get(zip.url) else {
            return .failure(SetupError(message: "Couldn't download the GitHub CLI. Try again in a moment."))
        }
        let hash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let expected = String(decoding: sumsData, as: UTF8.self).split(separator: "\n")
            .first { $0.hasSuffix(" \(zip.name)") }?.split(separator: " ").first.map(String.init)
        guard hash == expected else {
            return .failure(SetupError(message: "The download didn't match GitHub's checksum, so it wasn't installed."))
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("islandly-gh-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let archive = temp.appendingPathComponent(zip.name)
            try zipData.write(to: archive)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archive.path, temp.path]
            try unzip.run()
            unzip.waitUntilExit()
            let folder = zip.name.replacingOccurrences(of: ".zip", with: "")
            let binary = temp.appendingPathComponent("\(folder)/bin/gh")
            guard fm.isExecutableFile(atPath: binary.path) else { throw SetupError(message: "") }
            let destination = URL(fileURLWithPath: privateGh)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: binary, to: destination)
            return .success(destination.path)
        } catch {
            return .failure(SetupError(message: "Couldn't install the GitHub CLI."))
        }
    }

    private static func api(_ gh: String, _ path: String) -> Any? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", path]
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static let iso = ISO8601DateFormatter()
    private static func date(_ value: Any?) -> Date? { (value as? String).flatMap { iso.date(from: $0) } }
}

// MARK: - Push watcher

/// Tells when you push from anywhere on this Mac (terminal, editor, GitHub Desktop, an agent): a push rewrites
/// `.git/refs/remotes/…` in that repo. Uses FSEvents, the kernel's change journal that Spotlight already keeps:
/// directory-level only, batched every 2 s, media and Library folders excluded, so there's no scanning and no
/// polling. A `git fetch` also touches those refs; that just costs one extra check.
final class PushWatcher {
    var onPush: (() -> Void)?
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "app.islandly.push-watcher", qos: .utility)

    func start() {
        guard stream == nil else { return }
        let home = NSHomeDirectory()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<PushWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.contains(where: { $0.contains("/.git/refs/remotes/") || $0.contains("/.git/logs/refs/remotes/") }) {
                DispatchQueue.main.async { watcher.onPush?() }
            }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [home] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf))
        else { return }
        let skip = ["Library", ".Trash", "Pictures", "Movies", "Music", ".cache", ".npm", ".Trash"].map { home + "/" + $0 }
        FSEventStreamSetExclusionPaths(stream, Array(Set(skip)).prefix(8).map { $0 } as CFArray)
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

// MARK: - Views

/// The one-click setup, step by step, as a notch card.
struct CISetupCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let ci = model.ci
        switch ci.setup {
        case .installing:
            NotchCardLayout(model: model, symbol: "arrow.down", tint: .yellow,
                            title: "Setting up GitHub CI…", subtitle: "Downloading the official GitHub CLI from github.com.") {
                ProgressView().controlSize(.small).tint(.yellow)
                Text("No password needed").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            } buttons: {
                CardButton(title: "Cancel") { ci.cancelSetup() }
            }
        case .waiting(let code):
            NotchCardLayout(model: model, symbol: "person.badge.key.fill", tint: .yellow,
                            title: code.isEmpty ? "Connecting to GitHub…" : "Paste this code on GitHub",
                            subtitle: code.isEmpty ? "Getting a one-time code." : "Then click Authorize on the page that just opened.") {
                if code.isEmpty {
                    ProgressView().controlSize(.small).tint(.yellow)
                } else {
                    Text(code).font(.system(size: 18, weight: .bold, design: .monospaced)).foregroundStyle(.yellow)
                        .textSelection(.enabled)
                    Text("Copied").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            } buttons: {
                CardButton(title: "Cancel") { ci.cancelSetup() }
                if !code.isEmpty {
                    CardButton(title: "Open GitHub", primary: true, tint: .yellow) { GitHubCI.openDevicePage() }
                }
            }
        case .done:
            NotchCardLayout(model: model, symbol: "checkmark", tint: .green,
                            title: "GitHub connected", subtitle: "Push to a repo with Actions and your CI shows up right here.") {
                Text("Right-click the notch to turn it off").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            } buttons: {
                CardButton(title: "Done", primary: true, tint: .green) { ci.finishSetup() }
            }
        case .failed(let message):
            NotchCardLayout(model: model, symbol: "exclamationmark.triangle.fill", tint: .orange,
                            title: "Setup didn't finish", subtitle: message) {
                EmptyView()
            } buttons: {
                CardButton(title: "Close") { ci.cancelSetup() }
                CardButton(title: "Try again", primary: true, tint: .orange) { ci.startSetup() }
            }
        case nil:
            EmptyView()
        }
    }
}

/// The progress ring shown beside the notch and in the chip.
struct CIRing: View {
    let progress: Double
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: size * 0.16)
            Circle()
                .trim(from: 0, to: max(0.06, min(1, progress)))
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)
        }
        .frame(width: size, height: size)
    }
}

struct CIChip: View {
    @ObservedObject var model: IslandModel
    let run: CIRun

    var body: some View {
        Button {
            if let url = run.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                CIRing(progress: run.progress, size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(run.workflow) · \(run.repoName)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(run.branch) · \(run.status == "queued" ? "queued" : "running") \(formatDuration(max(0, model.system.now.timeIntervalSince(run.started)))) · \(Int(run.progress * 100))%")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(height: 46)
            .card(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this run on GitHub")
    }
}
