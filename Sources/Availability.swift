import AppKit
import CoreServices
import Speech

/// Whether a quick action can run on this Mac right now.
enum FeatureStatus: Equatable {
    case ready
    /// Fixable by the user (a permission or setting); `pane` opens the right System Settings page.
    case needsSetup(reason: String, pane: String)
    /// This Mac can't run it; tapping only explains why.
    case unsupported(reason: String)
}

/// Checks what each feature depends on. Runs at launch and when the island opens (throttled),
/// never on a timer, so it costs no battery while idle.
final class AvailabilityModel: ObservableObject {
    @Published private(set) var speechOnDevice = true
    @Published private(set) var speechLocaleSupported = true
    @Published private(set) var speechAuth = SFSpeechRecognizer.authorizationStatus()
    @Published private(set) var automationDenied = false
    /// Set when a capture actually failed; cleared by a successful one.
    /// (CGPreflightScreenCaptureAccess can say false while access works, so it can only *clear* this.)
    @Published var screenCaptureBlocked: Bool {
        didSet { UserDefaults.standard.set(screenCaptureBlocked, forKey: Self.captureKey) }
    }

    private static let captureKey = "screenCaptureBlocked"
    private var lastRefresh = Date.distantPast

    init() {
        screenCaptureBlocked = UserDefaults.standard.bool(forKey: Self.captureKey)
    }

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRefresh) > 10 else { return }
        lastRefresh = Date()

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        speechLocaleSupported = recognizer != nil
        speechOnDevice = recognizer?.supportsOnDeviceRecognition ?? false
        speechAuth = SFSpeechRecognizer.authorizationStatus()
        if screenCaptureBlocked && CGPreflightScreenCaptureAccess() { screenCaptureBlocked = false }

        // Asks TCC without prompting; can block briefly, so off the main thread.
        DispatchQueue.global(qos: .utility).async {
            let denied = Self.automationDenied(bundleID: "com.apple.systemevents")
            DispatchQueue.main.async { self.automationDenied = denied }
        }
    }

    func status(for action: QuickAction) -> FeatureStatus {
        switch action {
        case .grabText where screenCaptureBlocked:
            return .needsSetup(reason: "Grab Text needs Screen Recording. Click to allow it, then restart Islandly.",
                               pane: "Privacy_ScreenCapture")
        case .darkMode where automationDenied:
            return .needsSetup(reason: "Dark Mode needs Automation access. Click, then allow System Events for Islandly.",
                               pane: "Privacy_Automation")
        case .nameAlert:
            if !speechLocaleSupported || speechAuth == .restricted {
                return .unsupported(reason: "Not supported on this Mac: speech recognition is unavailable or restricted here.")
            }
            if !speechOnDevice {
                return .unsupported(reason: "Not supported on this Mac: it lacks on-device speech, and audio never leaves your Mac.")
            }
            if speechAuth == .denied {
                return .needsSetup(reason: "Name Alert needs Speech Recognition. Click to allow it for Islandly.",
                                   pane: "Privacy_SpeechRecognition")
            }
            return .ready
        default:
            return .ready
        }
    }

    static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Only an explicit "denied" counts: not-yet-asked or System Events not running are fine (macOS prompts on first use).
    private static func automationDenied(bundleID: String) -> Bool {
        var target = AEAddressDesc()
        let status: OSStatus = bundleID.withCString { ptr in
            guard AECreateDesc(DescType(typeApplicationBundleID), ptr, strlen(ptr), &target) == noErr else { return OSStatus(noErr) }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        }
        return status == OSStatus(errAEEventNotPermitted)
    }
}
