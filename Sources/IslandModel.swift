import AppKit
import Combine
import SwiftUI

// MARK: - Island state

enum IslandTab: String, CaseIterable {
    case home, timer, shelf, clipboard

    var symbol: String {
        switch self {
        case .home: return "music.note.house.fill"
        case .timer: return "timer"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "list.clipboard.fill"
        }
    }
}

/// Short-lived "live activity" shown under the notch.
enum Peek: Equatable {
    case charging(Bool, Int)
    case track(Track)
    case timerDone
    case meeting(title: String, hasLink: Bool)
    case color(hex: String)
    case keepAwakeEnded
    case textGrabbed(preview: String, lines: Int)
    case noTextFound
    case qrScanned(String)
    case needsScreenAccess
    case callListening(String)
    case build(BuildActivity)
}

/// What the footer caption is describing (native tooltips don't show in a non-activating panel).
enum Hint: Equatable {
    case tab(IslandTab)
    case keepAwake
    case cpu
    case memory
    case action(QuickAction)
}

final class IslandModel: ObservableObject {
    let system = SystemModel()
    let media = MediaModel()
    let timer = TimerModel()
    let clipboard = ClipboardModel()
    let shelf = ShelfModel()
    let calendar = CalendarModel()
    let stats = StatsModel()
    let actions = QuickActionsModel()
    let prompter = PrompterModel()
    let nameAlert = NameAlertModel()
    let builds = BuildModel()

    @Published private(set) var hint: Hint?
    @Published var expanded = false {
        didSet {
            if expanded && !oldValue {
                actions.refreshState()
                Haptics.open()
                // Something is playing → open straight onto the music card.
                if media.track?.isPlaying == true {
                    tab = .home
                    homePanel = nil
                }
            }
            if !expanded { hint = nil }
        }
    }
    /// True for a moment when someone says an alert word: the island flashes purple once.
    @Published private(set) var mentionFlash = false
    @Published var tab: IslandTab = .home
    @Published var homePanel: HomePanel?
    /// Horizontal offset of the music card while you two-finger swipe it (next / previous).
    @Published private(set) var mediaSwipe: CGFloat = 0
    /// Mouse is over the music card (swipes only count there, not over the tab chips).
    var hoveringMediaCard = false
    private var swipeAccumulated: CGFloat = 0
    private var swipeFired = false
    @Published var peek: Peek?
    @Published var dropTargeted = false
    @Published var notchSize = CGSize(width: 180, height: 32)
    /// While a screen tool (color sampler, capture crosshair) is active the island stays out of the way.
    @Published var suppressHover = false
    /// Last QR scanned from the screen (shown in the QR Beam panel instead of the clipboard).
    @Published var qrScanResult: String?

    private var bag: [AnyCancellable] = []
    private var peekToken = 0
    private var hintToken = 0
    private var qrCache: (text: String, image: NSImage?)?

    init() {
        // Any feature changing re-renders the island.
        let children: [ObservableObjectPublisher] = [
            system.objectWillChange, media.objectWillChange, timer.objectWillChange,
            clipboard.objectWillChange, shelf.objectWillChange, calendar.objectWillChange,
            stats.objectWillChange, actions.objectWillChange,
            prompter.objectWillChange, nameAlert.objectWillChange, builds.objectWillChange,
        ]
        for child in children {
            child.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        }

        media.onTrackChange = { [weak self] track in self?.showPeek(.track(track)) }
        system.onPowerChange = { [weak self] charging, level in self?.showPeek(.charging(charging, level)) }
        timer.onFinish = { [weak self] in
            guard let self else { return }
            NSSound(named: "Glass")?.play()
            self.showPeek(.timerDone, duration: 6)
        }
        nameAlert.onMention = { [weak self] mention in
            // One beep + one purple flash of the island. That's it.
            NSSound(named: "Ping")?.play()
            self?.flashPurple()
            if self?.nameAlert.buzzWhenAway == true, AttentionAlert.secondsSinceInput >= self?.nameAlert.awayAfter ?? 15 {
                AttentionAlert.shared.start(saying: "Someone said \(mention.keyword)")
            }
        }
        nameAlert.onCallStarted = { [weak self] app in self?.showPeek(.callListening(app), duration: 3.5) }
        builds.onFinish = { [weak self] activity in
            NSSound(named: activity.succeeded ? "Hero" : "Basso")?.play()
            self?.showPeek(.build(activity), duration: activity.succeeded ? 6 : 12)
        }
        builds.listen()
    }

    // MARK: Hints (footer caption)

    /// Debounced so moving between neighbouring items doesn't make the footer flicker.
    func setHint(_ newHint: Hint?, ifCurrent current: Hint? = nil) {
        hintToken += 1
        if let newHint {
            hint = newHint
            return
        }
        if let current, hint != current { return }
        let token = hintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.hintToken == token { self?.hint = nil }
        }
    }

    func hintIcon(_ hint: Hint) -> String {
        switch hint {
        case .tab(let tab): return tab.symbol
        case .keepAwake: return "cup.and.saucer.fill"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .action(let action):
            switch action {
            case .colorPicker: return "eyedropper.halffull"
            case .darkMode: return "circle.lefthalf.filled"
            case .grabText: return "text.viewfinder"
            case .qrBeam: return "qrcode"
            case .prompter: return "text.aligncenter"
            case .nameAlert: return "person.wave.2.fill"
            }
        }
    }

    func hintText(_ hint: Hint) -> String {
        switch hint {
        case .tab(let tab):
            switch tab {
            case .home: return "Home: media, quick tools and your next meeting."
            case .timer: return "Timer: countdowns that stay visible beside the notch."
            case .shelf: return "Shelf: drop files on the notch, drag them out anywhere later."
            case .clipboard: return "Clipboard: your last 25 copied texts, one click to copy again."
            }
        case .keepAwake:
            if system.keepAwake {
                let until = system.keepAwakeUntil.map { "until \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? "until you turn it off"
                return "Keep Awake is on \(until). Click to let your Mac sleep again."
            }
            return "Keep Awake: stops your Mac and screen from sleeping or locking while idle. Right-click to pick a duration."
        case .cpu:
            return "CPU \(Int(stats.cpu * 100))% busy  ·  ↓ \(formatBytes(stats.downRate))/s  ↑ \(formatBytes(stats.upRate))/s"
        case .memory:
            return "Memory: \(formatBytes(stats.memoryUsed, style: .memory)) of \(formatBytes(stats.memoryTotal, style: .memory)) in use (\(Int(stats.memoryFraction * 100))%)"
        case .action(let action):
            switch action {
            case .colorPicker: return "Click any pixel on screen to copy its hex color."
            case .darkMode: return "Switch macOS between light and dark appearance."
            case .grabText: return "Drag a box over anything on screen to copy its text, or read a QR code."
            case .qrBeam: return "Turn whatever you copied into a QR code, then scan it with your phone."
            case .prompter: return "Teleprompter: your script scrolls right under the camera, so you keep eye contact."
            case .nameAlert: return "Alerts you when someone on a call or video says your name or a keyword."
            }
        }
    }

    // MARK: Sizes

    static let expandedWidth: CGFloat = 460
    static let footerHeight: CGFloat = 40
    static let maxExpandedSize = CGSize(width: expandedWidth, height: 450)

    var expandedSize: CGSize {
        var height: CGFloat
        switch tab {
        case .home:
            // top row + tiles + (panel | event + media + picker) + padding
            height = notchSize.height + 8 + 54 + 16
            if let homePanel {
                height += 12 + homePanel.height
            } else {
                height += 12 + (media.track?.duration ?? 0 > 0 ? 88 : 68)
                if calendar.next != nil { height += 12 + 46 }
                if media.sources.count > 1 { height += 12 + 38 }
                height += CGFloat(min(builds.running.count, 2)) * (12 + 46)
            }
        case .timer: height = timer.isActive ? 172 : 162
        case .shelf: height = 184
        case .clipboard: height = clipboard.items.isEmpty ? 142 : 290
        }
        if hint != nil { height += Self.footerHeight }
        return CGSize(width: Self.expandedWidth, height: min(height, Self.maxExpandedSize.height))
    }

    enum LeftSlot: Equatable { case none, artwork, timerRing, build, listening }
    enum RightSlot: Equatable { case none, countdown, buildElapsed, waveform }

    var leftSlot: LeftSlot {
        if media.track != nil { return .artwork }
        if timer.isActive { return .timerRing }
        if !builds.running.isEmpty { return .build }
        if nameAlert.isListening { return .listening }
        return .none
    }

    var rightSlot: RightSlot {
        if timer.isActive { return .countdown }
        if !builds.running.isEmpty { return .buildElapsed }
        if media.track != nil { return .waveform }
        return .none
    }

    /// Idle: exactly the notch. Grows a little when there is something live to show.
    var collapsedSize: CGSize {
        let extra: CGFloat
        switch (leftSlot, rightSlot) {
        case (.none, .none): extra = 0
        case (_, .countdown), (_, .buildElapsed): extra = 110
        default: extra = 80
        }
        return CGSize(width: notchSize.width + extra, height: notchSize.height)
    }

    var prompterSize: CGSize {
        CGSize(width: PrompterModel.width,
               height: notchSize.height + 6 + PrompterModel.lineHeight * CGFloat(PrompterModel.visibleLines) + 10)
    }

    var peekSize: CGSize {
        CGSize(width: max(notchSize.width + 200, 380), height: notchSize.height + 52)
    }

    var currentSize: CGSize {
        if prompter.isRunning { return prompterSize }
        if expanded { return expandedSize }
        if peek != nil { return peekSize }
        return collapsedSize
    }

    func configure(for screen: NSScreen) {
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width,
                               height: screen.safeAreaInsets.top)
        } else {
            notchSize = CGSize(width: 120, height: 30)
        }
    }

    // MARK: Quick actions

    func perform(_ action: QuickAction) {
        switch action {
        case .colorPicker:
            suppressHover = true
            actions.pickColor { [weak self] hex in
                self?.suppressHover = false
                if let hex { self?.showPeek(.color(hex: hex), duration: 3) }
            }
        case .darkMode:
            actions.toggleDarkMode()
        case .grabText:
            grabText()
        case .qrBeam:
            togglePanel(.qr)
        case .prompter:
            togglePanel(.prompter)
        case .nameAlert:
            togglePanel(.nameAlert)
        }
    }

    func isOn(_ action: QuickAction) -> Bool {
        switch action {
        case .darkMode: return actions.darkMode
        case .qrBeam: return homePanel == .qr
        case .prompter: return homePanel == .prompter
        case .nameAlert: return homePanel == .nameAlert || nameAlert.isListening
        default: return false
        }
    }

    func togglePanel(_ panel: HomePanel) {
        homePanel = homePanel == panel ? nil : panel
    }

    /// Only called after a capture actually fails. (CGPreflightScreenCaptureAccess can report false
    /// even when ScreenCaptureKit is allowed, so it must not gate captures.)
    private func requestScreenAccess() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        showPeek(.needsScreenAccess, duration: 8)
    }

    private func grabText() {
        suppressHover = true
        ScreenTools.captureRegion { [weak self] image in
            guard let self else { return }
            self.suppressHover = false
            guard let image else {
                if ScreenTools.lastCaptureFailed { self.requestScreenAccess() }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let text = ScreenTools.recognizeText(in: image)
                let qr = text.isEmpty ? ScreenTools.detectQR(in: image) : nil
                DispatchQueue.main.async {
                    if !text.isEmpty {
                        self.clipboard.copy(text)
                        let lines = text.components(separatedBy: "\n")
                        self.showPeek(.textGrabbed(preview: lines.first ?? text, lines: lines.count), duration: 3)
                    } else if let qr {
                        self.receiveScannedQR(qr)
                    } else {
                        self.showPeek(.noTextFound, duration: 4)
                    }
                }
            }
        }
    }

    private func receiveScannedQR(_ payload: String) {
        clipboard.copy(payload)
        qrScanResult = payload
        homePanel = .qr
        tab = .home
        showPeek(.qrScanned(payload), duration: 4)
    }

    /// Cached so the QR isn't regenerated on every clock tick.
    func qrImage(for text: String) -> NSImage? {
        if let qrCache, qrCache.text == text { return qrCache.image }
        let image = text.utf8.count <= 2000 ? ScreenTools.qrImage(for: text) : nil
        qrCache = (text, image)
        return image
    }

    // MARK: Swipe the music card

    /// Two-finger swipe on the music card: left = next, right = previous.
    func handleScroll(_ event: NSEvent) {
        guard expanded, tab == .home, homePanel == nil, hoveringMediaCard,
              let track = media.track, track.canControl, event.momentumPhase.isEmpty else { return }
        if event.phase == .began {
            swipeAccumulated = 0
            swipeFired = false
        }
        // Normalize to finger direction regardless of the "natural scrolling" setting.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeAccumulated != 0 {
            swipeAccumulated += dx
            // Rubber-band feel: follows the fingers, with resistance.
            mediaSwipe = swipeAccumulated / (1 + abs(swipeAccumulated) / 120)
            if !swipeFired && abs(swipeAccumulated) > 70 {
                swipeFired = true
                Haptics.tap()
                media.send(swipeAccumulated < 0 ? .next : .previous)
            }
        }
        if event.phase == .ended || event.phase == .cancelled {
            swipeAccumulated = 0
            mediaSwipe = 0
        }
    }

    // MARK: Live activities

    func flashPurple(duration: TimeInterval = 0.7) {
        mentionFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.mentionFlash = false }
    }

    func showPeek(_ peek: Peek, duration: TimeInterval = 3.5) {
        guard !expanded, !prompter.isRunning else { return }
        peekToken += 1
        let token = peekToken
        self.peek = peek
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.peekToken == token { self?.peek = nil }
        }
    }

    /// Runs once a second.
    func tick() {
        let now = Date()
        // Publishing `now` redraws the island, so only do it when something visible uses the time.
        if expanded || peek != nil || prompter.isRunning || timer.isActive || !builds.running.isEmpty {
            system.now = now
        }
        timer.check(now)
        builds.pruneDead()
        nameAlert.tick()
        if system.keepAwake, let until = system.keepAwakeUntil, now >= until {
            system.checkKeepAwakeExpiry(now)
            showPeek(.keepAwakeEnded)
        }
        if let event = calendar.eventToAnnounce(at: now) {
            showPeek(.meeting(title: event.title ?? "Event",
                              hasLink: CalendarModel.meetingURL(for: event) != nil),
                     duration: 10)
        }
    }
}
