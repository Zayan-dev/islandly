import AppKit
import SwiftUI

// GitHub Actions in the notch: runs you trigger show a progress ring beside the notch, and the island flashes
// ✅ / ❌ (with the failing job and step) when they finish. Uses your own `gh` CLI login, so there's nothing to
// set up and no token is stored by Islandly. Only GitHub's API is contacted.

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
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "ciEnabled")
            if enabled { lastPoll = .distantPast } else { running = [] }
        }
    }

    var onStart: ((CIRun) -> Void)?
    var onFinish: ((CIRun) -> Void)?

    static let ghPath: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static var available: Bool { ghPath != nil }

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
    }

    /// Called once a second. Polls every 60 s, every 15 s right after a push, every 8 s while a run is going.
    func tick(_ now: Date) {
        guard enabled, let gh = Self.ghPath, !busy else { return }
        let interval: TimeInterval = !running.isEmpty ? 8 : (hot ? 15 : 60)
        guard now.timeIntervalSince(lastPoll) >= interval else { return }
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

    private func apply(_ result: FetchResult?) {
        guard enabled else { return }
        guard let result else { needsLogin = true; return }
        needsLogin = false
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

    struct FetchResult {
        let login: String
        let runs: [CIRun]
        let hot: Bool
    }

    private static func fetch(gh: String, login: String?, alsoCheck: [String], since: Date) -> FetchResult? {
        guard let login = login ?? (api(gh, "user") as? [String: Any])?["login"] as? String else { return nil }
        guard let repos = api(gh, "user/repos?sort=pushed&per_page=8") as? [[String: Any]] else { return nil }
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
        return FetchResult(login: login, runs: runs, hot: hot)
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

// MARK: - Views

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
