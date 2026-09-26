import AppKit
import EventKit
import SwiftUI

private let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

// MARK: - Root

struct IslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let prompting = model.prompter.isRunning
        let glass = model.expanded && !prompting
        let radius: CGFloat = prompting ? 26 : (model.expanded ? 34 : (model.peek != nil ? 24 : 10))
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Liquid Glass when open; solid black otherwise so it melts into the notch.
                // Deep black under the glass: keeps the Liquid Glass edge but reads as rich black.
                shape.fill(.black.opacity(0.6))
                    .opacity(glass ? 1 : 0)
                Color.clear
                    .glassEffect(.regular.tint(.black.opacity(0.5)), in: shape)
                    .opacity(glass ? 1 : 0)
                shape.fill(.black)
                    .opacity(glass ? 0 : 1)

                if prompting {
                    PrompterView(model: model)
                        .transition(.opacity)
                } else if model.expanded {
                    ExpandedView(model: model)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
                } else if let peek = model.peek {
                    PeekView(model: model, peek: peek)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                } else if model.closedIndicator != nil || model.showsClosedArtwork {
                    // Only the edge tabs are visible; the middle of the island sits under the notch.
                    HStack(spacing: 0) {
                        if model.showsClosedArtwork, let track = model.media.track {
                            Artwork(model: model, track: track, size: 20)
                                .frame(width: IslandModel.indicatorPeek)
                                .padding(.leading, 2)
                        }
                        Spacer(minLength: 0)
                        if let indicator = model.closedIndicator {
                        Group {
                            switch indicator {
                            case .wave:
                                Image(systemName: "waveform")
                                    .foregroundStyle(.green)
                                    .symbolEffect(.variableColor.iterative, isActive: true)
                            case .receiving:
                                Image(systemName: "iphone.and.arrow.forward")
                                    .foregroundStyle(.teal)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: IslandModel.indicatorPeek)
                        .padding(.trailing, 2)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .overlay {
                shape.fill(Color.purple).opacity(model.mentionFlash ? 0.85 : 0)
            }
            .overlay {
                // Hairline highlight along the edge, like light catching glass.
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                  startPoint: .bottom, endPoint: .top), lineWidth: 1)
                    .opacity(glass ? 1 : 0)
            }
            .frame(width: model.currentSize.width + (model.mentionFlash ? 36 : 0),
                   height: model.currentSize.height + (model.mentionFlash ? 6 : 0))
            .clipShape(shape)
            .offset(x: model.islandOffsetX)
            .overlay {
                if model.dropTargeted {
                    shape.stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .shadow(color: .black.opacity(glass ? 0.5 : 0), radius: 26, y: 12)
            .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
                model.shelf.add(providers: providers)
                return true
            }
            .contextMenu {
                Button("Restart Islandly") { relaunchApp() }
                Button("Quit Islandly") { NSApp.terminate(nil) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(spring, value: model.expanded)
        .animation(spring, value: model.peek)
        .animation(spring, value: model.tab)
        .animation(spring, value: model.hint)
        .animation(spring, value: model.homePanel)
        .animation(spring, value: model.collapsedSize)
        .animation(spring, value: model.media.sources.count)
        .animation(spring, value: model.prompter.isRunning)
        .animation(.easeInOut(duration: 0.3), value: model.mentionFlash)
        .animation(spring, value: model.builds.running.count)
        .onChange(of: model.dropTargeted) { _, targeted in
            if targeted { model.tab = .shelf }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Peek (live activity pop-ups)

struct PeekView: View {
    @ObservedObject var model: IslandModel
    let peek: Peek

    var body: some View {
        HStack(spacing: 12) {
            switch peek {
            case .charging(let charging, let level):
                Image(systemName: charging ? "bolt.fill" : "powerplug.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(charging ? .green : .white)
                    .symbolEffect(.bounce, value: charging)
                Text(charging ? "Charging" : "On Battery")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(level)%")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(charging ? .green : .white)

            case .track(let track):
                Artwork(model: model, track: track, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, isActive: true)

            case .timerDone:
                Image(systemName: "timer")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                    .symbolEffect(.bounce, options: .repeat(3), value: true)
                Text("Timer done").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("00:00")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)

            case .meeting(let title, let hasLink):
                Image(systemName: hasLink ? "video.fill" : "calendar")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(hasLink ? "Starting now · hover to join" : "Starting now")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()

            case .color(let hex):
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: hex))
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.3)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(hex).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text("Copied to clipboard").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)

            case .keepAwakeEnded:
                Image(systemName: "cup.and.saucer")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
                Text("Keep Awake ended — your Mac can sleep again")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()

            case .signature:
                Image(systemName: "signature")
                    .font(.system(size: 20))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Signature copied").font(.system(size: 13, weight: .semibold))
                    Text("Paste it into any document with ⌘V").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)

            case .phoneReceived(let name, let isText):
                Image(systemName: isText ? "text.bubble.fill" : "iphone.and.arrow.forward")
                    .font(.system(size: 20))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isText ? "Text from your phone" : "From your phone").font(.system(size: 13, weight: .semibold))
                    Text(isText ? "“\(name)” · open Phone to copy it" : "\(name) · on the Shelf")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)

            case .textGrabbed(let preview, let lines):
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 20))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Text copied\(lines > 1 ? " · \(lines) lines" : "")")
                        .font(.system(size: 13, weight: .semibold))
                    Text(preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)

            case .noTextFound:
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nothing readable found").font(.system(size: 13, weight: .semibold))
                    Text("Try a larger area with clearer text.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()

            case .needsScreenAccess:
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Allow Screen Recording").font(.system(size: 13, weight: .semibold))
                    Text("Turn on Islandly in the Settings window, then right-click the notch ▸ Restart.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()

            case .callListening(let app):
                Image(systemName: "ear.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse, isActive: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening for your name").font(.system(size: 13, weight: .semibold))
                    Text("\(app) call · works while you're muted").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()

            case .build(let activity):
                Image(systemName: activity.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(activity.succeeded ? .green : .red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.succeeded ? "Done · \(activity.command)" : "Failed (exit \(activity.exitCode ?? 1)) · \(activity.command)")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(activity.succeeded || activity.lastLine.isEmpty
                         ? "\(activity.folder) · \(formatDuration(activity.duration))"
                         : activity.lastLine)
                        .font(.system(size: 11, design: activity.succeeded ? .default : .monospaced))
                        .foregroundStyle(activity.succeeded ? Color.secondary : Color.red.opacity(0.9))
                        .lineLimit(1)
                }
                Spacer()
                Text(formatDuration(activity.duration))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

            case .qrScanned(let payload):
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 20))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("QR code copied · hover to open").font(.system(size: 13, weight: .semibold))
                    Text(payload).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, model.notchSize.height)
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Expanded

struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            // Top row lives beside the notch: tabs on the left, status on the right.
            HStack(spacing: 0) {
                TabBar(model: model)
                Spacer()
                HStack(spacing: 10) {
                    StatGauge(model: model, value: model.stats.cpu, symbol: "cpu", hint: .cpu)
                    StatGauge(model: model, value: model.stats.memoryFraction, symbol: "memorychip", hint: .memory)
                    KeepAwakeButton(model: model)
                }
            }
            .frame(height: model.notchSize.height)
            .padding(.horizontal, 18)

            Group {
                switch model.tab {
                case .home: HomeView(model: model)
                case .timer: TimerView(model: model)
                case .shelf: ShelfView(model: model)
                case .clipboard: ClipboardView(model: model)
                case .dev: DevServersView(model: model)
                }
            }
            .id(model.tab)
            .transition(.opacity)
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Footer caption: the island grows to make room, so it never covers anything.
            if let hint = model.hint {
                FooterCaption(icon: model.hintIcon(hint), text: model.hintText(hint))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .foregroundStyle(.white)
    }
}

struct FooterCaption: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 24)
            .frame(maxHeight: .infinity)
        }
        .frame(height: IslandModel.footerHeight)
        .background(.white.opacity(0.04))
        .allowsHitTesting(false)
    }
}

extension View {
    /// Shows `hint` in the island's footer caption while hovered.
    func hint(_ hint: Hint, _ model: IslandModel) -> some View {
        onHover { hovering in
            model.setHint(hovering ? hint : nil, ifCurrent: hint)
        }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Tiny live ring gauge (CPU / memory); details show in the hint bubble.
struct StatGauge: View {
    @ObservedObject var model: IslandModel
    let value: Double
    let symbol: String
    let hint: Hint

    private var tint: Color {
        switch value {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: value)
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .hint(hint, model)
    }
}

struct TabBar: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandTab.allCases, id: \.self) { tab in
                let selected = model.tab == tab
                Button { Haptics.tap(); model.tab = tab } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Capsule().fill(.white.opacity(selected ? 0.22 : 0)))
                        .foregroundStyle(selected ? .white : .secondary)
                        .overlay(alignment: .topTrailing) {
                            if badge(for: tab) {
                                Circle().fill(.orange).frame(width: 5, height: 5).offset(x: -3, y: 3)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hint(.tab(tab), model)
            }
        }
    }

    private func badge(for tab: IslandTab) -> Bool {
        switch tab {
        case .timer: return model.timer.isActive && model.tab != .timer
        case .shelf: return !model.shelf.files.isEmpty && model.tab != .shelf
        default: return false
        }
    }
}

struct KeepAwakeButton: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let system = model.system
        Button { system.keepAwake.toggle() } label: {
            Image(systemName: system.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(system.keepAwake ? Color.yellow : .secondary)
                .symbolEffect(.bounce, value: system.keepAwake)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hint(.keepAwake, model)
        .contextMenu {
            Button("Keep awake for 30 minutes") { system.keepAwake(for: 30 * 60) }
            Button("Keep awake for 1 hour") { system.keepAwake(for: 3600) }
            Button("Keep awake for 2 hours") { system.keepAwake(for: 2 * 3600) }
            Button("Keep awake until turned off") { system.keepAwake(for: nil) }
            if system.keepAwake {
                Divider()
                Button("Turn off") { system.keepAwake = false }
            }
        }
    }
}

// MARK: - Home tab

struct HomeView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuickActionsRow(model: model)
            if let panel = model.homePanel {
                HomePanelView(model: model, panel: panel)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                if let event = model.calendar.next {
                    EventChip(model: model, event: event)
                }
                ForEach(model.builds.running.prefix(2)) { activity in
                    BuildChip(model: model, activity: activity)
                }
                NowPlayingCard(model: model)
                if model.media.sources.count > 1 {
                    SourcePicker(model: model)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.homePanel)
    }
}

struct QuickActionsRow: View {
    @ObservedObject var model: IslandModel

    private func symbol(_ action: QuickAction, on: Bool) -> String {
        switch action {
        case .colorPicker: return "eyedropper.halffull"
        case .darkMode: return on ? "moon.fill" : "sun.max.fill"
        case .grabText: return "text.viewfinder"
        case .qrBeam: return "iphone.gen3.radiowaves.left.and.right"
        case .prompter: return "text.aligncenter"
        case .nameAlert: return on && model.nameAlert.isListening ? "ear.fill" : "person.wave.2.fill"
        }
    }

    private func accent(_ action: QuickAction) -> Color {
        switch action {
        case .colorPicker: return .pink
        case .darkMode: return .indigo
        case .grabText: return .cyan
        case .qrBeam: return .teal
        case .prompter: return .red
        case .nameAlert: return .purple
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(QuickAction.allCases, id: \.self) { action in
                let on = model.isOn(action)
                QuickActionTile(symbol: symbol(action, on: on),
                                label: action.label,
                                isOn: on,
                                onTint: accent(action),
                                status: model.availability.status(for: action)) {
                    Haptics.tap()
                    model.perform(action)
                }
                .hint(.action(action), model)
            }
        }
    }
}

// MARK: - Home panels (QR Beam)

struct HomePanelView: View {
    @ObservedObject var model: IslandModel
    let panel: HomePanel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if panel == .qr {
                    PhoneModePicker(model: model)
                } else {
                    SectionTitle(text: panel.title)
                }
                Spacer()
                IconButton(symbol: "xmark", help: "Close") { model.homePanel = nil }
            }
            .frame(height: 24)
            Group {
                switch panel {
                case .qr:
                    switch model.phoneMode {
                    case .send: QRPanel(model: model)
                    case .receive: ReceivePanel(model: model)
                    case .sign: SignPanel(model: model)
                    }
                case .prompter: PrompterPanel(model: model)
                case .nameAlert: NameAlertPanel(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: panel.height)
    }
}

struct QRPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let servers = model.devServers.servers.filter(\.isWeb)
        let server = servers.first { $0.id == model.qrServerID }
        let lan = server.flatMap { $0.onNetwork ? DevServerModel.lanAddress() : nil }
        let scanned = server == nil ? model.qrScanResult : nil
        let text: String? = server != nil ? lan.map { "http://\($0):\(server!.port)" } : (scanned ?? model.clipboard.items.first)
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let text, let image = model.qrImage(for: text) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.08))
                        .overlay(Image(systemName: server != nil ? "lock.fill" : "qrcode").font(.system(size: 34)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 7) {
                Text(headline(server: server, lan: lan, scanned: scanned, text: text))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Group {
                    if let server, !server.onNetwork {
                        Text("Localhost only. Run \(Text(PhonePanel.restartHint(for: server)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.cyan))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(text ?? (server != nil ? "Connect this Mac to Wi-Fi first." : "Copy a link or any text and point your phone's camera at the code."))
                            .foregroundStyle(server != nil ? .cyan : .secondary)
                    }
                }
                .font(.system(size: 11, design: server?.onNetwork == true ? .monospaced : .default))
                .lineLimit(3)
                Spacer(minLength: 0)
                if !servers.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(servers) { s in
                                    ServerChip(server: s, selected: s.id == server?.id) {
                                        Haptics.tap()
                                        model.qrServerID = s.id == server?.id ? nil : s.id
                                    }
                                    .id(s.id)
                                }
                            }
                        }
                        .onAppear { if let id = server?.id { proxy.scrollTo(id) } }
                        .onChange(of: model.qrServerID) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id) } }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if let text, let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
                        PillButton(title: "Open", symbol: "arrow.up.right", tint: .blue) { NSWorkspace.shared.open(url) }
                    }
                    if scanned != nil || server != nil {
                        PillButton(title: "Clipboard", symbol: "doc.on.clipboard") {
                            model.qrScanResult = nil
                            model.qrServerID = nil
                        }
                    }
                }
            }
            .frame(maxHeight: 128)
        }
        .onAppear { model.devServers.refresh() }
    }

    private func headline(server: DevServer?, lan: String?, scanned: String?, text: String?) -> String {
        if let server { return lan != nil || !server.onNetwork ? "\(server.title) on your phone" : "\(server.title) · no Wi-Fi" }
        if scanned != nil { return "Scanned from your screen" }
        return text == nil ? "Nothing copied yet" : "Your clipboard, ready to scan"
    }
}

/// A running dev server in QR Beam; picking it turns its network URL into the code.
struct ServerChip: View {
    let server: DevServer
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: server.onNetwork ? "iphone" : "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("\(server.shortName) :\(String(server.port))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? .white : .white.opacity(server.onNetwork ? 0.85 : 0.5))
            .background(Capsule().fill(selected ? Color.teal.opacity(0.45) : .white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(selected ? Color.teal : .white.opacity(0.1), lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct QuickActionTile: View {
    let symbol: String
    let label: String
    let isOn: Bool
    let onTint: Color
    var status: FeatureStatus = .ready
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @State private var nudge = 0

    private var unsupported: Bool {
        if case .unsupported = status { return true }
        return false
    }
    private var needsSetup: Bool {
        if case .needsSetup = status { return true }
        return false
    }

    var body: some View {
        Button {
            if unsupported { nudge += 1 }  // shake "no"; the footer caption says why
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isOn ? onTint : .white)
                    .frame(height: 18)
                    .contentTransition(.symbolEffect(.replace))
                    .overlay(alignment: .topTrailing) {
                        if unsupported {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(2.5)
                                .background(Circle().fill(.black.opacity(0.75)))
                                .offset(x: 8, y: -5)
                        } else if needsSetup {
                            Circle()
                                .fill(.orange)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                                .offset(x: 6, y: -3)
                        }
                    }
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(isOn ? 1 : 0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isOn ? onTint.opacity(0.28) : .white.opacity(hovering ? 0.13 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isOn ? onTint.opacity(0.7) : .white.opacity(hovering ? 0.14 : 0.06), lineWidth: 1)
            )
            .shadow(color: isOn ? onTint.opacity(0.45) : .clear, radius: 8)
            .opacity(unsupported ? 0.45 : 1)
            .saturation(unsupported ? 0 : 1)
            .keyframeAnimator(initialValue: 0.0, trigger: nudge) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-5, duration: 0.06)
                    LinearKeyframe(5, duration: 0.08)
                    LinearKeyframe(-3, duration: 0.08)
                    LinearKeyframe(0, duration: 0.08)
                }
            }
            .scaleEffect(pressed ? 0.94 : (hovering ? 1.03 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isOn)
    }
}

struct EventChip: View {
    @ObservedObject var model: IslandModel
    let event: EKEvent

    var body: some View {
        let link = CalendarModel.meetingURL(for: event)
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(event.calendar?.cgColor.map { Color(cgColor: $0) } ?? .blue)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "Event")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(CalendarModel.relativeTime(for: event, now: model.system.now))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let link {
                Spacer(minLength: 0)
                Button { NSWorkspace.shared.open(link) } label: {
                    Text("Join")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.green))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(link.absoluteString)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(14)
    }
}

struct Artwork: View {
    @ObservedObject var model: IslandModel
    let track: Track
    let size: CGFloat

    var body: some View {
        let appIcon = Image(nsImage: model.media.icon(for: track.source)).resizable()
        Group {
            if let url = track.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        appIcon
                    }
                }
            } else {
                appIcon
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct NowPlayingCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let track = model.media.track {
                    Artwork(model: model, track: track, size: 46)
                        .onTapGesture { model.media.focus(track) }
                        .help("Show in \(track.source.appName)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(track.canControl ? track.artist : "Enable Chrome ▸ View ▸ Developer ▸ Allow JavaScript from Apple Events")
                            .font(.system(size: track.canControl ? 12 : 10))
                            .foregroundStyle(track.canControl ? .secondary : Color.orange)
                            .lineLimit(track.canControl ? 1 : 2)
                    }
                    Spacer(minLength: 8)
                    if track.canControl {
                        HStack(spacing: 18) {
                            ControlButton(symbol: "backward.fill") { model.media.send(.previous) }
                            ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 20) { model.media.send(.playPause) }
                            ControlButton(symbol: "forward.fill") { model.media.send(.next) }
                        }
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 18))
                        .frame(width: 46, height: 46)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.1)))
                    Text("Nothing playing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let track = model.media.track, track.canControl, track.duration > 0 {
                ProgressBar(model: model, track: track)
            }
        }
        .padding(10)
        .card(20)
        // Two-finger swipe: the card follows your fingers; arrows hint what will happen.
        .overlay(alignment: .leading) {
            Image(systemName: "backward.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .opacity(Double(max(0, model.mediaSwipe) / 45))
                .offset(x: -26)
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "forward.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .opacity(Double(max(0, -model.mediaSwipe) / 45))
                .offset(x: 26)
        }
        .offset(x: model.mediaSwipe)
        .rotation3DEffect(.degrees(Double(model.mediaSwipe) / 6), axis: (x: 0, y: 1, z: 0))
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: model.mediaSwipe)
        .onHover { model.hoveringMediaCard = $0 }
    }
}

/// Click or drag to seek.
struct ProgressBar: View {
    @ObservedObject var model: IslandModel
    let track: Track
    @State private var dragFraction: Double?

    private func format(_ s: Double) -> String {
        let s = Int(max(0, s))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        let fraction = dragFraction ?? min(1, track.position(at: model.system.now) / track.duration)
        HStack(spacing: 8) {
            Text(format(fraction * track.duration))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: max(4, geo.size.width * fraction))
                }
                .frame(height: dragFraction == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { dragFraction = min(1, max(0, $0.location.x / geo.size.width)) }
                        .onEnded { value in
                            let f = min(1, max(0, value.location.x / geo.size.width))
                            model.media.send(.seek(f * track.duration))
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 12)
            Text("-" + format(track.duration - fraction * track.duration))
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.12), value: dragFraction == nil)
    }
}

/// Every open YouTube tab / music app; tap to switch which one the island controls.
struct SourcePicker: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.media.sources) { track in
                    let isSelected = track.source == model.media.selected
                    Button {
                        model.media.selected = track.source
                    } label: {
                        HStack(spacing: 7) {
                            ZStack(alignment: .bottomTrailing) {
                                Artwork(model: model, track: track, size: 26)
                                if track.isPlaying {
                                    Circle().fill(.green)
                                        .frame(width: 8, height: 8)
                                        .overlay(Circle().stroke(.black, lineWidth: 1.5))
                                        .offset(x: 2, y: 2)
                                }
                            }
                            Text(track.title)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: 110, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .background(Capsule().fill(.white.opacity(isSelected ? 0.2 : 0.07)))
                        .overlay(Capsule().stroke(.white.opacity(isSelected ? 0.35 : 0), lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(track.title)
                }
            }
        }
        .frame(height: 38)
    }
}

struct ControlButton: View {
    let symbol: String
    var size: CGFloat = 15
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .opacity(hovering ? 1 : 0.85)
                .scaleEffect(hovering ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Timer tab

struct TimerView: View {
    @ObservedObject var model: IslandModel
    private let presets = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        let timer = model.timer
        if timer.isActive {
            let remaining = timer.remaining(at: model.system.now)
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(.white.opacity(0.12), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: timer.total > 0 ? remaining / timer.total : 0)
                        .stroke(timer.isPaused ? Color.secondary : .orange,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remaining)
                    Text(formatCountdown(remaining))
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 12) {
                    Text(timer.isPaused
                         ? "Paused"
                         : "Ends at \(model.system.now.addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        PillButton(title: timer.isPaused ? "Resume" : "Pause",
                                   symbol: timer.isPaused ? "play.fill" : "pause.fill",
                                   tint: .orange) { timer.togglePause() }
                        PillButton(title: "1 min", symbol: "plus") { timer.add(60) }
                        PillButton(title: "Stop", symbol: "xmark") { timer.cancel() }
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Quick timer")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(presets, id: \.self) { minutes in
                        PresetButton(title: minutes == 60 ? "1 hr" : "\(minutes) min") {
                            Haptics.tap()
                            timer.start(seconds: TimeInterval(minutes * 60))
                        }
                    }
                }
            }
        }
    }
}

struct PillButton: View {
    let title: String
    let symbol: String
    var tint: Color = .white.opacity(0.14)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(tint))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shelf tab

struct ShelfView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let shelf = model.shelf
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                SectionTitle(text: shelf.files.isEmpty ? "Shelf" : "Shelf · \(shelf.files.count)")
                Spacer()
                if !shelf.files.isEmpty {
                    IconButton(symbol: "dot.radiowaves.up.forward", help: "AirDrop all") { shelf.airDrop() }
                    IconButton(symbol: "trash", help: "Clear shelf") { shelf.clear() }
                }
            }
            if shelf.files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 22))
                    Text("Drag files onto the notch to keep them handy")
                        .font(.system(size: 12))
                }
                .foregroundStyle(model.dropTargeted ? .white : .secondary)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(.white.opacity(model.dropTargeted ? 0.6 : 0.25))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(shelf.files, id: \.self) { url in
                            FileTile(shelf: shelf, url: url)
                        }
                    }
                }
                .frame(height: 96)
            }
        }
    }
}

struct FileTile: View {
    let shelf: ShelfModel
    let url: URL
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 72)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hovering ? 0.12 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { shelf.open(url) }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { shelf.open(url) }
            Button("Show in Finder") { shelf.reveal(url) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(url) }
        }
        .help("\(url.path)\nDouble-click to open · drag out to use")
    }
}

// MARK: - Clipboard tab

struct ClipboardView: View {
    @ObservedObject var model: IslandModel
    @State private var justCopied: String?

    var body: some View {
        let clipboard = model.clipboard
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: clipboard.items.isEmpty ? "Clipboard" : "Clipboard · \(clipboard.items.count)")
                Spacer()
                if !clipboard.items.isEmpty {
                    IconButton(symbol: "trash", help: "Clear history") { clipboard.clear() }
                }
            }
            if clipboard.items.isEmpty {
                Text("Text you copy will show up here.\nClick an item to copy it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(clipboard.items, id: \.self) { text in
                            ClipRow(text: text, copied: justCopied == text) {
                                clipboard.copy(text)
                                justCopied = text
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    if justCopied == text { justCopied = nil }
                                }
                            } onRemove: {
                                clipboard.remove(text)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ClipRow: View {
    let text: String
    let copied: Bool
    let onCopy: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 8) {
                Text(text.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if copied {
                    Label("Copied", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.green)
                } else if hovering {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hovering ? 0.14 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { onCopy() }
            Button("Remove") { onRemove() }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}


// MARK: - Shared polish

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.5))
    }
}

extension View {
    /// Soft card: translucent fill with a hairline edge for depth.
    func card(_ radius: CGFloat) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.07), lineWidth: 1))
        )
    }
}

struct PresetButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(hovering ? Color.orange : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? Color.orange.opacity(0.18) : .white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? Color.orange.opacity(0.5) : .white.opacity(0.07), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Subtle trackpad haptics (felt when a finger is on the trackpad), like native macOS controls.
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
    static func open() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

