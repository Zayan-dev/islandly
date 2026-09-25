import AppKit
import AVFoundation
import SwiftUI

// MARK: - Teleprompter model

final class PrompterModel: ObservableObject {
    enum Mode: String { case auto, voice }

    @Published private(set) var script: String
    @Published private(set) var words: [String] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var countdown: Int?
    /// Index of the next word to be read.
    @Published private(set) var position = 0
    @Published var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "prompterMode") } }
    @Published var wordsPerMinute: Double { didSet { UserDefaults.standard.set(wordsPerMinute, forKey: "prompterWPM") } }
    @Published private(set) var micDenied = false
    /// Mouse is over the running prompter (shows its controls).
    @Published var hovering = false

    static let width: CGFloat = 580
    static let visibleLines = 3
    static let lineHeight: CGFloat = 30
    static let font = NSFont.systemFont(ofSize: 21, weight: .semibold)

    private var normalized: [String] = []
    private var autoTimer: Timer?
    private let engine = AVAudioEngine()
    private let transcriber = LiveTranscriber()

    init() {
        script = UserDefaults.standard.string(forKey: "prompterScript")
            ?? "Paste or write your script, then press Start. The text scrolls right under your camera, so you keep eye contact while you read."
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "prompterMode") ?? "") ?? .auto
        let wpm = UserDefaults.standard.double(forKey: "prompterWPM")
        wordsPerMinute = wpm > 0 ? wpm : 140
        setScript(script)
        transcriber.onText = { [weak self] text, _ in self?.follow(spoken: text) }
    }

    var estimatedMinutes: Int { max(1, Int((Double(words.count) / 140).rounded())) }

    func setScript(_ text: String) {
        script = text
        UserDefaults.standard.set(text, forKey: "prompterScript")
        words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        normalized = words.map { normalizedWords($0).joined() }
        position = 0
    }

    /// Word ranges per display line, wrapped to the prompter's width.
    private var lineCache: (script: String, lines: [Range<Int>]) = ("", [])
    var lines: [Range<Int>] {
        if lineCache.script == script { return lineCache.lines }
        let maxWidth = Self.width - 56
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font]
        let space = (" " as NSString).size(withAttributes: attrs).width
        var result: [Range<Int>] = []
        var start = 0, width: CGFloat = 0
        for (i, word) in words.enumerated() {
            let w = (word as NSString).size(withAttributes: attrs).width
            if i > start && width + space + w > maxWidth {
                result.append(start..<i)
                start = i
                width = w
            } else {
                width += (i > start ? space : 0) + w
            }
        }
        if start < words.count { result.append(start..<words.count) }
        lineCache = (script, result)
        return result
    }

    var currentLine: Int {
        lines.firstIndex { $0.contains(position) } ?? max(0, lines.count - 1)
    }

    // MARK: Control

    func start() {
        guard !words.isEmpty else { return }
        position = 0
        isRunning = true
        isPaused = false
        countdown = 3
        tickCountdown()
    }

    private func tickCountdown() {
        guard isRunning, let value = countdown else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard self.isRunning else { return }
            if value > 1 {
                self.countdown = value - 1
                self.tickCountdown()
            } else {
                self.countdown = nil
                self.beginScrolling()
            }
        }
    }

    private func beginScrolling() {
        switch mode {
        case .auto: scheduleAuto()
        case .voice: startListening()
        }
    }

    func togglePause() {
        guard isRunning, countdown == nil else { return }
        isPaused.toggle()
        if isPaused {
            autoTimer?.invalidate()
            stopListening()
        } else {
            beginScrolling()
        }
    }

    func stop() {
        isRunning = false
        isPaused = false
        countdown = nil
        hovering = false
        autoTimer?.invalidate()
        stopListening()
    }

    func restart() {
        position = 0
    }

    func nudge(lines delta: Int) {
        let target = min(max(0, currentLine + delta), max(0, lines.count - 1))
        if lines.indices.contains(target) { position = lines[target].lowerBound }
    }

    func changeSpeed(by delta: Double) {
        wordsPerMinute = min(260, max(60, wordsPerMinute + delta))
        if mode == .auto && isRunning && !isPaused && countdown == nil { scheduleAuto() }
    }

    private func scheduleAuto() {
        autoTimer?.invalidate()
        let timer = Timer(timeInterval: 60 / wordsPerMinute, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            if self.position < self.words.count {
                self.position += 1
            } else {
                self.autoTimer?.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoTimer = timer
    }

    // MARK: Voice follow

    private func startListening() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            LiveTranscriber.requestAuthorization { speechOK in
                guard granted, speechOK else {
                    self.micDenied = true
                    self.mode = .auto
                    self.scheduleAuto()
                    return
                }
                self.micDenied = false
                self.transcriber.contextualStrings = Array(Set(self.words.filter { $0.count > 5 })).prefix(80).map { $0 }
                self.transcriber.start()
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                    self?.transcriber.append(buffer)
                }
                try? self.engine.start()
            }
        }
    }

    private func stopListening() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        transcriber.stop()
    }

    /// Moves the position to just after the last words you said, searching a little ahead of where you are.
    private func follow(spoken: String) {
        guard isRunning, !isPaused, mode == .voice else { return }
        let said = normalizedWords(spoken).suffix(3)
        guard let last = said.last else { return }
        let window = position..<min(normalized.count, position + 30)
        for i in window where normalized[i] == last {
            let previousMatches = said.count < 2 || (i > 0 && normalized[i - 1] == said[said.index(before: said.endIndex - 1)])
            if previousMatches || last.count >= 4 {
                position = i + 1
                return
            }
        }
    }
}

// MARK: - Running prompter (shown under the notch, no hover needed)

struct PrompterView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let prompter = model.prompter
        let lines = prompter.lines
        let current = prompter.currentLine
        ZStack(alignment: .top) {
            if let countdown = prompter.countdown {
                Text("\(countdown)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, model.notchSize.height / 2)
            } else {
                // Current line sits at the top, as close to the camera as possible.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, range in
                        lineText(range, words: prompter.words, position: prompter.position, isCurrent: index == current)
                            .opacity(index < current ? 0 : (index == current ? 1 : (index == current + 1 ? 0.55 : 0.3)))
                            .frame(height: PrompterModel.lineHeight, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: -CGFloat(current) * PrompterModel.lineHeight)
                .animation(.easeInOut(duration: 0.35), value: current)
                .padding(.horizontal, 28)
                .padding(.top, model.notchSize.height + 6)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.black, .black, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom))

                if prompter.position >= prompter.words.count {
                    Label("End of script", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 8)
                }
            }

            // Top row beside the notch: status left, controls right (controls only on hover).
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(prompter.isPaused ? Color.orange : .red).frame(width: 7, height: 7)
                    Text(prompter.isPaused ? "Paused" : (prompter.mode == .voice ? "Following voice" : "\(Int(prompter.wordsPerMinute)) wpm"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if prompter.hovering {
                    HStack(spacing: 12) {
                        if prompter.mode == .auto {
                            IconButton(symbol: "tortoise.fill", help: "Slower") { prompter.changeSpeed(by: -15) }
                            IconButton(symbol: "hare.fill", help: "Faster") { prompter.changeSpeed(by: 15) }
                        }
                        IconButton(symbol: "chevron.up", help: "Back a line") { prompter.nudge(lines: -1) }
                        IconButton(symbol: "chevron.down", help: "Forward a line") { prompter.nudge(lines: 1) }
                        IconButton(symbol: prompter.isPaused ? "play.fill" : "pause.fill", help: "Pause") { prompter.togglePause() }
                        IconButton(symbol: "xmark", help: "Stop") { prompter.stop() }
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: model.notchSize.height)
            .padding(.horizontal, 18)
        }
        .animation(.easeOut(duration: 0.15), value: prompter.hovering)
    }

    private func lineText(_ range: Range<Int>, words: [String], position: Int, isCurrent: Bool) -> Text {
        range.reduce(Text("")) { partial, i in
            let word = Text(words[i] + " ")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(isCurrent && i < position ? .white.opacity(0.35) : .white)
            return Text("\(partial)\(word)")
        }
    }
}

// MARK: - Setup panel (Home)

struct PrompterPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let prompter = model.prompter
        VStack(alignment: .leading, spacing: 10) {
            Text(prompter.script)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .card(12)

            HStack(spacing: 8) {
                PillButton(title: "Edit script", symbol: "square.and.pencil") {
                    TextEditorWindow.show(title: "Teleprompter Script", text: prompter.script,
                                          prompt: "Your script scrolls right under the camera while you read.") {
                        prompter.setScript($0)
                    }
                }
                PillButton(title: "Paste", symbol: "doc.on.clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                        prompter.setScript(text)
                    }
                }
                Spacer()
                Text("\(prompter.words.count) words · ~\(prompter.estimatedMinutes) min")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Picker("", selection: Binding(get: { prompter.mode }, set: { prompter.mode = $0 })) {
                    Text("Auto scroll").tag(PrompterModel.Mode.auto)
                    Text("Follow my voice").tag(PrompterModel.Mode.voice)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                if prompter.mode == .auto {
                    Text("\(Int(prompter.wordsPerMinute)) wpm")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    IconButton(symbol: "minus", help: "Slower") { prompter.changeSpeed(by: -10) }
                    IconButton(symbol: "plus", help: "Faster") { prompter.changeSpeed(by: 10) }
                }
                Spacer()
                PillButton(title: "Start", symbol: "play.fill", tint: .red) {
                    model.homePanel = nil
                    prompter.start()
                }
            }
            if prompter.micDenied {
                Text("Voice follow needs Microphone and Speech Recognition access (System Settings ▸ Privacy).")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }
}
