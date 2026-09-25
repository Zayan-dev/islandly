import AppKit
import AVFoundation
import Speech
import SwiftUI

// MARK: - Live on-device transcription

/// Streams audio into Apple's speech recognizer (on-device when supported) and reports the running transcript.
/// Recognition requests are rotated every ~50 s because a single request can't run forever.
final class LiveTranscriber {
    /// (transcript of the current segment, segment number)
    var onText: ((String, Int) -> Void)?
    var contextualStrings: [String] = []

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt = Date()
    private var segment = 0
    private var running = false

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    /// Transcription must stay on this Mac; if on-device recognition isn't available we don't start at all.
    static var isAvailableOnDevice: Bool {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return false }
        return r.isAvailable && r.supportsOnDeviceRecognition
    }

    func start() {
        guard Self.isAvailableOnDevice else { return }
        running = true
        newSegment()
    }

    func stop() {
        running = false
        lock.lock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        request?.append(buffer)
        lock.unlock()
        rotateIfNeeded()
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        request?.appendAudioSampleBuffer(sampleBuffer)
        lock.unlock()
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        lock.lock()
        let due = Date().timeIntervalSince(startedAt) > 50
        if due { startedAt = Date() }
        lock.unlock()
        if due { DispatchQueue.main.async { self.newSegment() } }
    }

    private func newSegment() {
        guard running, let recognizer, recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = contextualStrings
        guard recognizer.supportsOnDeviceRecognition else { return }
        request.requiresOnDeviceRecognition = true  // never send audio to a server

        lock.lock()
        self.request?.endAudio()
        task?.cancel()
        self.request = request
        startedAt = Date()
        segment += 1
        let segment = self.segment
        let began = startedAt
        lock.unlock()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.onText?(text, segment) }
            }
            guard error != nil || result?.isFinal == true else { return }
            // Segment ended (silence timeout, final result, error) → start a fresh one.
            // Back off if it died instantly so a persistent error can't spin.
            let delay = Date().timeIntervalSince(began) < 1 ? 2.0 : 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.lock.lock()
                let current = self.segment == segment
                self.lock.unlock()
                if current { self.newSegment() }
            }
        }
    }
}

/// Lower-cased words with punctuation stripped, for matching speech against text.
func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

// MARK: - Small editor window (the island itself can't take keyboard focus)

enum TextEditorWindow {
    private static var open: [String: NSWindow] = [:]

    static func show(title: String, text: String, prompt: String, onSave: @escaping (String) -> Void) {
        if let window = open[title] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let close = { [weak window] in
            window?.close()
            open[title] = nil
        }
        window.contentView = NSHostingView(rootView: EditorView(prompt: prompt, text: text, onSave: { value in
            onSave(value)
            close()
        }, onCancel: close))
        window.center()
        window.level = .floating
        open[title] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct EditorView: View {
    let prompt: String
    @State var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }
}
