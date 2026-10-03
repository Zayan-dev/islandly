import AppKit
import SwiftUI

// Hold ⌥ (Option) over anything and ask out loud (or say nothing); let go, and Claude Code or
// Codex (whichever you use, signed in with your own account) explains it in a bubble right at the cursor.
//
// Off until you turn it on. Unlike the rest of Islandly this sends something off the Mac: the highlighted area
// goes to Anthropic or OpenAI through your own Claude Code / Codex login. Nothing is sent unless you hold ⌥ and let go.
// The key is watched by reading the modifier state a few times a second, so no Accessibility permission is needed.

enum AskEngine: String, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }

    /// The installed command-line tool: on PATH, in the desktop app, or bundled with an IDE extension.
    var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String]
        switch self {
        case .claude:
            paths = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            paths += Self.extensionBinaries(prefix: "anthropic.claude-code-", relative: "resources/native-binary/claude")
        case .codex:
            paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                     "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"]
            #if arch(arm64)
            paths += Self.extensionBinaries(prefix: "openai.chatgpt-", relative: "bin/macos-aarch64/codex")
            #else
            paths += Self.extensionBinaries(prefix: "openai.chatgpt-", relative: "bin/macos-x86_64/codex")
            #endif
        }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func extensionBinaries(prefix: String, relative: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [String] = []
        for dir in [".vscode/extensions", ".cursor/extensions", ".antigravity-ide/extensions", ".antigravity/extensions", ".windsurf/extensions"] {
            let base = home.appendingPathComponent(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
            for name in names.filter({ $0.hasPrefix(prefix) }).sorted().reversed() {   // newest version first
                out.append(base.appendingPathComponent(name).appendingPathComponent(relative).path)
            }
        }
        return out
    }
}

final class AskModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "askEnabled")
            enabled ? startWatching() : stopWatching()
        }
    }
    @Published var engine: AskEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "askEngine") }
    }
    /// Read answers aloud when you asked out loud.
    @Published var speakAnswers: Bool {
        didSet { UserDefaults.standard.set(speakAnswers, forKey: "askSpeak") }
    }

    var available: [AskEngine] { AskEngine.allCases.filter { $0.executable != nil } }

    private enum Phase { case idle, arming(Date, reply: Bool), boxing, replying }
    private var phase = Phase.idle
    private var timer: Timer?
    private var scrollMonitor: Any?
    private var boxScale: CGFloat = 1
    private let box = AskBoxWindow()
    private let bubble = AskBubble()
    private let voice = VoiceInput()

    static let holdDelay: TimeInterval = 0.6
    static let replyDelay: TimeInterval = 0.35
    static let baseBox = CGSize(width: 460, height: 220)

    init() {
        let saved = AskEngine(rawValue: UserDefaults.standard.string(forKey: "askEngine") ?? "")
        engine = saved ?? (AskEngine.claude.executable != nil ? .claude : .codex)
        speakAnswers = UserDefaults.standard.object(forKey: "askSpeak") as? Bool ?? true
        enabled = UserDefaults.standard.bool(forKey: "askEnabled")
        bubble.speakSetting = { [weak self] in self?.speakAnswers ?? true }
        if enabled { startWatching() }
    }

    /// Turning it on is consent to send what you point at; ask once, clearly.
    func turnOn() {
        guard let engine = available.contains(engine) ? engine : available.first else {
            AgentHooks.alert("Claude Code or Codex needed",
                             "Hold ⌥ to Ask uses Claude Code or Codex, signed in with your own account. Install one of them (in the terminal, the ChatGPT app or an IDE extension), then turn this on.")
            return
        }
        self.engine = engine
        let company = engine == .claude ? "Anthropic" : "OpenAI"
        if AgentHooks.confirm("Turn on Hold ⌥ to Ask?",
                              "Point at anything and hold the Option key: a box shows what you're pointing at. Say your question out loud while you hold it (or say nothing), then let go. \(engine.name) answers in a bubble and reads it to you. Hold ⌥ by the bubble to reply.\n\nWhen you let go, the highlighted area (a screenshot and its text) and your question's words go to \(company) through your own \(engine.name) account. Your voice is turned into text on your Mac and never sent. Nothing else leaves your Mac.",
                              button: "Turn On") {
            enabled = true
            VoiceInput.requestMicrophone { _ in }   // optional: without it you can still ask silently
        }
    }

    // MARK: Watching the ⌥ key

    private var fastTimer = false

    private func startWatching(fast: Bool = false) {
        fastTimer = fast
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 30 : 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        cancelBox()
        if case .replying = phase { cancelReply() }
    }

    /// Only ⌥, no other modifier, no mouse button, no other key held.
    private var optionAlone: Bool {
        let flags = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift, .function, .capsLock])
        guard flags == .option, NSEvent.pressedMouseButtons == 0 else { return false }
        for key: CGKeyCode in 0..<128 where !(54...63).contains(key) && CGEventSource.keyState(.combinedSessionState, key: key) {
            return false
        }
        return true
    }

    private var released: Bool { NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty }

    private func tick() {
        // Esc (key 53) closes the bubble or cancels the box; read from the key state, so no permission is needed.
        if CGEventSource.keyState(.combinedSessionState, key: 53) {
            if case .boxing = phase { cancelBox(); return }
            if case .replying = phase { cancelReply() }
            if bubble.isOpen { bubble.close(); phase = .idle; return }
        }
        switch phase {
        case .idle:
            // Quick Esc taps need a quicker look while the bubble is up; relax again once it's closed.
            if bubble.isOpen != fastTimer { startWatching(fast: bubble.isOpen) }
            if NSEvent.modifierFlags.contains(.option), optionAlone {
                // By the open bubble, holding ⌥ means "reply"; anywhere else it's a new question.
                phase = .arming(Date(), reply: bubble.canReply(at: NSEvent.mouseLocation))
            }
        case .arming(let since, let reply):
            if !optionAlone { phase = .idle; return }
            if Date().timeIntervalSince(since) >= (reply ? Self.replyDelay : Self.holdDelay) {
                reply ? startReply() : showBox()
            }
        case .boxing:
            if released { ask(about: currentBoxRect()) } else if !optionAlone { cancelBox() } else { box.place(currentBoxRect()) }
        case .replying:
            if released { finishReply() } else if !optionAlone { cancelReply() }
        }
    }

    // MARK: The box

    private func currentBoxRect() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens[0]
        let size = CGSize(width: Self.baseBox.width * boxScale, height: Self.baseBox.height * boxScale)
        var rect = CGRect(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2, width: size.width, height: size.height)
        let f = screen.frame
        rect.origin.x = min(max(rect.minX, f.minX), f.maxX - rect.width)
        rect.origin.y = min(max(rect.minY, f.minY), f.maxY - rect.height)
        return rect
    }

    private func showBox() {
        phase = .boxing
        boxScale = 1
        let listening = VoiceInput.microphoneAllowed
        box.label = listening ? "Ask out loud, or just let go · scroll to resize" : "Let go to ask \(engine.name) · scroll to resize"
        box.place(currentBoxRect())
        box.orderFrontRegardless()
        if listening {
            voice.onText = { [weak self] text in
                guard let self, case .boxing = self.phase, !text.isEmpty else { return }
                self.box.label = "“\(text.suffix(70))”"
            }
            voice.start()
        }
        startWatching(fast: true)
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            self.boxScale = min(2.6, max(0.45, self.boxScale * (1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08))))
            self.box.place(self.currentBoxRect())
        }
    }

    private func endBox() {
        box.orderOut(nil)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        phase = .idle
        if enabled { startWatching() } else { timer?.invalidate(); timer = nil }
    }

    private func cancelBox() {
        guard case .boxing = phase else { if case .arming = phase { phase = .idle }; return }
        voice.stop { _ in }
        endBox()
    }

    // MARK: Asking

    private func ask(about rect: CGRect) {
        endBox()
        let engine = available.contains(self.engine) ? self.engine : (available.first ?? self.engine)
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app"
        bubble.start(engine: engine, near: rect)
        let primaryHeight = NSScreen.screens[0].frame.height
        let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)

        // Two things finish independently: the screenshot (+ its text) and your spoken question.
        let group = DispatchGroup()
        var question = ""
        var image: URL?
        var screenText = ""
        var captureFailed = false
        group.enter()
        if VoiceInput.microphoneAllowed { voice.stop { question = $0; group.leave() } } else { group.leave() }
        group.enter()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {   // let the box disappear first
            ScreenTools.captureRect(cgRect) { captured in
                guard let captured else { captureFailed = true; group.leave(); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    screenText = ScreenTools.recognizeText(in: captured)
                    image = Self.saveJPEG(captured)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if captureFailed {
                self.bubble.fail("Islandly needs Screen Recording to see what you're pointing at. Allow it in System Settings → Privacy & Security, then restart Islandly.")
                return
            }
            self.bubble.begin(engine: engine, image: image, context: Self.context(app: app, text: screenText), question: question)
        }
    }

    // MARK: Replying by voice

    private func startReply() {
        guard VoiceInput.microphoneAllowed else {
            phase = .idle
            VoiceInput.requestMicrophone { _ in }
            return
        }
        phase = .replying
        bubble.startListening()
        voice.onText = { [weak self] text in self?.bubble.hear(text) }
        voice.start()
        startWatching(fast: true)
    }

    private func finishReply() {
        phase = .idle
        startWatching()
        voice.stop { [weak self] words in
            if words.isEmpty { self?.bubble.stopListening() } else { self?.bubble.reply(words) }
        }
    }

    private func cancelReply() {
        phase = .idle
        if enabled { startWatching() }
        voice.stop { _ in }
        bubble.stopListening()
    }

    /// What you're pointing at: the app and the text found in the box.
    static func context(app: String, text: String) -> String {
        var c = "I'm pointing at part of my screen in \(app) (screenshot attached)."
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { c += "\n\nText detected in that area (may be imperfect):\n" + String(trimmed.prefix(4000)) }
        return c
    }

    /// The capture, scaled to a sensible size, in a private temporary folder.
    private static func saveJPEG(_ image: CGImage) -> URL? {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: .zero).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        let url = AskRunner.workDir.appendingPathComponent("look.jpg")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

// MARK: - Running Claude Code / Codex

/// One question to the user's own Claude Code or Codex, answered as it streams.
final class AskRunner {
    static var workDir: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("islandly-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    private var process: Process?
    private var buffer = Data()

    func cancel() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    /// `onText` gets the answer so far (Claude streams; Codex sends it whole). `onDone` gets an error message or nil.
    func run(engine: AskEngine, image: URL?, prompt: String, onText: @escaping (String) -> Void, onDone: @escaping (String?) -> Void) {
        cancel()
        guard let exe = engine.executable else { onDone("\(engine.name) isn't installed on this Mac."); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.currentDirectoryURL = Self.workDir
        var env = ProcessInfo.processInfo.environment
        env["ISLANDLY_ASK"] = "1"   // Islandly's own agent hooks stay quiet for these
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        var answer = ""
        var failure: String?
        switch engine {
        case .claude:
            process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                 "--include-partial-messages", "--tools", "", "--model", "sonnet",
                                 "--no-session-persistence", "--setting-sources", "project"]
        case .codex:
            var args = ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only"]
            if let image { args += ["-i", image.path] }
            process.arguments = args + ["--", prompt]
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[..<newline]
                self.buffer.removeSubrange(...newline)
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                switch engine {
                case .claude:
                    if event["type"] as? String == "stream_event", let ev = event["event"] as? [String: Any],
                       ev["type"] as? String == "content_block_delta", let delta = ev["delta"] as? [String: Any],
                       let piece = delta["text"] as? String {
                        answer += piece
                        let snapshot = answer
                        DispatchQueue.main.async { onText(snapshot) }
                    } else if event["type"] as? String == "result" {
                        if event["is_error"] as? Bool == true { failure = (event["result"] as? String) ?? "Claude couldn't answer." }
                        if answer.isEmpty, let result = event["result"] as? String, failure == nil {
                            answer = result
                            DispatchQueue.main.async { onText(result) }
                        }
                    }
                case .codex:
                    let item = event["item"] as? [String: Any]
                    if event["type"] as? String == "item.completed", item?["type"] as? String == "agent_message",
                       let text = item?["text"] as? String {
                        answer += (answer.isEmpty ? "" : "\n\n") + text
                        let snapshot = answer
                        DispatchQueue.main.async { onText(snapshot) }
                    } else if ["error", "turn.failed"].contains(event["type"] as? String ?? "") {
                        let error = event["error"] as? [String: Any]
                        failure = (error?["message"] as? String) ?? (event["message"] as? String) ?? "Codex couldn't answer."
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] p in
            output.fileHandleForReading.readabilityHandler = nil
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let lastErr = stderr.split(separator: "\n").last.map(String.init)
            DispatchQueue.main.async {
                if self?.process === p { self?.process = nil }
                if p.terminationReason == .uncaughtSignal { onDone(nil); return }   // cancelled
                if answer.isEmpty {
                    onDone(failure ?? (p.terminationStatus == 0 ? "No answer came back." : (lastErr ?? "\(engine.name) stopped unexpectedly.")))
                } else {
                    onDone(failure)
                }
            }
        }

        do { try process.run() } catch { onDone("Couldn't start \(engine.name): \(error.localizedDescription)"); return }
        self.process = process

        if engine == .claude {
            // Claude Code takes the image and the question as one stream-json message on stdin.
            var content: [[String: Any]] = []
            if let image, let data = try? Data(contentsOf: image) {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
            }
            content.append(["type": "text", "text": prompt])
            let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
            if var line = try? JSONSerialization.data(withJSONObject: message) {
                line.append(0x0A)
                input.fileHandleForWriting.write(line)
            }
        }
        try? input.fileHandleForWriting.close()

        // Never hang around forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak process] in
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

// MARK: - The box

final class AskBoxWindow: NSPanel {
    private let model = BoxModel()

    final class BoxModel: ObservableObject { @Published var label = "" }

    var label: String {
        get { model.label }
        set { model.label = newValue }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        contentView = NSHostingView(rootView: AskBoxView(model: model))
    }

    required init?(coder: NSCoder) { nil }

    func place(_ rect: CGRect) { setFrame(rect, display: true) }
}

private struct AskBoxView: View {
    @ObservedObject var model: AskBoxWindow.BoxModel

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color(red: 0.29, green: 0.58, blue: 0.96), Color(red: 0.61, green: 0.45, blue: 0.95),
                                                      Color(red: 0.93, green: 0.42, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 2.5)
                .shadow(color: Color(red: 0.61, green: 0.45, blue: 0.95).opacity(0.6), radius: 10)
            Text(model.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.75)))
                .padding(.top, 8)
        }
    }
}

// MARK: - The answer bubble

final class AskBubble {
    final class State: ObservableObject {
        @Published var engine: AskEngine = .claude
        @Published var answer = ""
        @Published var error: String?
        @Published var working = true
        @Published var question: String?
        @Published var listening = false
        @Published var heard = ""
        @Published var voiceMode = false
        @Published var muted = false
        /// Your chosen size (drag the bottom-right corner); remembered.
        @Published var width = CGFloat(UserDefaults.standard.object(forKey: "askBubbleWidth") as? Double ?? 400)
        @Published var answerHeight = CGFloat(UserDefaults.standard.object(forKey: "askBubbleAnswerHeight") as? Double ?? 250)
    }

    private let state = State()
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private let runner = AskRunner()
    private let speaker = AnswerSpeaker()
    private var anchor: CGRect = .zero
    /// Once you drag the bubble somewhere, it stays there (its top edge fixed while answers grow).
    private var placedTop: CGPoint?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var resizeStart: (mouse: CGPoint, width: CGFloat, height: CGFloat)?
    private var image: URL?
    private var context = ""
    private var history: [(question: String?, answer: String)] = []
    var speakSetting: () -> Bool = { true }

    static let width: CGFloat = 400

    // MARK: Conversation

    var isOpen: Bool { panel?.isVisible == true }

    func drag(ended: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
        guard let start = dragStart else { return }
        panel.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
        placedTop = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        if ended { dragStart = nil }
    }

    /// Bottom-right corner: wider/narrower and taller/shorter; the top-left corner stays put.
    func resizeDrag(ended: Bool) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if resizeStart == nil {
            resizeStart = (mouse, state.width, state.answerHeight)
            placedTop = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        guard let start = resizeStart else { return }
        state.width = min(900, max(300, start.width + mouse.x - start.mouse.x))
        state.answerHeight = min(700, max(110, start.height - (mouse.y - start.mouse.y)))
        resize()
        if ended {
            resizeStart = nil
            UserDefaults.standard.set(Double(state.width), forKey: "askBubbleWidth")
            UserDefaults.standard.set(Double(state.answerHeight), forKey: "askBubbleAnswerHeight")
        }
    }

    func start(engine: AskEngine, near rect: CGRect) {
        runner.cancel()
        placedTop = nil
        speaker.reset()
        history = []
        state.engine = engine
        state.answer = ""
        state.error = nil
        state.question = nil
        state.listening = false
        state.working = true
        anchor = rect
        show()
    }

    /// First question about this spot. Asked out loud → answered out loud.
    func begin(engine: AskEngine, image: URL?, context: String, question: String) {
        self.image = image
        self.context = context
        state.engine = engine
        state.voiceMode = !question.isEmpty && speakSetting()
        send(question.isEmpty ? nil : question)
    }

    /// A spoken follow-up: same screenshot, plus what was said so far.
    func reply(_ question: String) {
        state.listening = false
        state.voiceMode = speakSetting()
        if !state.answer.isEmpty { history.append((state.question, state.answer)) }
        send(question)
    }

    /// A typed follow-up.
    func followUp() {
        TextEditorWindow.show(title: "Ask a follow-up", text: "", prompt: "Your question about what you pointed at:") { [weak self] question in
            guard let self, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !self.state.answer.isEmpty { self.history.append((self.state.question, self.state.answer)) }
            self.send(question)
        }
    }

    private func send(_ question: String?) {
        state.question = question
        state.answer = ""
        state.error = nil
        state.working = true
        speaker.reset()
        speaker.muted = state.muted
        resize()
        let prompt = Self.prompt(context: context, history: history, question: question, spoken: state.voiceMode)
        runner.run(engine: state.engine, image: image, prompt: prompt, onText: { [weak self] text in
            guard let self else { return }
            self.state.answer = text
            if self.state.voiceMode { self.speaker.feed(text, final: false) }
            self.resize()
        }, onDone: { [weak self] error in
            guard let self else { return }
            self.state.working = false
            if let error { self.state.error = error }
            if self.state.voiceMode { self.speaker.feed(self.state.answer, final: true) }
            self.resize()
        })
    }

    static func prompt(context: String, history: [(question: String?, answer: String)], question: String?, spoken: Bool) -> String {
        var p = context + "\n\n"
        if spoken {
            p += "I'm talking to you out loud, like asking a friend sitting next to me who can see my screen. Answer conversationally in 1–3 short sentences of plain speech, with no markdown, lists or code blocks, because your reply is read aloud. "
        } else {
            p += "Answer in plain language, in 2–4 short sentences, no headings. "
        }
        p += "If it's an error, give the likely cause and the fix; if it's another language, translate it. Don't run any commands."
        if !history.isEmpty {
            p += "\n\nOur conversation so far:"
            for turn in history { p += "\nMe: \(turn.question ?? "What is this?")\nYou: \(turn.answer)" }
        }
        p += "\n\n" + (question.map { "My question: \($0)" } ?? "Explain what it shows.")
        return p
    }

    // MARK: Listening for a reply

    /// Holding ⌥ by the bubble (or the spot it's about) replies.
    func canReply(at point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -40, dy: -40).contains(point) || anchor.insetBy(dx: -20, dy: -20).contains(point)
    }

    func startListening() {
        runner.cancel()          // barge in, like interrupting a friend
        speaker.stop()
        state.working = false
        state.listening = true
        state.heard = ""
        resize()
    }

    func hear(_ text: String) {
        state.heard = text
        resize()
    }

    func stopListening() {
        state.listening = false
        resize()
    }

    func toggleMute() {
        state.muted.toggle()
        speaker.muted = state.muted
    }

    func fail(_ message: String) {
        state.working = false
        state.error = message
        resize()
    }

    func close() {
        runner.cancel()
        speaker.stop()
        panel?.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let image { try? FileManager.default.removeItem(at: image) }
        image = nil
        history = []
    }

    // MARK: Window

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = FirstMouseHostingView(rootView: AskBubbleView(state: state, onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(self?.state.answer ?? "", forType: .string)
            }, onFollowUp: { [weak self] in self?.followUp() },
               onMute: { [weak self] in self?.toggleMute() },
               onClose: { [weak self] in self?.close() },
               onDrag: { [weak self] ended in self?.drag(ended: ended) },
               onResize: { [weak self] ended in self?.resizeDrag(ended: ended) }))
            panel = p
        }
        resize()
        panel?.orderFrontRegardless()
        if clickMonitor == nil {
            // Clicking anywhere else dismisses it (not while it's thinking or listening).
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, let panel = self.panel, !self.state.working, !self.state.listening else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
    }

    private func resize() {
        guard let panel, let view = panel.contentView else { return }
        DispatchQueue.main.async {
            let width = self.state.width
            let height = min(self.state.answerHeight + 170, max(64, view.fittingSize.height))
            if let top = self.placedTop {
                panel.setFrame(NSRect(x: top.x, y: top.y - height, width: width, height: height), display: true)
                return
            }
            // Under the box if there's room, otherwise above it.
            let screen = NSScreen.screens.first { $0.frame.intersects(self.anchor) } ?? NSScreen.screens[0]
            var x = self.anchor.midX - width / 2
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - width - 8)
            var y = self.anchor.minY - height - 8
            if y < screen.visibleFrame.minY + 8 { y = min(self.anchor.maxY + 8, screen.visibleFrame.maxY - height - 8) }
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }
}

private struct AskBubbleView: View {
    @ObservedObject var state: AskBubble.State
    let onCopy: () -> Void
    let onFollowUp: () -> Void
    let onMute: () -> Void
    let onClose: () -> Void
    let onDrag: (Bool) -> Void
    let onResize: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let question = state.question, !state.listening {
                Text("“\(question)”")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(3)
            }
            if state.listening {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, isActive: true)
                    Text(state.heard.isEmpty ? "Listening… let go of ⌥ when you're done" : state.heard)
                        .font(.system(size: 12.5))
                        .foregroundStyle(state.heard.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if state.answer.isEmpty && state.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at what you pointed at…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if !state.answer.isEmpty {
                ScrollView {
                    Text(Self.markdown(state.answer))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: state.answerHeight)
            }
            if let error = state.error, !state.listening {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.working && !state.listening && !state.answer.isEmpty {
                HStack(spacing: 6) {
                    Label("Hold ⌥ here to reply", systemImage: "mic")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    CardButton(title: copied ? "Copied" : "Copy") {
                        onCopy()
                        copied = true
                    }
                    CardButton(title: "Type", primary: true, action: onFollowUp)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(width: state.width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.07).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // A barely-there backing over the whole window: macOS sends clicks and scrolls on fully transparent pixels
        // to whatever is behind, so this keeps everything inside the bubble's frame in the bubble.
        .background(Color.black.opacity(0.002))
        .environment(\.colorScheme, .dark)
    }

    /// Bottom-right corner grip.
    private var resizeGrip: some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                let inset = CGFloat(i) * 4 + 3
                var path = Path()
                path.move(to: CGPoint(x: size.width - inset, y: size.height - 3))
                path.addLine(to: CGPoint(x: size.width - 3, y: size.height - inset))
                ctx.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1.2)
            }
        }
        .frame(width: 18, height: 18)
        .padding(5)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in onResize(false) }
            .onEnded { _ in onResize(true) })
        .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
    }

    /// Drag the bubble anywhere by its top bar.
    private var dragToMove: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { _ in onDrag(false) }
            .onEnded { _ in onDrag(true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentBadge(source: state.engine.rawValue, size: 18)
            Text(state.engine.name).font(.system(size: 12, weight: .semibold))
            if state.working {
                Text(state.answer.isEmpty ? "looking…" : "answering…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if state.voiceMode {
                Button(action: onMute) {
                    Image(systemName: state.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .contentShape(Rectangle())
        .gesture(dragToMove)
        .onHover { inside in (inside ? NSCursor.openHand : NSCursor.arrow).set() }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
