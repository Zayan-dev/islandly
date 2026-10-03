import AVFoundation
import Speech

// Voice for "Hold ⌥ to Ask": your question is heard while you hold ⌥ (transcribed on-device), and the answer is
// spoken back with the Mac's own voices. Nothing here sends audio anywhere; only the transcribed words are asked.

/// Push-to-talk speech input: microphone → Apple's on-device SpeechTranscriber.
final class VoiceInput {
    /// The words so far (finished + in-progress), on the main thread.
    var onText: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    /// Audio captured before the recognizer is ready (it takes a moment to start), so first words aren't lost.
    private var pending: [AVAudioPCMBuffer] = []
    private var resultsTask: Task<Void, Never>?
    private var finished = ""
    private var current = ""
    private var run = 0

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default: done(false)
        }
    }

    static var microphoneAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    var transcript: String { (finished + current).trimmingCharacters(in: .whitespacesAndNewlines) }

    func start() {
        stopEngine()
        run += 1
        let run = self.run
        finished = ""
        current = ""
        lock.withLock { pending = []; continuation = nil; converter = nil; format = nil }
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buffer, _ in self?.feed(buffer) }
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        Task { @MainActor in await self.startRecognizer(run) }
    }

    /// Stops listening and hands back the final words (waits briefly for the recognizer to finish).
    func stop(_ done: @escaping (String) -> Void) {
        stopEngine()
        let (analyzer, continuation) = lock.withLock { () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?) in
            let v = (self.analyzer, self.continuation)
            self.analyzer = nil
            self.continuation = nil
            self.pending = []
            return v
        }
        continuation?.finish()
        let task = resultsTask
        var called = false
        let finish = { [weak self] in
            guard !called else { return }
            called = true
            self?.run += 1
            done(self?.transcript ?? "")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: finish)   // never wait long
        Task { @MainActor in
            if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            _ = await task?.value
            finish()
        }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation, let format else {
            if pending.count < 400, let copy = Self.copy(buffer) { pending.append(copy) }   // ~10 s at most
            return
        }
        if let out = convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    @MainActor
    private func startRecognizer(_ run: Int) async {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard run == self.run, let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            try await analyzer.start(inputSequence: stream)
            guard run == self.run else { continuation.finish(); await analyzer.cancelAndFinishNow(); return }
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await MainActor.run {
                            guard let self else { return }
                            if result.isFinal { self.finished += text; self.current = "" } else { self.current = text }
                            self.onText?(self.transcript)
                        }
                    }
                } catch {}
            }
            lock.withLock {
                self.analyzer = analyzer
                self.format = format
                self.continuation = continuation
                for buffer in pending { if let out = convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: out)) } }
                pending = []
            }
        } catch {}
    }

    /// Caller holds the lock.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status != .error && out.frameLength > 0 ? out : nil
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: Int(buffer.frameLength)) }
        } else { return nil }
        return copy
    }
}

/// Reads the answer aloud as it streams: each finished sentence is spoken while the next one arrives.
final class AnswerSpeaker {
    private let synth = AVSpeechSynthesizer()
    private var spokenUpTo = 0
    var muted = false {
        didSet { if muted { stop() } }
    }

    /// The best English voice installed (premium, then enhanced), in the user's own accent when there is one.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let mine = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let quality = v.quality == .premium ? 3 : (v.quality == .enhanced ? 2 : 1)
            let accent = v.language == mine ? 2 : (v.language == "en-US" ? 1 : 0)
            let novelty = v.voiceTraits.contains(.isNoveltyVoice) ? -10 : 0
            return quality * 10 + accent + novelty
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    func reset() {
        stop()
        spokenUpTo = 0
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    /// `text` is the whole answer so far; speaks the complete sentences not yet spoken (all of it when `final`).
    func feed(_ text: String, final: Bool) {
        guard !muted, text.count > spokenUpTo else { return }
        let start = text.index(text.startIndex, offsetBy: spokenUpTo)
        let rest = text[start...]
        var end = rest.startIndex
        if final {
            end = rest.endIndex
        } else {
            // Up to the last sentence end followed by a space or newline.
            var i = rest.startIndex
            while i < rest.endIndex {
                let next = rest.index(after: i)
                if ".!?\n".contains(rest[i]), next < rest.endIndex, rest[next].isWhitespace { end = next }
                i = next
            }
        }
        guard end > rest.startIndex else { return }
        let chunk = Self.plain(String(rest[rest.startIndex..<end]))
        spokenUpTo += rest.distance(from: rest.startIndex, to: end)
        guard !chunk.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: chunk)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(utterance)
    }

    /// Markdown and code symbols aren't meant to be read aloud.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"`{1,3}|\*{1,2}|_{2}|^#+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
