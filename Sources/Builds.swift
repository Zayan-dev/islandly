import AppKit
import SwiftUI

/// A command run through the `notch` CLI (see bin/notch).
struct BuildActivity: Identifiable, Equatable {
    let id: String
    let command: String
    let folder: String
    let pid: Int32
    let start: Date
    var end: Date?
    var exitCode: Int32?
    var lastLine = ""

    var succeeded: Bool { exitCode == 0 }
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \(s / 60 % 60)m"
}

enum BuildNotifier {
    static let name = Notification.Name("app.islandly.build")

    /// CLI mode: `Islandly --notify start <id> <pid> <command> <cwd>` / `--notify finish <id> <exit code> <last line>`.
    static func post(_ args: [String]) {
        var info: [String: String] = [:]
        switch args.first {
        case "start" where args.count >= 5:
            info = ["event": "start", "id": args[1], "pid": args[2], "command": args[3], "cwd": args[4]]
        case "finish" where args.count >= 3:
            info = ["event": "finish", "id": args[1], "status": args[2], "line": args.count > 3 ? args[3] : ""]
        default:
            FileHandle.standardError.write(Data("usage: Islandly --notify start|finish …\n".utf8))
            return
        }
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info,
                                                                     deliverImmediately: true)
    }
}

final class BuildModel: ObservableObject {
    @Published private(set) var running: [BuildActivity] = []

    var onFinish: ((BuildActivity) -> Void)?
    var onStart: ((BuildActivity) -> Void)?

    func listen() {
        DistributedNotificationCenter.default().addObserver(forName: BuildNotifier.name, object: nil,
                                                            queue: .main) { [weak self] note in
            guard let info = note.userInfo as? [String: String] else { return }
            self?.handle(info)
        }
    }

    private func handle(_ info: [String: String]) {
        // Any local process can post this notification, so keep it bounded: short strings, few activities.
        guard let id = info["id"], id.count <= 64 else { return }
        func clip(_ s: String?, _ n: Int) -> String? { s.map { String($0.prefix(n)) } }
        switch info["event"] {
        case "start":
            guard running.count < 8 else { return }
            let cwd = clip(info["cwd"], 512) ?? ""
            let activity = BuildActivity(id: id,
                                         command: clip(info["command"], 120) ?? "command",
                                         folder: URL(fileURLWithPath: cwd).lastPathComponent,
                                         pid: Int32(info["pid"] ?? "") ?? 0,
                                         start: Date())
            running.append(activity)
            onStart?(activity)
        case "finish":
            guard let index = running.firstIndex(where: { $0.id == id }) else { return }
            var activity = running.remove(at: index)
            activity.end = Date()
            activity.exitCode = Int32(info["status"] ?? "") ?? 1
            activity.lastLine = clip(info["line"], 200) ?? ""
            onFinish?(activity)
        default:
            break
        }
    }

    /// Drops activities whose `notch` wrapper died without reporting (terminal closed, killed…).
    func pruneDead() {
        running.removeAll { $0.pid > 0 && kill($0.pid, 0) != 0 && errno == ESRCH }
    }
}

// MARK: - Views

struct BuildChip: View {
    @ObservedObject var model: IslandModel
    let activity: BuildActivity

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.command)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text("\(activity.folder) · running \(formatDuration(max(0, model.system.now.timeIntervalSince(activity.start))))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(10)
        .frame(height: 46)
        .card(14)
    }
}
