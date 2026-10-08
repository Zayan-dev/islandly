import AppKit
import IOKit.hid
import SwiftUI

// Lid-angle easter eggs. Recent MacBooks have a hinge sensor (an HID device, readable without any permission):
//   • open the lid → the notch stretches awake and says hi
//   • tilt the screen → a live protractor shows the angle
//   • open it all the way → "that's as far as it goes"
//   • music playing? closing the lid fades the volume down; opening it brings it back

enum LidPeek: Equatable {
    case angle(Int)
    case welcome
    case maxOpen(Int)
    case volume(Int)
}

final class LidModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "lidEasterEggs")
            enabled ? start() : stop()
        }
    }
    /// Not published: the island only redraws for the peeks, not for every reading.
    private(set) var angle: Int?

    var onPeek: ((LidPeek) -> Void)?
    var isPlaying: () -> Bool = { false }

    static let available: Bool = LidSensor() != nil

    private var sensor: LidSensor?
    private var timer: Timer?
    private var history: [(time: Date, angle: Int)] = []
    private var lastMove = Date.distantPast
    private var moveStart: Int?
    private var lastWelcome = Date.distantPast
    private var lastMaxOpen = Date.distantPast
    /// The volume before closing the lid turned it down, restored when it opens again.
    private var savedVolume: Int?
    private var appliedVolume: Int?
    private var readingVolume = false
    private let volumeQueue = DispatchQueue(label: "app.islandly.lid-volume")

    static let fadeStart = 55      // below this angle the music fades…
    static let fadeEnd = 15        // …down to silence here
    static let maxOpen = 128

    init() {
        enabled = UserDefaults.standard.object(forKey: "lidEasterEggs") as? Bool ?? true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.enabled else { return }
            self.sensor = nil   // reopen the device after sleep
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self.welcome() }
        }
        if enabled { start() }
    }

    private func start() {
        guard timer == nil else { return }
        schedule(fast: false)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        restoreVolume()
        angle = nil
    }

    /// 4 Hz while the lid is still, 15 Hz while it moves.
    private func schedule(fast: Bool) {
        timer?.invalidate()
        let t = Timer(timeInterval: fast ? 1.0 / 15 : 0.25, repeats: true) { [weak self] _ in self?.sample() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        isFast = fast
    }
    private var isFast = false

    private func sample() {
        if sensor == nil { sensor = LidSensor() }
        guard let value = sensor?.angle() else { sensor = nil; return }
        let now = Date()
        let previous = angle
        angle = value
        history.append((now, value))
        history.removeAll { now.timeIntervalSince($0.time) > 4 }

        let moving = previous.map { abs($0 - value) >= 1 } ?? false
        if moving {
            lastMove = now
            if moveStart == nil { moveStart = previous }
        }
        let still = now.timeIntervalSince(lastMove) > 1.5
        if still { moveStart = nil }
        if moving != isFast && (moving || now.timeIntervalSince(lastMove) > 3) { schedule(fast: moving) }

        // Opened from nearly shut.
        if value > 70, let lowest = history.map(\.angle).min(), lowest < 30 { welcome() }

        // All the way open, while opening.
        if value >= Self.maxOpen, let start = moveStart, value - start >= 12,
           now.timeIntervalSince(lastMaxOpen) > 20 {
            lastMaxOpen = now
            onPeek?(.maxOpen(value))
            return
        }

        // Music fades as the lid closes.
        if isPlaying() && value < Self.fadeStart {
            fadeVolume(for: value)
            return
        }
        if savedVolume != nil { restoreVolume() }

        // Live protractor while you tilt it (a real move, not a nudge).
        if moving, let start = moveStart, abs(value - start) >= 8 {
            onPeek?(.angle(value))
        }
    }

    private func welcome() {
        let now = Date()
        guard now.timeIntervalSince(lastWelcome) > 30 else { return }
        lastWelcome = now
        history.removeAll()
        onPeek?(.welcome)
    }

    // MARK: Volume

    private func fadeVolume(for value: Int) {
        guard let saved = savedVolume else {
            guard !readingVolume else { return }
            readingVolume = true
            volumeQueue.async { [weak self] in
                let current = Int(runAppleScript("output volume of (get volume settings)") ?? "") ?? 50
                DispatchQueue.main.async {
                    self?.readingVolume = false
                    if self?.savedVolume == nil { self?.savedVolume = current }
                }
            }
            return
        }
        let fraction = Double(value - Self.fadeEnd) / Double(Self.fadeStart - Self.fadeEnd)
        let target = Int((Double(saved) * min(1, max(0, fraction))).rounded())
        onPeek?(.volume(target))
        if let applied = appliedVolume, abs(applied - target) < 2, target != 0 { return }
        guard appliedVolume != target else { return }
        appliedVolume = target
        volumeQueue.async { _ = runAppleScript("set volume output volume \(target)") }
    }

    private func restoreVolume() {
        guard let saved = savedVolume else { return }
        savedVolume = nil
        appliedVolume = nil
        volumeQueue.async { _ = runAppleScript("set volume output volume \(saved)") }
        onPeek?(.volume(saved))
    }
}

/// The hinge sensor: Apple HID device 0x8104, sensor usage page; feature report 1 holds the angle in degrees.
final class LidSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let device = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first else { return nil }
        self.device = device
        guard angle() != nil else { return nil }
    }

    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    func angle() -> Int? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3 else { return nil }
        let value = Int(report[1]) | Int(report[2]) << 8
        return (0...360).contains(value) ? value : nil
    }
}

// MARK: - Views

/// A little protractor: the arc is the hinge's range, the needle is the screen.
struct Protractor: View {
    let angle: Int
    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 1)
            let radius = min(size.width / 2, size.height) - 2
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            context.stroke(arc, with: .color(.white.opacity(0.25)), lineWidth: 2)
            for tick in stride(from: 0, through: 180, by: 30) {
                let a = Double(180 + tick) * .pi / 180
                var p = Path()
                p.move(to: CGPoint(x: center.x + cos(a) * (radius - 4), y: center.y + sin(a) * (radius - 4)))
                p.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
                context.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 1)
            }
            // The base is the keyboard (flat, pointing right); the needle is the screen.
            let a = Double(360 - min(180, max(0, angle))) * .pi / 180
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius))
            context.stroke(needle, with: .color(.cyan), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)), with: .color(.cyan))
        }
        .frame(width: 44, height: 24)
    }
}

struct LidPeekContent: View {
    let peek: LidPeek

    var body: some View {
        switch peek {
        case .angle(let angle):
            Protractor(angle: angle)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(angle)°").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(angle)))
                Text("Lid angle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        case .welcome:
            Text("👋").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text(greeting).font(.system(size: 13, weight: .semibold))
                Text("Welcome back").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        case .maxOpen(let angle):
            Text("🤸").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 1) {
                Text("That's as far as it goes").font(.system(size: 13, weight: .semibold))
                Text("\(angle)° · any further and it's a tablet").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        case .volume(let level):
            Image(systemName: level == 0 ? "speaker.slash.fill" : (level < 34 ? "speaker.wave.1.fill" : (level < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")))
                .font(.system(size: 18))
                .foregroundStyle(.cyan)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lid volume · \(level)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Capsule().fill(.white.opacity(0.15)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(.cyan).frame(width: g.size.width * CGFloat(level) / 100) }
                    }
            }
            Spacer(minLength: 0)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Burning the midnight oil?"
        }
    }
}
