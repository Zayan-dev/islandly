import AppKit
import AVFoundation

/// "Buzz" for when you're away from the Mac (it has no vibration motor): full-screen flash, a loud chime,
/// and a spoken callout — repeated until you touch the mouse or keyboard.
final class AttentionAlert {
    static let shared = AttentionAlert()

    private let repeatEvery: TimeInterval = 8
    private let maxRounds = 5

    private var timer: Timer?
    private var rounds = 0
    private var startedAt = Date()
    private var restoreVolume: Int?
    private let speech = AVSpeechSynthesizer()
    private var flashWindows: [NSWindow] = []

    static var secondsSinceInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var isActive: Bool { timer != nil }

    func start(saying message: String) {
        stop()
        startedAt = Date()
        rounds = 0
        boostVolume()
        round(message)
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.check(message) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        speech.stopSpeaking(at: .immediate)
        restoreVolumeIfNeeded()
    }

    private var nextRoundAt = Date()

    private func check(_ message: String) {
        // You're back: any input since the alert started stops it.
        if Self.secondsSinceInput < Date().timeIntervalSince(startedAt) - 0.5 {
            stop()
            return
        }
        guard Date() >= nextRoundAt else { return }
        if rounds >= maxRounds { stop(); return }
        round(message)
    }

    private func round(_ message: String) {
        rounds += 1
        nextRoundAt = Date().addingTimeInterval(repeatEvery)
        flashScreens()
        NSSound(named: "Sosumi")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard self.isActive else { return }
            let utterance = AVSpeechUtterance(string: message)
            utterance.rate = 0.5
            utterance.volume = 1
            self.speech.speak(utterance)
        }
    }

    // MARK: Screen flash

    private func flashScreens() {
        flashWindows.forEach { $0.orderOut(nil) }
        flashWindows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = NSColor.systemPurple
            window.alphaValue = 0
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
        pulse(times: 3)
    }

    private func pulse(times: Int) {
        guard times > 0 else {
            flashWindows.forEach { $0.orderOut(nil) }
            flashWindows = []
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            flashWindows.forEach { $0.animator().alphaValue = 0.55 }
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.28
                self.flashWindows.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                self.pulse(times: times - 1)
            })
        })
    }

    // MARK: Volume (raised while alerting, then put back)

    private func boostVolume() {
        DispatchQueue.global(qos: .userInitiated).async {
            let current = Int(runAppleScript("output volume of (get volume settings)") ?? "") ?? 50
            let muted = runAppleScript("output muted of (get volume settings)") == "true"
            guard current < 70 || muted else { return }
            DispatchQueue.main.async { self.restoreVolume = muted ? -1 : current }
            runAppleScript("set volume output volume 75 without output muted")
        }
    }

    private func restoreVolumeIfNeeded() {
        guard let restore = restoreVolume else { return }
        restoreVolume = nil
        DispatchQueue.global(qos: .userInitiated).async {
            if restore == -1 {
                runAppleScript("set volume with output muted")
            } else {
                runAppleScript("set volume output volume \(restore)")
            }
        }
    }
}
