import AVFoundation
import Speech

/// Something the transcriber heard: its best guess plus the alternatives it considered, each as words with the time
/// (in seconds of audio) they were spoken. Alternatives matter for names: "Zayan" is often only the second guess.
struct Heard {
    struct Word {
        let text: String
        let time: Double
    }
    let candidates: [[Word]]
    let isFinal: Bool
}

/// Transcribes what the Mac is playing, entirely on-device, for Name Alert.
///
/// Uses Apple's SpeechTranscriber (macOS 26): built for long, far-field conversation, it runs continuously and
/// reports words as they're spoken. Where it isn't available, falls back to the older SFSpeechRecognizer.
final class CallTranscriber {
    var onHeard: ((Heard) -> Void)?
    /// A one-time setup message (e.g. the speech model downloading), or nil when there's nothing to say.
    var onStatus: ((String?) -> Void)?
    var onError: ((Error) -> Void)?
    var keywords: [String] = [] { didSet { updateContext() } }

    static var isAvailable: Bool { SpeechTranscriber.isAvailable || LiveTranscriber.isAvailableOnDevice }

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var legacy: LiveTranscriber?
    private var resultsTask: Task<Void, Never>?
    /// Bumped by every start/stop so late async steps of an old run are discarded.
    private var run = 0

    func start() {
        stop()
        let run = self.run
        if SpeechTranscriber.isAvailable {
            Task { @MainActor in await self.startModern(run) }
        } else {
            startLegacy()
        }
    }

    func stop() {
        run += 1
        resultsTask?.cancel()
        resultsTask = nil
        lock.lock()
        let analyzer = self.analyzer, input = self.input, legacy = self.legacy
        self.analyzer = nil
        self.input = nil
        self.format = nil
        self.converter = nil
        self.legacy = nil
        lock.unlock()
        input?.finish()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        legacy?.stop()
    }

    /// Called on the audio capture queue.
    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let legacy {
            legacy.append(sampleBuffer)
            return
        }
        guard let input, let format, let pcm = Self.pcmBuffer(sampleBuffer) else { return }
        if converter?.inputFormat != pcm.format { converter = AVAudioConverter(from: pcm.format, to: format) }
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * format.sampleRate / pcm.format.sampleRate) + 32
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, out.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: out))
    }

    // MARK: SpeechTranscriber

    @MainActor
    private func startModern(_ run: Int) async {
        do {
            let transcriber = SpeechTranscriber(locale: await Self.locale(),
                                                transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .alternativeTranscriptions, .fastResults],
                                                attributeOptions: [.audioTimeRange])
            // First use only: Apple's speech model for the language (downloaded by macOS, then kept on the Mac).
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onStatus?("Downloading Apple's on-device speech model (one time)…")
                try await request.downloadAndInstall()
                onStatus?(nil)
            }
            guard run == self.run else { return }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CocoaError(.featureUnsupported)
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let context = AnalysisContext()
            context.contextualStrings[.general] = keywords
            try await analyzer.setContext(context)
            // Keep at most ~20 s of audio queued if transcription ever falls behind.
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(200))
            try await analyzer.start(inputSequence: stream)
            guard run == self.run else {
                continuation.finish()
                await analyzer.cancelAndFinishNow()
                return
            }
            lock.withLock {
                self.analyzer = analyzer
                self.input = continuation
                self.format = format
            }
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let heard = Self.heard(from: result)
                        await MainActor.run {
                            guard let self, run == self.run else { return }
                            self.onHeard?(heard)
                        }
                    }
                } catch {
                    await MainActor.run {
                        guard let self, run == self.run, !(error is CancellationError) else { return }
                        self.onError?(error)
                    }
                }
            }
        } catch {
            guard run == self.run else { return }
            onStatus?(nil)
            // e.g. the model couldn't download (offline): the older recognizer still works.
            if LiveTranscriber.isAvailableOnDevice { startLegacy() } else { onError?(error) }
        }
    }

    private func updateContext() {
        lock.lock()
        let analyzer = self.analyzer, legacy = self.legacy
        lock.unlock()
        legacy?.contextualStrings = keywords
        guard let analyzer else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = keywords
        Task { try? await analyzer.setContext(context) }
    }

    /// The user's own English variant when Apple supports it (en-GB, en-IN, en-AU…), otherwise US English.
    private static func locale() async -> Locale {
        let current = Locale.current
        if current.language.languageCode == .english,
           let match = await SpeechTranscriber.supportedLocales.first(where: {
               $0.language.languageCode == .english && $0.region == current.region
           }) {
            return match
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) ?? Locale(identifier: "en-US")
    }

    private static func heard(from result: SpeechTranscriber.Result) -> Heard {
        let start = result.range.start.seconds
        let fallback = start.isFinite ? start : 0
        func words(_ text: AttributedString) -> [Heard.Word] {
            var out: [Heard.Word] = []
            for run in text.runs {
                let time = run.audioTimeRange.map(\.start.seconds).flatMap { $0.isFinite ? $0 : nil } ?? fallback
                for word in String(text[run.range].characters).split(whereSeparator: \.isWhitespace) {
                    out.append(Heard.Word(text: String(word), time: time))
                }
            }
            return out
        }
        return Heard(candidates: [words(result.text)] + result.alternatives.map(words), isFinal: result.isFinal)
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }

    // MARK: Fallback: SFSpeechRecognizer

    private func startLegacy() {
        let legacy = LiveTranscriber()
        legacy.contextualStrings = keywords
        legacy.onText = { [weak self] text, segment in
            // No word times here: a word's position in its segment stands in for time, so the same mention
            // (re-sent as the transcript grows) is recognised as the same one.
            let words = text.split(separator: " ").enumerated().map { index, word in
                Heard.Word(text: String(word), time: Double(segment) * 100_000 + Double(index))
            }
            self?.onHeard?(Heard(candidates: [words], isFinal: false))
        }
        lock.lock()
        self.legacy = legacy
        lock.unlock()
        legacy.start()
    }
}
