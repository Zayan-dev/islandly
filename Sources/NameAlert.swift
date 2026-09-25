import AppKit
import SwiftUI

struct Mention: Identifiable, Equatable {
    let id = UUID()
    let keyword: String
    let context: String
    let date: Date
}

/// Listens to what your Mac is *playing* (the other people on a call, a lecture, a video) — not your microphone —
/// transcribes it on-device, and alerts when someone says one of your keywords. Nothing is recorded or stored.
final class NameAlertModel: NSObject, ObservableObject {
    enum Mode: String, CaseIterable {
        case off, auto, always
        var label: String {
            switch self {
            case .off: return "Off"
            case .auto: return "Auto on calls"
            case .always: return "Always"
            }
        }
    }

    @Published private(set) var isListening = false
    /// Off / only during calls (default) / all the time.
    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "nameAlertMode")
            applyMode()
        }
    }
    /// Name of the call app while Auto mode sees a call (e.g. "Microsoft Teams").
    @Published private(set) var callApp: String?
    @Published private(set) var keywords: [String]
    @Published private(set) var mentions: [Mention] = []
    @Published private(set) var problem: String?
    /// Last few words heard (shown faintly in the panel so you can see it working).
    @Published private(set) var liveSnippet = ""
    /// Flash + loud alert + spoken callout when you're away from the Mac.
    @Published var buzzWhenAway: Bool { didSet { UserDefaults.standard.set(buzzWhenAway, forKey: "nameAlertBuzz") } }
    /// Seconds without mouse/keyboard input before you count as "away" (user preference).
    /// Also detect calls in browser tabs (Google Meet, Teams web, Zoom web). Off by default: costs a little battery.
    @Published var detectBrowserCalls: Bool {
        didSet {
            UserDefaults.standard.set(detectBrowserCalls, forKey: "nameAlertBrowserCalls")
            calls.checkBrowsers = detectBrowserCalls
        }
    }
    @Published var awayAfter: TimeInterval { didSet { UserDefaults.standard.set(awayAfter, forKey: "nameAlertAwayAfter") } }
    static let awayChoices: [TimeInterval] = [5, 15, 30, 60, 120, 300]

    var onMention: ((Mention) -> Void)?
    /// Auto mode switched listening on because a call started.
    var onCallStarted: ((String) -> Void)?

    private let calls = CallDetector()
    private var starting = false
    private var pollCount = 0

    private let transcriber = LiveTranscriber()
    /// Highest occurrence count already alerted, per keyword, for the current transcript segment.
    private var alerted: [String: Int] = [:]
    private var alertedSegment = 0
    private var lastAlert: [String: Date] = [:]

    override init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "nameAlertKeywords"), !saved.isEmpty {
            keywords = saved
        } else {
            // Default to the account's name parts (e.g. "Muhammad Zayan" → both).
            keywords = NSFullUserName().split(separator: " ").map(String.init).filter { $0.count > 1 }
        }
        buzzWhenAway = UserDefaults.standard.object(forKey: "nameAlertBuzz") as? Bool ?? false
        let savedAway = UserDefaults.standard.double(forKey: "nameAlertAwayAfter")
        awayAfter = savedAway > 0 ? savedAway : 15
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "nameAlertMode") ?? "") ?? .auto
        detectBrowserCalls = UserDefaults.standard.bool(forKey: "nameAlertBrowserCalls")
        super.init()
        calls.checkBrowsers = detectBrowserCalls
        transcriber.onText = { [weak self] text, segment in self?.scan(text, segment: segment) }
        calls.onChange = { [weak self] inCall, app in
            guard let self else { return }
            self.callApp = app
            guard self.mode == .auto else { return }
            if inCall {
                self.start()
                self.onCallStarted?(app ?? "a call")
            } else {
                self.stop()
            }
        }
    }

    /// Called every second; call detection runs every 3 s.
    func tick() {
        pollCount += 1
        guard pollCount % 3 == 0, mode == .auto else { return }
        calls.poll()
        if calls.callApp != callApp { callApp = calls.callApp }
    }

    func applyMode() {
        switch mode {
        case .off: stop()
        case .always: start()
        case .auto: calls.inCall ? start() : stop()
        }
    }

    func setKeywords(_ text: String) {
        keywords = text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        UserDefaults.standard.set(keywords, forKey: "nameAlertKeywords")
        transcriber.contextualStrings = keywords
    }


    func start() {
        guard !isListening, !starting else { return }
        starting = true
        problem = nil
        LiveTranscriber.requestAuthorization { ok in
            guard ok, LiveTranscriber.isAvailableOnDevice else {
                self.starting = false
                if ok {
                    self.problem = "On-device speech recognition isn't available on this Mac, so Name Alert stays off (audio never leaves your Mac)."
                    return
                }
                self.problem = "Allow Speech Recognition for Islandly in System Settings ▸ Privacy & Security."
                return
            }
            self.startStream()
        }
    }

    func stop() {
        SystemAudioTap.shared.unsubscribe("nameAlert")
        transcriber.stop()
        isListening = false
        starting = false
        liveSnippet = ""
    }

    private func startStream() {
        transcriber.contextualStrings = keywords
        transcriber.start()
        let transcriber = self.transcriber
        SystemAudioTap.shared.subscribe("nameAlert", handler: { transcriber.append($0) }, onError: { [weak self] error in
            self?.stop()
            self?.problem = "Listening stopped: \(error.localizedDescription)"
        }, started: { [weak self] error in
            guard let self else { return }
            self.starting = false
            if let error {
                self.transcriber.stop()
                SystemAudioTap.shared.unsubscribe("nameAlert")
                self.problem = "Couldn't listen to system audio: \(error.localizedDescription)"
            } else {
                self.isListening = true
            }
        })
    }

    // MARK: Matching

    /// Capitalized words that *sound* like the keyword (names often come out as "Zane" for "Zayan").
    /// Lower-case words are skipped so everyday words ("zone") don't trigger alerts.
    private func soundAlikeMatches(of keyword: String, in text: String) -> [NSTextCheckingResult] {
        let target = soundex(keyword)
        guard target.count == 4, keyword.count >= 3,
              let regex = try? NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z']+\\b") else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            guard let range = Range(match.range, in: text) else { return false }
            let word = String(text[range])
            return word.caseInsensitiveCompare(keyword) != .orderedSame
                && abs(word.count - keyword.count) <= 2
                && soundex(word) == target
        }
    }

    /// Classic Soundex code (e.g. Zayan, Zane, Zayn → Z500).
    private func soundex(_ word: String) -> String {
        let codes: [Character: Character] = [
            "b": "1", "f": "1", "p": "1", "v": "1",
            "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
            "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
        ]
        let letters = Array(word.lowercased().filter(\.isLetter))
        guard let first = letters.first else { return "" }
        var result = String(first).uppercased()
        var last = codes[first]
        for ch in letters.dropFirst() {
            let code = codes[ch]
            if let code, code != last { result.append(code) }
            if ch != "h" && ch != "w" { last = code }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    private func scan(_ text: String, segment: Int) {
        if segment != alertedSegment {
            alertedSegment = segment
            alerted = [:]
        }
        let words = text.split(separator: " ").map(String.init)
        liveSnippet = words.suffix(8).joined(separator: " ")

        for keyword in keywords {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: keyword) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            var matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            matches += soundAlikeMatches(of: keyword, in: text)
            matches.sort { $0.range.location < $1.range.location }
            let seen = alerted[keyword.lowercased()] ?? 0
            guard matches.count > seen, let match = matches.last, let range = Range(match.range, in: text) else { continue }
            alerted[keyword.lowercased()] = matches.count

            // Same keyword at most once every 15 s (transcripts get revised while you speak).
            if let last = lastAlert[keyword.lowercased()], Date().timeIntervalSince(last) < 15 { continue }
            lastAlert[keyword.lowercased()] = Date()

            let before = text[..<range.lowerBound].split(separator: " ").suffix(9).joined(separator: " ")
            let after = text[range.upperBound...].split(separator: " ").prefix(4).joined(separator: " ")
            let context = "…\(before) \(text[range]) \(after)".trimmingCharacters(in: .whitespaces)
            let mention = Mention(keyword: keyword, context: context, date: Date())
            mentions.insert(mention, at: 0)
            if mentions.count > 10 { mentions.removeLast() }
            onMention?(mention)
        }
    }
}

// MARK: - Panel (Home)

struct NameAlertPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let alert = model.nameAlert
        VStack(alignment: .leading, spacing: 11) {
            // 1. Status + mode
            HStack(spacing: 8) {
                statusDot(alert)
                Text(statusTitle(alert))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Picker("", selection: Binding(get: { alert.mode }, set: { alert.mode = $0 })) {
                    ForEach(NameAlertModel.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }

            // 2. Keywords
            HStack(spacing: 6) {
                rowLabel("Listening for")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(alert.keywords, id: \.self) { keyword in
                            Text(keyword)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.purple.opacity(0.35)))
                        }
                        Button {
                            TextEditorWindow.show(title: "Name Alert Keywords",
                                                  text: alert.keywords.joined(separator: ", "),
                                                  prompt: "Words to listen for, separated by commas — your name, nickname, team, project…") {
                                alert.setKeywords($0)
                            }
                        } label: {
                            Label("Edit", systemImage: "plus")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 3. Browser calls (Auto mode only)
            HStack(spacing: 6) {
                rowLabel("Browser calls")
                MiniSwitch(isOn: alert.detectBrowserCalls, tint: .purple) { alert.detectBrowserCalls.toggle() }
                Text(alert.detectBrowserCalls
                     ? "Checks tabs every 30s · small battery use"
                     : "No battery use · muted Meet calls missed")
                    .font(.system(size: 10))
                    .foregroundStyle(alert.detectBrowserCalls ? Color.orange.opacity(0.9) : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .opacity(alert.mode == .auto ? 1 : 0.4)
            .disabled(alert.mode != .auto)

            // 4. Buzz when away + idle threshold
            HStack(spacing: 6) {
                rowLabel("Buzz when away")
                MiniSwitch(isOn: alert.buzzWhenAway, tint: .orange) { alert.buzzWhenAway.toggle() }
                if alert.buzzWhenAway {
                    Text("after")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        ForEach(NameAlertModel.awayChoices, id: \.self) { seconds in
                            let selected = alert.awayAfter == seconds
                            Button { alert.awayAfter = seconds } label: {
                                Text(formatAway(seconds))
                                    .font(.system(size: 11, weight: selected ? .bold : .medium))
                                    .foregroundStyle(selected ? .black : .white.opacity(0.8))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(selected ? Color.orange : .white.opacity(0.08)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        // Custom value: shows the number when it isn't one of the presets.
                        let custom = !NameAlertModel.awayChoices.contains(alert.awayAfter)
                        Button {
                            TextEditorWindow.show(title: "Away After (seconds)",
                                                  text: "\(Int(alert.awayAfter))",
                                                  prompt: "Seconds without mouse or keyboard activity before you count as away (3 – 3600).") { text in
                                let digits = text.filter(\.isNumber)
                                if let value = Double(digits) { alert.awayAfter = min(3600, max(3, value)) }
                            }
                        } label: {
                            Text(custom ? formatAway(alert.awayAfter) : "Custom")
                                .font(.system(size: 11, weight: custom ? .bold : .medium))
                                .foregroundStyle(custom ? .black : .white.opacity(0.8))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(custom ? Color.orange : .white.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Flash + loud alert when you've stepped away")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // 4. Last mention / live status / problem
            Group {
                if let problem = alert.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if let mention = alert.mentions.first {
                    let head = Text("\u{201C}\(mention.keyword)\u{201D} · \(ago(mention.date))  ").fontWeight(.semibold)
                    let body = Text(mention.context).foregroundColor(.secondary)
                    Text("\(head)\(body)")
                } else {
                    Text(hintText(alert)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .card(10)
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    @ViewBuilder
    private func statusDot(_ alert: NameAlertModel) -> some View {
        Circle()
            .fill(alert.isListening ? Color.purple : (alert.mode == .off ? Color.gray : Color.white.opacity(0.4)))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.purple.opacity(alert.isListening ? 0.5 : 0), lineWidth: 4).scaleEffect(1.6))
    }

    private func statusTitle(_ alert: NameAlertModel) -> String {
        switch alert.mode {
        case .off: return "Name Alert is off"
        case .auto: return alert.isListening ? "Listening · \(alert.callApp ?? "call")" : "Waiting for a call"
        case .always: return alert.isListening ? "Listening · all audio" : "Starting…"
        }
    }

    private func hintText(_ alert: NameAlertModel) -> String {
        if alert.isListening, !alert.liveSnippet.isEmpty { return "Hearing: \(alert.liveSnippet)" }
        switch alert.mode {
        case .off: return "Turn on to get a purple flash + beep when someone says your name."
        case .auto: return "Turns on by itself when you join a call — and stays on while you're muted."
        case .always: return "Listening to everything your Mac plays. Transcribed on-device, never recorded."
        }
    }

    private func formatAway(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m\(s % 60)s"
    }

    private func ago(_ date: Date) -> String {
        let s = Int(model.system.now.timeIntervalSince(date))
        return s < 10 ? "just now" : (s < 60 ? "\(s)s ago" : (s < 3600 ? "\(s / 60)m ago" : date.formatted(date: .omitted, time: .shortened)))
    }
}

/// Small iOS-style switch (a plain Toggle doesn't take clicks reliably in the non-activating panel).
struct MiniSwitch: View {
    let isOn: Bool
    var tint: Color = .green
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isOn ? tint : Color.white.opacity(0.2))
                .frame(width: 28, height: 16)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
