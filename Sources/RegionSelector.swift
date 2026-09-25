import AppKit

/// Full-screen "drag a box" overlay. Returns the selection in global Cocoa screen coordinates, or nil if cancelled.
final class RegionSelector {
    private static var current: RegionSelector?

    private var windows: [NSWindow] = []
    private let completion: (CGRect?) -> Void
    private let previousApp = NSWorkspace.shared.frontmostApplication

    static func select(completion: @escaping (CGRect?) -> Void) {
        current?.finish(nil)
        let selector = RegionSelector(completion: completion)
        current = selector
        selector.show()
    }

    private init(completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
    }

    private func show() {
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: false)
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self, weak window] local in
                guard let local, let window else { self?.finish(nil); return }
                self?.finish(window.convertToScreen(local))
            }
            window.contentView = view
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate()
        let mouseScreenWindow = windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first
        mouseScreenWindow?.makeKeyAndOrderFront(nil)
        mouseScreenWindow?.makeFirstResponder(mouseScreenWindow?.contentView)
    }

    private func finish(_ rect: CGRect?) {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        previousApp?.activate()
        Self.current = nil
        // Give the overlay a moment to leave the screen before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.completion(rect) }
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var onFinish: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: NSRect? {
        guard let start, let current else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(roundedRect: selection.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            border.lineWidth = 1.5
            border.stroke()
        } else {
            let text = "Drag over the text or QR code  ·  Esc to cancel" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            let pill = NSRect(x: bounds.midX - size.width / 2 - 18, y: bounds.midY - size.height / 2 - 10,
                              width: size.width + 36, height: size.height + 20)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 10), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        if let selection, selection.width > 4, selection.height > 4 {
            onFinish?(selection)
        } else {
            onFinish?(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }  // Esc
    }
}
