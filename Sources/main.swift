import AppKit
import SwiftUI

// MARK: - Window

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    var panel: IslandPanel!
    var screen: NSScreen = NSScreen.screens[0]
    var timers: [Timer] = []
    private var hoverChangedAt: Date?
    private var mediaTicks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = FirstMouseHostingView(rootView: IslandView(model: model))

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.layout() }

        model.system.start()
        model.calendar.start()
        model.availability.refresh(force: true)
        model.media.refresh()

        // Hover is event-driven (no 33 Hz polling): react to mouse movement, plus a slow safety net.
        panel.acceptsMouseMovedEvents = true
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] _ in
            self?.checkHover()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.checkHover()
            return event
        }
        schedule(0.5) { [weak self] in self?.checkHover() }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.model.handleScroll(event)
            return event
        }
        schedule(1) { [weak self] in
            self?.model.clipboard.poll()
            self?.model.tick()
        }
        // What's playing: every 1.5 s while open, every 4.5 s while closed; Music/Spotify also push changes instantly.
        schedule(1.5) { [weak self] in
            guard let self else { return }
            self.mediaTicks += 1
            if self.model.expanded || self.mediaTicks % 3 == 0 { self.model.media.refresh() }
        }
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                self?.model.media.refresh()
            }
        }
        // CPU/memory rings are only visible while the island is open.
        schedule(2) { [weak self] in
            if self?.model.expanded == true { self?.model.stats.refresh() }
        }
        model.stats.refresh()

        model.nameAlert.applyMode()

        schedule(30) { [weak self] in
            self?.model.system.refreshBattery()
            self?.model.calendar.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.system.keepAwake = false
    }

    private func schedule(_ interval: TimeInterval, _ block: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    /// Prefer the built-in (notched) display; fall back to the menu-bar screen.
    private func layout() {
        screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens[0]
        model.configure(for: screen)
        let max = IslandModel.maxExpandedSize
        let size = CGSize(width: Swift.max(max.width, PrompterModel.width) + 80, height: max.height + 50)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// Expand only while hovering (short delays avoid flicker when passing by); clicks pass through otherwise.
    private func checkHover() {
        if model.suppressHover {
            if model.expanded { model.expanded = false }
            panel.ignoresMouseEvents = true
            hoverChangedAt = nil
            return
        }
        // While the teleprompter runs it stays open by itself; hovering only reveals its controls.
        if model.prompter.isRunning {
            if model.expanded { model.expanded = false }
            let size = model.prompterSize
            let rect = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height + 2)
            let inside = rect.contains(NSEvent.mouseLocation)
            panel.ignoresMouseEvents = !inside
            if model.prompter.hovering != inside { model.prompter.hovering = inside }
            return
        }
        let size = model.currentSize
        var rect = NSRect(x: screen.frame.midX - size.width / 2 + model.islandOffsetX,
                          y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height + 2)
        if model.expanded { rect = rect.insetBy(dx: -10, dy: -10) }
        var inside = rect.contains(NSEvent.mouseLocation)
        // Don't collapse mid-drag (dragging a file out of the shelf, scrubbing the progress bar).
        if model.expanded && NSEvent.pressedMouseButtons & 1 != 0 { inside = true }
        panel.ignoresMouseEvents = !inside

        guard inside != model.expanded else { hoverChangedAt = nil; return }
        let now = Date()
        if hoverChangedAt == nil { hoverChangedAt = now }
        let delay = inside ? 0.12 : 0.25
        if now.timeIntervalSince(hoverChangedAt!) < delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in self?.checkHover() }
        }
        if now.timeIntervalSince(hoverChangedAt!) >= delay {
            model.expanded = inside
            if inside { model.peek = nil }
            hoverChangedAt = nil
        }
    }
}

// CLI mode, used by the `notch` command: post a build event to the running island and exit.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--notify" {
    BuildNotifier.post(Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
