import AppKit
import Combine
import SwiftUI

// MARK: - Island state

enum IslandTab: String, CaseIterable {
    case home, dev, timer, world, shelf, clipboard

    var symbol: String {
        switch self {
        case .home: return "music.note.house.fill"
        case .timer: return "timer"
        case .world: return "globe"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "list.clipboard.fill"
        case .dev: return "server.rack"
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
    case phoneReceived(name: String, isText: Bool)
    case signature
    case update(count: Int)
    case agentDone(agent: String, source: String, project: String, detail: String)
    case agentWaiting(agent: String, source: String, project: String, message: String)
    case ci(CIRun)
    case ciStarted(CIRun)
    case lid(LidPeek)
    case time(TimeConversion)
}

/// What the footer caption is describing (native tooltips don't show in a non-activating panel).
enum Hint: Equatable {
    case tab(IslandTab)
    case keepAwake
    case cpu
    case memory
    case action(QuickAction)
    case update
}

final class IslandModel: ObservableObject {
    // First: it checks whether this is a fresh install before anything else saves a setting.
    let whatsNew = WhatsNewModel()
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
    let availability = AvailabilityModel()
    let devServers = DevServerModel()
    let receiver = PhoneReceiver()
    let updates = UpdateModel()
    let agents = AgentHub()
    let ask = AskModel()
    let ci = GitHubCI()
    let worldClock = WorldClockModel()
    let lid = LidModel()

    @Published private(set) var hint: Hint?
    @Published var expanded = false {
        didSet {
            if expanded && !oldValue {
                actions.refreshState()
                availability.refresh()
                Haptics.open()
                // Something is playing → open straight onto the music card.
                // (Unless the phone is mid-transfer: keep that panel.)
                if media.track?.isPlaying == true, !receiver.isRunning {
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
    @Published var homePanel: HomePanel? { didSet { syncPhone() } }
    /// Send / Receive inside the Phone panel.
    @Published var phoneMode: PhoneMode = .send { didSet { syncPhone() } }
    /// Horizontal offset of the music card while you two-finger swipe it (next / previous).
    @Published private(set) var mediaSwipe: CGFloat = 0
    /// Mouse is over the music card (swipes only count there, not over the tab chips).
    var hoveringMediaCard = false
    private var swipeAccumulated: CGFloat = 0
    private var swipeFired = false
    @Published var peek: Peek?
    @Published var dropTargeted = false
    /// The island's springy "stretch" (lid opened, opened all the way).
    @Published var stretching = false
    @Published var notchSize = CGSize(width: 180, height: 32)
    /// Keep every Islandly window out of screen sharing, screenshots and recordings (on by default).
    @Published var hiddenFromScreenShare = UserDefaults.standard.object(forKey: "hideFromScreenShare") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hiddenFromScreenShare, forKey: "hideFromScreenShare") }
    }
    /// While a screen tool (color sampler, capture crosshair) is active the island stays out of the way.
    @Published var suppressHover = false
    /// Last QR scanned from the screen (shown in the QR Beam panel instead of the clipboard).
    @Published var qrScanResult: String?
    /// Dev server picked in QR Beam (its network URL becomes the code).
    @Published var qrServerID: String?

    private var bag: [AnyCancellable] = []
    private var peekToken = 0
    private var hintToken = 0
    private var qrCache: (text: String, image: NSImage?)?

    init() {
        // Any feature changing re-renders the island.
        let children: [ObservableObjectPublisher] = [
            system.objectWillChange, media.objectWillChange, timer.objectWillChange,
            clipboard.objectWillChange, shelf.objectWillChange, calendar.objectWillChange,
            stats.objectWillChange, actions.objectWillChange, availability.objectWillChange, devServers.objectWillChange, receiver.objectWillChange,
            prompter.objectWillChange, nameAlert.objectWillChange, builds.objectWillChange, updates.objectWillChange, agents.objectWillChange, whatsNew.objectWillChange, ask.objectWillChange, ci.objectWillChange, worldClock.objectWillChange,
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
        receiver.onFile = { [weak self] url in
            self?.shelf.add(url)
            self?.showPeek(.phoneReceived(name: url.lastPathComponent, isText: false), duration: 4)
        }
        receiver.onSignature = { [weak self] url in
            self?.shelf.add(url)
            self?.showPeek(.signature, duration: 4)
        }
        receiver.onText = { [weak self] text in
            // Not copied automatically: it waits in Phone ▸ Receive until you choose Copy.
            self?.showPeek(.phoneReceived(name: text, isText: true), duration: 4)
        }
        nameAlert.onCallStarted = { [weak self] app in
            // Don't claim to be listening on a Mac that can't transcribe.
            guard let self, self.availability.status(for: .nameAlert) == .ready else { return }
            self.showPeek(.callListening(app), duration: 3.5)
        }
        builds.onFinish = { [weak self] activity in
            NSSound(named: activity.succeeded ? "Hero" : "Basso")?.play()
            self?.showPeek(.build(activity), duration: activity.succeeded ? 6 : 12)
        }
        builds.listen()
        agents.onRequest = { NSSound(named: "Submarine")?.play() }
        agents.onFinished = { [weak self] session, summary in
            NSSound(named: "Pop")?.play()
            let took = formatDuration(max(0, Date().timeIntervalSince(session.startedAt)))
            self?.showPeek(.agentDone(agent: session.agentName, source: session.source, project: session.project,
                                      detail: summary ?? "Done in \(took)"), duration: 6)
        }
        agents.onWaiting = { [weak self] session, message in
            self?.showPeek(.agentWaiting(agent: session.agentName, source: session.source, project: session.project,
                                         message: message), duration: 8)
        }
        updates.onResult = { [weak self] count in self?.showPeek(.update(count: count), duration: 3) }
        clipboard.onText = { [weak self] text in
            guard let self, let conversion = TimeConversion.parse(text, clocks: self.worldClock.zones) else { return }
            self.showPeek(.time(conversion), duration: 8)
        }
        ci.onStart = { [weak self] run in self?.showPeek(.ciStarted(run), duration: 3) }
        ci.onFinish = { [weak self] run in
            NSSound(named: run.succeeded ? "Hero" : "Basso")?.play()
            self?.showPeek(.ci(run), duration: run.succeeded ? 6 : 12)
        }
        lid.isPlaying = { [weak self] in self?.media.track?.isPlaying == true }
        lid.onPeek = { [weak self] peek in
            guard let self else { return }
            switch peek {
            case .welcome:
                self.stretch()
                self.showPeek(.lid(peek), duration: 3)
            case .maxOpen:
                self.stretch()
                Haptics.tap()
                self.showPeek(.lid(peek), duration: 2.5)
            case .angle, .volume:
                self.showPeek(.lid(peek), duration: 1.4)
            }
        }
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
        case .update: return "arrow.down.circle.fill"
        case .action(let action):
            switch availability.status(for: action) {
            case .needsSetup: return "exclamationmark.triangle.fill"
            case .unsupported: return "lock.fill"
            case .ready: break
            }
            switch action {
            case .colorPicker: return "eyedropper.halffull"
            case .darkMode: return "circle.lefthalf.filled"
            case .grabText: return "text.viewfinder"
            case .qrBeam: return "iphone.gen3.radiowaves.left.and.right"
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
            case .world: return "World Clock: your time and the cities you work with. Drag the slider to plan."
            case .dev: return "Dev: servers running on this Mac. Open one in the browser or on your phone, or stop a stuck one."
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
        case .update:
            switch updates.state {
            case .available(let count, let changes):
                let what = changes.first.map { ": \($0)\(count > 1 ? " and more" : "")" } ?? ""
                return "Update available (\(count) change\(count == 1 ? "" : "s")\(what)). Click to update; Islandly restarts by itself."
            case .updating(let step): return step
            case .failed(let message): return "Update failed: \(message) Click to try again."
            case .upToDate: return "Islandly is up to date."
            case .checking: return "Checking for updates…"
            case .idle: return updates.versionLabel
            }
        case .action(let action):
            switch availability.status(for: action) {
            case .needsSetup(let reason, _), .unsupported(let reason): return reason
            case .ready: break
            }
            switch action {
            case .colorPicker: return "Click any pixel on screen to copy its hex color."
            case .darkMode: return "Switch macOS between light and dark appearance."
            case .grabText: return "Drag a box over anything on screen to copy its text, or read a QR code."
            case .qrBeam: return "Phone: send links and dev servers to it, or receive photos, files and text from it."
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
                height += CGFloat(min(agents.working.count, 2)) * (12 + 46)
                height += CGFloat(min(ci.running.count, 2)) * (12 + 46)
            }
        case .timer: height = timer.isActive ? 172 : 162
        case .shelf: height = 184
        case .clipboard: height = clipboard.items.isEmpty ? 142 : 290
        case .world: height = notchSize.height + 8 + 52 + 8 + 24 + 8 + CGFloat(min(max(worldClock.zones.count, 1), 5)) * 44 + 8 + 24 + 16
        case .dev:
            if devServers.phone != nil {
                height = notchSize.height + 8 + 22 + 8 + 122 + 16
            } else {
                height = devServers.servers.isEmpty ? 142 : notchSize.height + 8 + 26 + CGFloat(min(devServers.servers.count, 5)) * 48 + 16
            }
        }
        if hint != nil { height += Self.footerHeight }
        return CGSize(width: Self.expandedWidth, height: min(height, Self.maxExpandedSize.height))
    }

    /// What the closed island shows while something is live. It stays exactly the notch; indicators peek out
    /// just past its edges (the notch itself is the camera cutout, so it can't show anything):
    /// the song's thumbnail on the left, the green wave (or the phone icon while Receive is open) on the right.
    enum ClosedIndicator: Equatable { case wave, receiving, agent(waiting: Bool), ci(Double) }
    static let indicatorPeek: CGFloat = 30

    var closedIndicator: ClosedIndicator? {
        if receiver.isRunning { return .receiving }  // an open port should never be invisible
        if agents.working.contains(where: { $0.state == .waiting }) { return .agent(waiting: true) }
        if let run = ci.running.first { return .ci(run.progress) }
        if media.track?.isPlaying == true { return .wave }
        if !agents.working.isEmpty { return .agent(waiting: false) }
        return nil
    }

    /// Thumbnail tab on the left while something plays.
    var showsClosedArtwork: Bool { media.track?.isPlaying == true }

    var collapsedSize: CGSize {
        let tabs = CGFloat((showsClosedArtwork ? 1 : 0) + (closedIndicator != nil ? 1 : 0))
        return CGSize(width: notchSize.width + tabs * Self.indicatorPeek, height: notchSize.height)
    }

    /// Keeps the notch-covered part centred on the notch when only one side has a tab.
    var islandOffsetX: CGFloat {
        guard !expanded, peek == nil, !prompter.isRunning, card == nil else { return 0 }
        let right: CGFloat = closedIndicator != nil ? Self.indicatorPeek : 0
        let left: CGFloat = showsClosedArtwork ? Self.indicatorPeek : 0
        return (right - left) / 2
    }

    var prompterSize: CGSize {
        CGSize(width: PrompterModel.width,
               height: notchSize.height + 6 + PrompterModel.lineHeight * CGFloat(PrompterModel.visibleLines) + 10)
    }

    var peekSize: CGSize {
        CGSize(width: max(notchSize.width + 200, 380), height: notchSize.height + 52)
    }

    /// A card the island shows by itself until it's answered: an agent's permission request first, then an
    /// update that's ready, then (once) what's new and new features to switch on.
    var card: NotchCard? {
        if let request = agents.pending { return .agent(request.id) }
        if ci.setup != nil { return .ciSetup }
        if updates.offer { return .update }
        if !whatsNew.unseenNotes.isEmpty { return .whatsNew }
        if let offer = whatsNew.nextFeature(applies: featureApplies) { return .feature(offer.id) }
        return nil
    }

    var cardSize: CGSize {
        switch card {
        case .agent: return CGSize(width: 440, height: notchSize.height + 160)
        default: return CGSize(width: 400, height: notchSize.height + 106)   // icon row + footer row
        }
    }

    private func featureApplies(_ offer: FeatureOffer) -> Bool {
        switch offer.id {
        case "claude-agent": return AgentHooks.claudeFound && !agents.claudeConnected
        // Also offered to people on the old notify-only connection, to move them to full hooks.
        case "codex-agent": return AgentHooks.codexFound && !AgentHooks.codexUpToDate
        case "ask-ai": return !ask.enabled && !ask.available.isEmpty
        // Developers only (they use git), and only when CI can't already show.
        case "github-ci": return ci.enabled && ci.wantsSetup
            && FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.gitconfig")
        default: return true
        }
    }

    func acceptFeature(_ offer: FeatureOffer) {
        switch offer.id {
        case "claude-agent": agents.setClaude(true)   // the card itself is the consent
        case "codex-agent": agents.setCodex(true)
        case "ask-ai": ask.turnOn()
        case "github-ci": ci.startSetup()
        default: break
        }
    }

    var currentSize: CGSize {
        if prompter.isRunning { return prompterSize }
        if card != nil { return cardSize }
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
        switch availability.status(for: action) {
        case .unsupported:
            return  // the footer caption already explains why
        case .needsSetup(_, let pane) where action != .grabText:
            // Grab Text still tries: the capture itself is the only reliable permission check.
            AvailabilityModel.openSettings(pane)
            return
        default:
            break
        }
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
        case .qrBeam: return homePanel == .qr || receiver.isRunning
        case .prompter: return homePanel == .prompter
        case .nameAlert: return homePanel == .nameAlert || nameAlert.isListening
        default: return false
        }
    }

    func togglePanel(_ panel: HomePanel) {
        homePanel = homePanel == panel ? nil : panel
    }

    /// The receiver runs only while Receive is showing.
    private func syncPhone() {
        if homePanel == .qr && phoneMode != .send {
            receiver.page = phoneMode == .sign ? .sign : .upload
            receiver.start()
        } else if receiver.isRunning {
            receiver.stop()
        }
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
                if ScreenTools.lastCaptureFailed {
                    self.availability.screenCaptureBlocked = true
                    self.requestScreenAccess()
                }
                return
            }
            self.availability.screenCaptureBlocked = false
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
        qrServerID = nil
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

    func stretch() {
        stretching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.stretching = false }
    }

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
        if expanded || peek != nil || prompter.isRunning || timer.isActive || !builds.running.isEmpty || !agents.working.isEmpty || !ci.running.isEmpty {
            system.now = now
        }
        timer.check(now)
        builds.pruneDead()
        ci.tick(now)
        agents.prune(now)
        // Dev servers are only scanned while that tab is on screen.
        if expanded && (tab == .dev || (tab == .home && homePanel == .qr && phoneMode == .send)) && Int(now.timeIntervalSince1970) % 3 == 0 {
            devServers.refresh()
        }
        nameAlert.tick()
        updates.tick(now)
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
