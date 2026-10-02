import AppKit
import SwiftUI

// Coding agents in the notch: Claude Code (terminal, IDE extensions, the Claude desktop Code tab) and Codex.
//
// Claude Code and Codex run `Islandly --agent-hook claude|codex` from their hooks (same events, same answers):
// what they're doing shows beside the notch, and when they need permission you can answer Allow / Deny right here.
// (Older Codex installs connected through its `notify` setting, which only reports finished turns; still understood.) Everything travels over a private Unix socket (only your user can open it);
// no network port. If Islandly isn't running, or you don't answer, the agent simply asks you itself as usual.

// MARK: - Socket path

enum AgentSocket {
    static var path: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Islandly")
        return dir.appendingPathComponent("agents.sock").path
    }

    static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        return addr
    }
}

// MARK: - Hook client (runs inside the agent's hook, then exits)

enum AgentHookClient {
    /// How long a permission request waits for your answer in the notch before the agent asks you itself.
    static let answerTimeout: TimeInterval = 110

    /// `Islandly --agent-hook claude` (hook JSON on stdin) or `Islandly --agent-hook codex '<json>'`.
    /// Never fails loudly: any problem means "do nothing", so the agent carries on exactly as without Islandly.
    static func run(_ args: [String]) -> Never {
        let source = args.first ?? "claude"
        let input: Data
        if source == "codex", let json = args.last, args.count > 1 {
            input = Data(json.utf8)
        } else {
            input = FileHandle.standardInput.readDataToEndOfFile()
        }
        guard let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
        let wantsAnswer = payload["hook_event_name"] as? String == "PermissionRequest"

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = AgentSocket.address() else { exit(0) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { exit(0) }   // Islandly isn't running
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let message: [String: Any] = ["source": source, "wait": wantsAnswer, "payload": payload]
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { exit(0) }
        line.append(0x0A)
        let sent = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard sent == line.count, wantsAnswer else { close(fd); exit(0) }

        // Wait for the answer. If you answer in the agent instead, it cancels the hook by killing the shell
        // that runs us; we notice our parent is gone and quit, which closes the card in the notch.
        var reply = Data()
        let deadline = Date().addingTimeInterval(answerTimeout)
        let parent = getppid()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, getppid() == parent else { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(min(remaining, 0.25) * 1000))
            if ready == 0 { continue }
            guard ready > 0 else { break }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            reply.append(buffer, count: n)
        }
        close(fd)
        guard let end = reply.firstIndex(of: 0x0A),
              let answer = try? JSONSerialization.jsonObject(with: reply[..<end]) as? [String: Any],
              let decision = answer["decision"] as? String, decision == "allow" || decision == "deny" else { exit(0) }

        var decided: [String: Any] = ["behavior": decision]
        if decision == "deny" { decided["message"] = "Denied from Islandly." }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decided]]
        if let data = try? JSONSerialization.data(withJSONObject: output) {
            FileHandle.standardOutput.write(data)
        }
        exit(0)
    }
}

// MARK: - Server

/// Accepts hook connections on the socket. Requests that need an answer keep their connection open until you
/// decide; if the agent gives up first (you answered there, or it was stopped), the connection closes and the
/// card disappears.
final class AgentServer {
    final class Connection {
        let fd: Int32
        fileprivate var source: DispatchSourceRead?
        fileprivate var buffer = Data()
        fileprivate var delivered = false
        fileprivate(set) var isOpen = true
        var onClose: (() -> Void)?

        init(fd: Int32) { self.fd = fd }

        func reply(_ object: [String: Any]) {
            guard isOpen, var data = try? JSONSerialization.data(withJSONObject: object) else { return }
            data.append(0x0A)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
            finish()
        }

        func finish() {
            guard isOpen else { return }
            isOpen = false
            source?.cancel()
        }
    }

    var onMessage: (([String: Any], Connection) -> Void)?

    private var listenFD: Int32 = -1
    /// Open connections, kept alive here until they close (touched only on `queue`).
    private var open: [Int32: Connection] = [:]
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "islandly.agents")

    func start() {
        guard listenFD < 0 else { return }
        let path = AgentSocket.path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = AgentSocket.address() else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { close(fd); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        acceptSource = source
    }

    private func acceptAll() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // Only processes of this same user may talk to us.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            let connection = Connection(fd: client)
            open[client] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
            connection.source = source
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.read(connection)
            }
            source.setCancelHandler { [weak self, weak connection] in
                close(client)
                self?.open[client] = nil
                guard let connection else { return }
                connection.isOpen = false
                DispatchQueue.main.async { connection.onClose?() }
            }
            source.resume()
            // Hooks send one small message right away; don't hold a silent connection forever.
            queue.asyncAfter(deadline: .now() + 10) { [weak connection] in
                if let connection, !connection.delivered { connection.finish() }
            }
        }
    }

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let n = Darwin.read(connection.fd, &chunk, chunk.count)
        guard n > 0 else { connection.finish(); return }   // closed by the agent
        guard !connection.delivered else { return }
        connection.buffer.append(chunk, count: n)
        guard connection.buffer.count < 1_000_000 else { connection.finish(); return }
        guard let end = connection.buffer.firstIndex(of: 0x0A) else { return }
        connection.delivered = true
        guard let message = try? JSONSerialization.jsonObject(with: connection.buffer[..<end]) as? [String: Any] else {
            connection.finish()
            return
        }
        if message["wait"] as? Bool != true { connection.finish() }
        DispatchQueue.main.async { self.onMessage?(message, connection) }
    }
}

// MARK: - Model

struct AgentSession: Identifiable, Equatable {
    enum State: Equatable { case working, waiting, done }
    let id: String
    let source: String          // "claude" / "codex"
    var project: String
    var activity: String
    var state: State
    var startedAt: Date
    var updatedAt: Date

    var agentName: String { source == "codex" ? "Codex" : "Claude" }
}

struct AgentRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let agentName: String
    let project: String
    let tool: String
    let detail: String
    let connection: AgentServer.Connection
}

final class AgentHub: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var requests: [AgentRequest] = []
    @Published private(set) var claudeConnected = false
    @Published private(set) var codexConnected = false

    var onFinished: ((AgentSession, String?) -> Void)?
    var onWaiting: ((AgentSession, String) -> Void)?
    var onRequest: (() -> Void)?

    private let server = AgentServer()

    init() {
        refreshConnections()
        server.onMessage = { [weak self] message, connection in self?.handle(message, connection) }
        // Listen only while an agent is connected: no socket at all for people who never use this.
        if claudeConnected || codexConnected { server.start() }
        // A moved app gets its hook path fixed silently (only rewritten if the path changed).
        if claudeConnected, !AgentHooks.claudeUpToDate { try? AgentHooks.installClaude() }
        if codexConnected, !AgentHooks.codexUpToDate { try? AgentHooks.installCodex() }
    }

    var working: [AgentSession] { sessions.filter { $0.state != .done } }
    var pending: AgentRequest? { requests.first }

    func refreshConnections() {
        claudeConnected = AgentHooks.claudeInstalled
        codexConnected = AgentHooks.codexInstalled
    }

    func answer(_ request: AgentRequest, allow: Bool?) {
        if let allow { request.connection.reply(["decision": allow ? "allow" : "deny"]) } else { request.connection.reply(["decision": "ask"]) }
        requests.removeAll { $0.id == request.id }
        if allow != nil, let i = sessions.firstIndex(where: { $0.id == request.sessionID }) {
            sessions[i].state = .working
            sessions[i].activity = allow == true ? "Running \(request.tool)" : "Denied \(request.tool)"
        }
    }

    /// Once a second: forget sessions that went quiet (an agent that crashed never says goodbye).
    func prune(_ now: Date) {
        let before = sessions.count
        sessions.removeAll { s in
            (s.state == .done && now.timeIntervalSince(s.updatedAt) > 20) || now.timeIntervalSince(s.updatedAt) > 30 * 60
        }
        if sessions.count != before { objectWillChange.send() }
    }

    // MARK: Connect / disconnect

    func setClaude(_ on: Bool) {
        do {
            if on { try AgentHooks.installClaude() } else { try AgentHooks.uninstallClaude() }
        } catch {
            AgentHooks.alert("Couldn't update Claude Code's settings", error.localizedDescription)
        }
        afterConnectionChange()
    }

    func setCodex(_ on: Bool) {
        do {
            if on {
                try AgentHooks.installCodex()
                AgentHooks.offerCodexReview()
            } else {
                try AgentHooks.uninstallCodex()
            }
        } catch {
            AgentHooks.alert("Couldn't update Codex's settings", error.localizedDescription)
        }
        afterConnectionChange()
    }

    private func afterConnectionChange() {
        refreshConnections()
        if claudeConnected || codexConnected { server.start() }
    }

    // MARK: Events

    private func handle(_ message: [String: Any], _ connection: AgentServer.Connection) {
        guard let payload = message["payload"] as? [String: Any] else { connection.finish(); return }
        let source = message["source"] as? String ?? "claude"
        // Codex's older `notify` setting sends a different shape: just "a turn finished".
        if source == "codex", payload["hook_event_name"] == nil { handleCodex(payload); return }
        let agentName = source == "codex" ? "Codex" : "Claude"

        let event = payload["hook_event_name"] as? String ?? ""
        let id = payload["session_id"] as? String ?? "claude"
        let cwd = payload["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? agentName : (cwd as NSString).lastPathComponent
        let now = Date()

        func update(_ change: (inout AgentSession) -> Void) {
            if let i = sessions.firstIndex(where: { $0.id == id }) {
                change(&sessions[i])
                sessions[i].updatedAt = now
            } else {
                var s = AgentSession(id: id, source: source, project: project, activity: "Starting…", state: .working,
                                     startedAt: now, updatedAt: now)
                change(&s)
                sessions.append(s)
            }
        }

        // Answered in the agent itself: once the session moves on, its card in the notch is stale.
        if ["PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd", "Interrupt"].contains(event) {
            for request in requests where request.sessionID == id { request.connection.finish() }
            requests.removeAll { $0.sessionID == id }
        }

        switch event {
        case "SessionStart":
            update { $0.state = .working; $0.activity = "Ready" }
        case "UserPromptSubmit":
            update { $0.state = .working; $0.activity = "Thinking…"; $0.startedAt = now }
        case "PreToolUse":
            let tool = payload["tool_name"] as? String ?? "tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            update { $0.state = .working; $0.activity = Self.describe(tool: tool, input: input).short }
        case "PostToolUse":
            update { if $0.state == .waiting { $0.state = .working } }
        case "Notification":
            let text = payload["message"] as? String ?? "\(project) needs you"
            update { $0.state = .waiting; $0.activity = text }
            // Permission prompts get their own card; this covers "waiting for your input" and the like.
            if !text.lowercased().contains("permission"), let s = sessions.first(where: { $0.id == id }) { onWaiting?(s, text) }
        case "PermissionRequest":
            let tool = payload["tool_name"] as? String ?? "tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let described = Self.describe(tool: tool, input: input)
            update { $0.state = .waiting; $0.activity = "Waiting: \(described.short)" }
            let request = AgentRequest(sessionID: id, agentName: agentName, project: project, tool: described.verb,
                                       detail: described.detail, connection: connection)
            connection.onClose = { [weak self] in
                // The agent stopped waiting (you answered there, or it was interrupted).
                self?.requests.removeAll { $0.id == request.id }
            }
            requests.append(request)
            onRequest?()
        case "Stop":
            update { $0.state = .done; $0.activity = "Finished" }
            let summary = (payload["last_assistant_message"] as? String)?
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if let s = sessions.first(where: { $0.id == id }) { onFinished?(s, summary.map { String($0.prefix(140)) }) }
        case "Interrupt":
            update { $0.state = .done; $0.activity = "Stopped" }
        case "SessionEnd":
            sessions.removeAll { $0.id == id }
            requests.filter { $0.sessionID == id }.forEach { $0.connection.finish() }
            requests.removeAll { $0.sessionID == id }
        default:
            break
        }
    }

    private func handleCodex(_ payload: [String: Any]) {
        guard payload["type"] as? String == "agent-turn-complete" else { return }
        let cwd = payload["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Codex" : (cwd as NSString).lastPathComponent
        let id = payload["thread-id"] as? String ?? payload["turn-id"] as? String ?? UUID().uuidString
        let summary = (payload["last-assistant-message"] as? String)?
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let session = AgentSession(id: id, source: "codex", project: project, activity: "Finished", state: .done,
                                   startedAt: Date(), updatedAt: Date())
        sessions.removeAll { $0.id == id }
        sessions.append(session)
        onFinished?(session, summary.map { String($0.prefix(140)) })
    }

    /// Plain-language description of a tool call: a short live label, plus a verb and detail for permission cards.
    static func describe(tool: String, input: [String: Any]) -> (short: String, verb: String, detail: String) {
        func file(_ key: String = "file_path") -> String { ((input[key] as? String) ?? "") as NSString as String }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        switch tool {
        case "apply_patch":
            // Codex edits files with a patch; its header lines name the files ("*** Update File: path").
            let patch = input.values.compactMap { $0 as? String }.joined(separator: "\n")
            let files = patch.components(separatedBy: "\n").compactMap { line -> String? in
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
                return nil
            }
            let label = files.count == 1 ? name(files[0]) : (files.isEmpty ? "files" : "\(files.count) files")
            return ("Editing \(label)", "edit \(label)", files.isEmpty ? String(patch.prefix(300)) : files.joined(separator: "\n"))
        case "Bash", "shell", "local_shell", "exec_command":
            let raw = input["command"] ?? input["cmd"]
            let command = ((raw as? String) ?? (raw as? [String])?.joined(separator: " ") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = command.split(separator: "\n").first.map(String.init) ?? command
            return ("Running \(first.prefix(40))", "run a command", command)
        case "Edit", "MultiEdit":
            return ("Editing \(name(file()))", "edit \(name(file()))", file())
        case "Write":
            return ("Writing \(name(file()))", "create \(name(file()))", file())
        case "Read":
            return ("Reading \(name(file()))", "read \(name(file()))", file())
        case "NotebookEdit":
            return ("Editing \(name(file("notebook_path")))", "edit \(name(file("notebook_path")))", file("notebook_path"))
        case "WebFetch":
            let url = input["url"] as? String ?? ""
            return ("Reading \(URL(string: url)?.host ?? "a web page")", "open a web page", url)
        case "WebSearch":
            let query = input["query"] as? String ?? ""
            return ("Searching the web", "search the web", query)
        case "Grep", "Glob":
            let pattern = input["pattern"] as? String ?? ""
            return ("Searching \(pattern.prefix(30))", "search files", pattern)
        case "Task", "Agent":
            let description = input["description"] as? String ?? "a sub-task"
            return ("Agent: \(description.prefix(36))", "start an agent", description)
        default:
            let pretty = tool.hasPrefix("mcp__") ? tool.split(separator: "__").dropFirst().joined(separator: " · ") : tool
            let detail = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            return ("Using \(pretty.prefix(36))", "use \(pretty)", String(detail.prefix(300)))
        }
    }
}

// MARK: - Installing the hooks

enum AgentHooks {
    static let marker = "--agent-hook"
    static var claudeSettings: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var codexConfig: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml") }
    static var codexHooks: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json") }
    static var claudeFound: Bool { FileManager.default.fileExists(atPath: claudeSettings.deletingLastPathComponent().path) }
    static var codexFound: Bool { FileManager.default.fileExists(atPath: codexConfig.deletingLastPathComponent().path) }

    /// The hook command. `|| true` keeps the agent quiet if Islandly is ever moved or deleted.
    static func command(_ source: String) -> String {
        let exe = Bundle.main.executablePath ?? "/Applications/Islandly.app/Contents/MacOS/Islandly"
        return "'\(exe.replacingOccurrences(of: "'", with: "'\\''"))' \(marker) \(source) 2>/dev/null || true"
    }

    static let claudeEvents: [(event: String, timeout: Int)] = [
        ("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5), ("Notification", 5),
        ("PermissionRequest", Int(AgentHookClient.answerTimeout) + 10), ("Stop", 5), ("SessionEnd", 5),
    ]

    /// Codex fires the same events except Notification, plus Interrupt; SessionEnd hooks may take at most 3 s.
    static let codexEvents: [(event: String, timeout: Int)] = [
        ("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5),
        ("PermissionRequest", Int(AgentHookClient.answerTimeout) + 10), ("Stop", 5), ("Interrupt", 3), ("SessionEnd", 3),
    ]

    static var claudeInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettings), let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    static var claudeUpToDate: Bool {
        (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains(command("claude").replacingOccurrences(of: "/", with: "\\/")) == true
            || (try? String(contentsOf: claudeSettings, encoding: .utf8))?.contains(command("claude")) == true
    }

    /// Connected through hooks.json with this copy's path (not the old notify line, not a moved app).
    static var codexUpToDate: Bool {
        guard let text = try? String(contentsOf: codexHooks, encoding: .utf8) else { return false }
        return text.contains(command("codex")) || text.contains(command("codex").replacingOccurrences(of: "/", with: "\\/"))
    }

    static func installClaude() throws {
        var settings = try readJSON(claudeSettings)
        settings["hooks"] = adding(claudeEvents, source: "claude", to: settings["hooks"] as? [String: Any] ?? [:])
        try writeJSON(settings, to: claudeSettings)
    }

    static func uninstallClaude() throws {
        var settings = try readJSON(claudeSettings)
        let hooks = stripped(settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try writeJSON(settings, to: claudeSettings)
    }

    private static func adding(_ events: [(event: String, timeout: Int)], source: String, to existing: [String: Any]) -> [String: Any] {
        var hooks = stripped(existing)
        for (event, timeout) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command(source), "timeout": timeout]]])
            hooks[event] = groups
        }
        return hooks
    }

    /// The user's hooks minus Islandly's (so installing twice never duplicates, and uninstalling leaves theirs).
    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let mine = list.filter { ($0["command"] as? String)?.contains(marker) != true }
                if mine.isEmpty { return nil }
                var g = group
                g["hooks"] = mine
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    private static func readJSON(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(url.path) isn't a JSON object."])
        }
        return object
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = url.appendingPathExtension("islandly-backup")
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: url, to: backup)   // the original, before Islandly ever touched it
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    // Codex: the same hooks, in ~/.codex/hooks.json. (Earlier versions of Islandly used a `notify` line in
    // config.toml, which only reported finished turns; connecting again replaces it.)

    static var codexInstalled: Bool {
        let hooks = (try? String(contentsOf: codexHooks, encoding: .utf8))?.contains(marker) ?? false
        let notify = (try? String(contentsOf: codexConfig, encoding: .utf8))?.contains(marker) ?? false
        return hooks || notify
    }

    /// Hooks are on by default; someone may have switched them off in config.toml.
    static var codexHooksDisabled: Bool {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return false }
        var inFeatures = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inFeatures = t == "[features]" }
            if inFeatures, t.replacingOccurrences(of: " ", with: "").hasPrefix("hooks=false") { return true }
        }
        return false
    }

    static func installCodex() throws {
        try removeLegacyNotify()
        var file = try readJSON(codexHooks)
        file["hooks"] = adding(codexEvents, source: "codex", to: file["hooks"] as? [String: Any] ?? [:])
        try writeJSON(file, to: codexHooks)
        if codexHooksDisabled {
            alert("Codex hooks are switched off",
                  "Islandly is connected, but ~/.codex/config.toml has hooks = false under [features]. Set it to true (or remove that line) for Codex to show up in the notch.")
        }
    }

    static func uninstallCodex() throws {
        try removeLegacyNotify()
        var file = try readJSON(codexHooks)
        let hooks = stripped(file["hooks"] as? [String: Any] ?? [:])
        file["hooks"] = hooks.isEmpty ? nil : hooks
        if file.isEmpty, (try? Data(contentsOf: codexHooks.appendingPathExtension("islandly-backup"))) == nil {
            try? FileManager.default.removeItem(at: codexHooks)   // we created it; leave nothing behind
        } else {
            try writeJSON(file, to: codexHooks)
        }
    }

    private static func removeLegacyNotify() throws {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8), text.contains(marker) else { return }
        let kept = text.components(separatedBy: "\n").filter { !($0.contains(marker) && $0.hasPrefix("notify")) }
        try kept.joined(separator: "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// Codex runs new hooks only after you trust them: a Codex safety check Islandly doesn't bypass. The dependable
    /// place to approve is Codex's own review screen, shown when Codex starts in a terminal; this opens it for you.
    static func offerCodexReview() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"]
        let codex = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let steps = "Codex runs new hooks only after you approve them once (its own safety check).\n\n"
            + (codex != nil
               ? "Click Open Review: Terminal opens Codex, which lists Islandly's hooks. Approve them, then quit Codex (Ctrl+C twice). Finally restart your Codex app or reload your IDE window (Codex only reads approvals when it starts) and start a new chat."
               : "Run codex in a terminal: it lists Islandly's hooks when it starts. Approve them, then restart your Codex app or reload your IDE window and start a new chat.")
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "One more step: approve Islandly in Codex"
        alert.informativeText = steps
        if codex != nil { alert.addButton(withTitle: "Open Review") }
        alert.addButton(withTitle: codex != nil ? "Later" : "OK")
        guard let codex, alert.runModal() == .alertFirstButtonReturn else { return }
        // A .command file opens in Terminal without asking for Automation access.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("islandly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("Approve Islandly in Codex.command")
        let quoted = "'" + codex.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = "#!/bin/sh\ncd \"$HOME\"\necho 'Approve the Islandly hooks below, then press Ctrl+C twice to quit.'\nexec \(quoted)\n"
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(script.path, 0o755)
        NSWorkspace.shared.open(script)
    }

    static func confirm(_ title: String, _ message: String, button: String) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Views

/// The permission card: stays under the notch until you answer (or the agent stops waiting).
struct AgentRequestView: View {
    @ObservedObject var model: IslandModel
    let request: AgentRequest

    var body: some View {
        let more = model.agents.requests.count - 1
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                AgentBadge(source: request.agentName == "Codex" ? "codex" : "claude", size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(request.agentName) wants to \(request.tool)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(request.project + (more > 0 ? "  ·  +\(more) more waiting" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 44)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.07)))
            }
            HStack(spacing: 8) {
                Button { model.agents.answer(request, allow: nil) } label: {
                    Text("Answer in \(request.agentName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                choice("Deny", color: .red.opacity(0.85)) { model.agents.answer(request, allow: false) }
                choice("Allow", color: .green) { model.agents.answer(request, allow: true) }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, model.notchSize.height + 4)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func choice(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(title == "Allow" ? .black : .white)
                .frame(width: 74, height: 28)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The agent's own app icon (ChatGPT for Codex, Claude for Claude Code), taken from the app installed on this Mac,
/// the way Finder shows it; a plain symbol when that app isn't installed.
enum AgentIcons {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for source: String) -> NSImage? {
        if let cached = cache[source] { return cached }
        let ids = source == "codex" ? ["com.openai.codex", "com.openai.chat"] : ["com.anthropic.claudefordesktop"]
        let image = ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[source] = image
        return image
    }
}

struct AgentBadge: View {
    let source: String
    var size: CGFloat = 20

    var body: some View {
        if let icon = AgentIcons.icon(for: source) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size * 1.18, height: size * 1.18)   // app icons have a transparent margin
                .frame(width: size, height: size)
        } else {
            Image(systemName: source == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(source == "codex" ? Color(white: 0.3) : Color(red: 0.85, green: 0.47, blue: 0.34)))
        }
    }
}

/// Home tab: one row per agent that's working (or waiting) right now.
struct AgentChip: View {
    @ObservedObject var model: IslandModel
    let session: AgentSession

    var body: some View {
        HStack(spacing: 10) {
            AgentBadge(source: session.source, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.agentName) · \(session.project)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(session.activity) · \(formatDuration(max(0, model.system.now.timeIntervalSince(session.startedAt))))")
                    .font(.system(size: 11))
                    .foregroundStyle(session.state == .waiting ? Color.orange : .secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            Spacer()
            if session.state == .waiting {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(height: 46)
        .card(14)
    }
}

