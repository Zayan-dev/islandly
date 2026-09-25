import AppKit
import EventKit
import IOKit.ps
import IOKit.pwr_mgt
import UniformTypeIdentifiers

// MARK: - Clock, battery, keep-awake

final class SystemModel: ObservableObject {
    @Published var now = Date()
    @Published private(set) var hasBattery = false
    @Published private(set) var batteryLevel = 100
    @Published private(set) var isCharging = false
    @Published var keepAwake = false {
        didSet {
            if !keepAwake { keepAwakeUntil = nil }
            applyKeepAwake()
        }
    }
    /// nil while on = until turned off.
    @Published private(set) var keepAwakeUntil: Date?

    func keepAwake(for duration: TimeInterval?) {
        keepAwake = true
        keepAwakeUntil = duration.map { Date().addingTimeInterval($0) }
    }

    func checkKeepAwakeExpiry(_ now: Date) {
        if let keepAwakeUntil, now >= keepAwakeUntil { keepAwake = false }
    }

    /// Fired when the charger is plugged in / unplugged.
    var onPowerChange: ((_ charging: Bool, _ level: Int) -> Void)?

    private var assertionID: IOPMAssertionID = 0
    private var powerSource: CFRunLoopSource?
    private var loadedOnce = false

    func start() {
        refreshBattery()
        // Instant callback on power changes instead of waiting for a poll.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<SystemModel>.fromOpaque(ctx).takeUnretainedValue().refreshBattery()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    func refreshBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            hasBattery = false
            return
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if let cap = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                batteryLevel = cap * 100 / max
            }
            let charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if loadedOnce && charging != isCharging { onPowerChange?(charging, batteryLevel) }
            isCharging = charging
            hasBattery = true
            loadedOnce = true
            return
        }
        hasBattery = false
    }

    private func applyKeepAwake() {
        if keepAwake, assertionID == 0 {
            // Blocks idle display sleep, which also blocks idle system sleep and the idle screen lock.
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Islandly: keep awake" as CFString,
                                        &assertionID)
        } else if !keepAwake, assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }
}

// MARK: - Timer

final class TimerModel: ObservableObject {
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var total: TimeInterval = 0

    var onFinish: (() -> Void)?

    var isActive: Bool { endDate != nil || pausedRemaining != nil }
    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return 0
    }

    func start(seconds: TimeInterval) {
        total = seconds
        endDate = Date().addingTimeInterval(seconds)
        pausedRemaining = nil
    }

    func togglePause() {
        if let pausedRemaining {
            endDate = Date().addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
        } else if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
        }
    }

    func add(_ seconds: TimeInterval) {
        if let pausedRemaining { self.pausedRemaining = pausedRemaining + seconds }
        if let endDate { self.endDate = endDate.addingTimeInterval(seconds) }
        total += seconds
    }

    func cancel() {
        endDate = nil
        pausedRemaining = nil
    }

    func check(_ now: Date) {
        if let endDate, now >= endDate {
            self.endDate = nil
            onFinish?()
        }
    }
}

func formatCountdown(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Clipboard history (text only, in memory, skips password-manager items)

final class ClipboardModel: ObservableObject {
    @Published private(set) var items: [String] = []

    private let pasteboard = NSPasteboard.general
    private var lastChange = NSPasteboard.general.changeCount
    private static let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
    ]
    private let limit = 25

    func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.ignoredTypes),
              let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChange = pasteboard.changeCount
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
    }

    func remove(_ text: String) { items.removeAll { $0 == text } }
    func clear() { items.removeAll() }
}

// MARK: - File shelf (keeps references, not copies; survives relaunch)

final class ShelfModel: ObservableObject {
    @Published private(set) var files: [URL] = [] {
        didSet { UserDefaults.standard.set(files.map(\.path), forKey: Self.key) }
    }
    private static let key = "shelfFiles"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        files = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        guard !files.contains(url) else { return }
        files.append(url)
    }

    func add(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { self.add(url) }
            }
        }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clear() { files.removeAll() }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func airDrop() {
        guard !files.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()
        service.perform(withItems: files)
    }
}

// MARK: - Calendar: next event + meeting link

final class CalendarModel: ObservableObject {
    @Published private(set) var next: EKEvent?
    @Published private(set) var authorized = false

    private let store = EKEventStore()
    private var announced = Set<String>()

    func start() {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async {
                self.authorized = granted
                self.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                               queue: .main) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard authorized else { next = nil; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 3600),
                                                 end: now.addingTimeInterval(24 * 3600), calendars: nil)
        next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .first
    }

    /// Returns the next event once, ~1 minute before it starts (drives the meeting pop-up).
    func eventToAnnounce(at now: Date) -> EKEvent? {
        if let next, next.endDate <= now { refresh() }
        guard let event = next, let id = event.eventIdentifier else { return nil }
        let untilStart = event.startDate.timeIntervalSince(now)
        guard untilStart <= 60, untilStart > -30, !announced.contains(id) else { return nil }
        announced.insert(id)
        return event
    }

    /// Only real meeting domains over HTTPS — calendar invites can come from anyone, so a link that merely
    /// *mentions* "zoom.us" (e.g. https://evil.example/zoom.us) must not get a Join button.
    static func isMeetingLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        let domains = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com", "around.co", "chime.aws"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func meetingURL(for event: EKEvent) -> URL? {
        let texts = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url, isMeetingLink(url) { return url }
            }
        }
        return nil
    }

    static func relativeTime(for event: EKEvent, now: Date) -> String {
        if event.startDate <= now {
            return "Now · until \(event.endDate.formatted(date: .omitted, time: .shortened))"
        }
        let minutes = Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        if !Calendar.current.isDateInToday(event.startDate) {
            return "Tomorrow \(event.startDate.formatted(date: .omitted, time: .shortened))"
        }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }
}
