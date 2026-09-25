import AVFoundation
import ScreenCaptureKit

/// One shared capture of what the Mac is *playing* (never the microphone). Name Alert transcribes it. The stream runs only while at least one feature is subscribed.
final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = SystemAudioTap()

    typealias Handler = (CMSampleBuffer) -> Void

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var onError: [String: (Error) -> Void] = [:]
    private var stream: SCStream?
    private var starting = false
    private var pending: [(Error?) -> Void] = []
    private let queue = DispatchQueue(label: "dynamic-island.audio-tap")

    func subscribe(_ id: String, handler: @escaping Handler, onError: @escaping (Error) -> Void = { _ in },
                   started: @escaping (Error?) -> Void) {
        lock.lock()
        handlers[id] = handler
        self.onError[id] = onError
        lock.unlock()

        if stream != nil { started(nil); return }
        pending.append(started)
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            let error = await self.startStream()
            self.starting = false
            let callbacks = self.pending
            self.pending = []
            callbacks.forEach { $0(error) }
        }
    }

    func unsubscribe(_ id: String) {
        lock.lock()
        handlers[id] = nil
        onError[id] = nil
        let empty = handlers.isEmpty
        lock.unlock()
        if empty {
            stream?.stopCapture(completionHandler: nil)
            stream = nil
        }
    }

    @MainActor
    private func startStream() async -> Error? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000
            config.channelCount = 1
            // Audio only: keep the (required) video side as tiny and infrequent as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                  configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
            return nil
        } catch {
            return error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        lock.lock()
        let current = Array(handlers.values)
        lock.unlock()
        current.forEach { $0(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.stream = nil
            self.lock.lock()
            let callbacks = Array(self.onError.values)
            self.handlers = [:]
            self.onError = [:]
            self.lock.unlock()
            callbacks.forEach { $0(error) }
        }
    }
}
