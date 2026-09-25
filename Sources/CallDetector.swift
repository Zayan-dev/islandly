import AppKit
import CoreAudio

/// Decides whether you're in a call — robust to being muted. You count as "in a call" while ANY signal holds:
///   1. another app is using a microphone (you pick up a call),
///   2. a call app is running audio output (the others talking — works while you're muted),
///   3. a Zoom meeting window is open,
///   4. a browser tab is on a meeting (Google Meet, Teams web, Zoom web).
/// The call only "ends" after every signal has been gone for `endGrace` seconds.
final class CallDetector {
    private(set) var inCall = false
    /// e.g. "Microsoft Teams", "Google Meet"
    private(set) var callApp: String?

    var onChange: ((Bool, String?) -> Void)?

    private let endGrace: TimeInterval = 45
    private var lastSignal: Date?
    private var browserMeeting: String?
    /// Off = browser tabs are never checked (no cost). On = checks for Meet/Teams/Zoom web meeting tabs.
    var checkBrowsers = false {
        didSet { if !checkBrowsers { browserMeeting = nil } }
    }
    private var browserCheckRunning = false
    private var lastBrowserCheck = Date.distantPast

    private static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.cisco.webex", "Webex"), ("Cisco-Systems.Spark", "Webex"),
        ("com.skype", "Skype"),
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("desktop.WhatsApp", "WhatsApp"),
    ]

    private static let browsers: [(bundleID: String, script: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave Browser"), ("company.thebrowser.Browser", "Arc"),
        ("com.apple.Safari", "Safari"),
    ]

    /// Call every few seconds.
    func poll() {
        if checkBrowsers { refreshBrowserMeetingIfDue() }
        let signal = micOrCallAudio() ?? zoomMeetingWindow() ?? browserMeeting

        if let signal {
            lastSignal = Date()
            if !inCall || callApp != signal {
                let started = !inCall
                inCall = true
                callApp = signal
                if started { onChange?(true, signal) }
            }
        } else if inCall, let lastSignal, Date().timeIntervalSince(lastSignal) > endGrace {
            inCall = false
            callApp = nil
            onChange?(false, nil)
        }
    }

    // MARK: 1 + 2. Core Audio: who is using the mic / which call app is outputting audio

    private func micOrCallAudio() -> String? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var micUser: String?
        for process in Self.audioProcesses() where process.pid != ownPID {
            let callName = Self.callApps.first { process.bundleID.hasPrefix($0.prefix) }?.name
            if process.input {
                // A call app, or any other app picking up the mic (browser calls, etc.).
                if let callName { return callName }
                micUser = micUser ?? Self.displayName(for: process)
            }
            if process.output, let callName { return callName }
        }
        return micUser
    }

    private struct AudioProcess {
        let pid: pid_t
        let bundleID: String
        let input: Bool
        let output: Bool
    }

    private static func audioProcesses() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            let pid: Int32 = value(id, kAudioProcessPropertyPID) ?? -1
            let input: UInt32 = value(id, kAudioProcessPropertyIsRunningInput) ?? 0
            let output: UInt32 = value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            guard input != 0 || output != 0 else { return nil }
            return AudioProcess(pid: pid, bundleID: bundleID(id) ?? "", input: input != 0, output: output != 0)
        }
    }

    private static func value<T: FixedWidthInteger>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result: T = 0
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func displayName(for process: AudioProcess) -> String {
        if let app = NSRunningApplication(processIdentifier: process.pid), let name = app.localizedName { return name }
        // Helper processes (e.g. "com.google.Chrome.helper") → the parent app's name.
        let parentID = process.bundleID.components(separatedBy: ".helper").first ?? process.bundleID
        return NSRunningApplication.runningApplications(withBundleIdentifier: parentID).first?.localizedName ?? "a call"
    }

    // MARK: 3. Zoom meeting window (stays while muted)

    private func zoomMeetingWindow() -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows where (window[kCGWindowOwnerName as String] as? String) == "zoom.us" {
            let title = window[kCGWindowName as String] as? String ?? ""
            if title.hasPrefix("Zoom Meeting") || title.hasPrefix("Zoom Webinar") { return "Zoom" }
        }
        return nil
    }

    // MARK: 4. Meeting tabs in browsers (Google Meet releases the mic when you mute)

    private func refreshBrowserMeetingIfDue() {
        guard !browserCheckRunning, Date().timeIntervalSince(lastBrowserCheck) > (inCall ? 10 : 30) else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let browsers = Self.browsers.filter { running.contains($0.bundleID) }
        guard !browsers.isEmpty else { browserMeeting = nil; return }
        browserCheckRunning = true
        lastBrowserCheck = Date()

        DispatchQueue.global(qos: .utility).async {
            var found: String?
            for browser in browsers {
                let urls = runAppleScript("tell application \"\(browser.script)\" to get URL of every tab of every window") ?? ""
                if let meeting = Self.meeting(in: urls) { found = meeting; break }
            }
            DispatchQueue.main.async {
                self.browserMeeting = found
                self.browserCheckRunning = false
            }
        }
    }

    private static func meeting(in urls: String) -> String? {
        // Meet rooms look like meet.google.com/abc-defg-hij
        if urls.range(of: #"meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}"#, options: .regularExpression) != nil {
            return "Google Meet"
        }
        if urls.range(of: #"teams\.(microsoft|live)\.com/[^,]*(meetup-join|meeting|/call)"#, options: .regularExpression) != nil {
            return "Microsoft Teams"
        }
        if urls.range(of: #"zoom\.us/(wc|j)/"#, options: .regularExpression) != nil { return "Zoom" }
        return nil
    }
}
