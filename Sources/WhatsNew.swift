import AppKit
import SwiftUI

// One-time cards that drop out of the notch by themselves: "an update is ready", "here's what's new", and
// "new feature, want it on?". Each is shown once; the island stays open until it's answered.
//
// Shipping a release? Add an entry to `WhatsNewModel.notes` (what changed, shown once to people who update) and,
// for something people must switch on, to `WhatsNewModel.features` (a card with Turn on / Not now).

struct WhatsNewNote: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
}

struct FeatureOffer: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let footnote: String
    let button: String
}

/// What the island is showing on its own, in priority order (only one at a time).
enum NotchCard: Hashable {
    case agent(UUID)
    case update
    case whatsNew
    case feature(String)
}

final class WhatsNewModel: ObservableObject {
    /// Newest first. Ids must never change: they record what someone has already seen. Keep each one short:
    /// a title of a few words and one line under it.
    static let notes: [WhatsNewNote] = [
        WhatsNewNote(id: "2026-10-agents", symbol: "sparkle", tint: claudeOrange,
                     title: "Claude Code & Codex in your notch", subtitle: "See what they're doing and Allow or Deny requests here."),
        WhatsNewNote(id: "2026-09-name-alert-engine", symbol: "person.wave.2.fill", tint: .purple,
                     title: "Name Alert hears you better", subtitle: "A new speech engine catches your name 3× more often."),
        WhatsNewNote(id: "2026-09-updates", symbol: "arrow.down.circle.fill", tint: .green,
                     title: "One-click updates", subtitle: "New versions show up right here. Click and you're done."),
    ]

    static let features: [FeatureOffer] = [
        FeatureOffer(id: "claude-agent", symbol: "sparkle", tint: claudeOrange,
                     title: "Show Claude Code here?", subtitle: "Answer its permission requests from the notch.",
                     footnote: "Adds a hook to Claude's settings · undo any time", button: "Turn on"),
        FeatureOffer(id: "codex-agent", symbol: "chevron.left.forwardslash.chevron.right", tint: Color(white: 0.45),
                     title: "Show Codex here?", subtitle: "Answer its approval requests from the notch.",
                     footnote: "Codex then asks you to approve it once", button: "Turn on"),
    ]

    @Published private(set) var seen: Set<String>
    /// Cards wait a moment after launch, so they don't pop the instant the app opens.
    @Published private(set) var ready = false

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: "whatsNewSeen") {
            seen = Set(saved)
        } else {
            // First run of this version. A brand-new install has nothing to compare with, so it skips the
            // "what's new" notes (feature offers still show); someone updating sees them.
            let existingUser = !(defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "app.islandly") ?? [:]).isEmpty
            seen = existingUser ? [] : Set(Self.notes.map(\.id))
            defaults.set(Array(seen), forKey: "whatsNewSeen")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.ready = true }
    }

    var unseenNotes: [WhatsNewNote] { ready ? Self.notes.filter { !seen.contains($0.id) } : [] }

    /// How many notes this run started with, for the page dots.
    private(set) lazy var batchSize = Self.notes.filter { !seen.contains($0.id) }.count

    /// The next feature offer that applies to this Mac (e.g. Claude Code is installed and not yet connected).
    func nextFeature(applies: (FeatureOffer) -> Bool) -> FeatureOffer? {
        guard ready else { return nil }
        return Self.features.first { !seen.contains($0.id) && applies($0) }
    }

    func markNotesSeen() { markSeen(Self.notes.map(\.id)) }

    func markSeen(_ ids: [String]) {
        seen.formUnion(ids)
        UserDefaults.standard.set(Array(seen), forKey: "whatsNewSeen")
    }
}

// MARK: - Views

let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

/// Rounded, gradient icon tile — the card's anchor.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: tint.opacity(0.45), radius: 10, y: 2)
    }
}

/// Every card: icon tile + title + one line, then a footer row (left accessory, buttons on the right).
struct NotchCardLayout<Accessory: View, Buttons: View>: View {
    @ObservedObject var model: IslandModel
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    /// Shows this app icon instead of the symbol tile (e.g. "codex" / "claude").
    var agentIcon: String? = nil
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let agentIcon, AgentIcons.icon(for: agentIcon) != nil {
                    AgentBadge(source: agentIcon, size: 40)
                } else {
                    IconTile(symbol: symbol, tint: tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                accessory()
                Spacer(minLength: 8)
                buttons()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, model.notchSize.height + 8)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct CardButton: View {
    let title: String
    var primary = false
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(primary ? .black : .white.opacity(0.75))
                .padding(.horizontal, primary ? 16 : 8)
                .frame(height: 28)
                .background(Capsule().fill(primary ? tint : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Small gray caption for the footer's left side.
private struct Footnote: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(.white.opacity(i == current ? 0.9 : 0.25))
                    .frame(width: i == current ? 14 : 5, height: 5)
            }
        }
    }
}

/// "An update is ready", then progress until Islandly restarts itself.
struct UpdateOfferCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let updates = model.updates
        switch updates.state {
        case .updating(let step):
            NotchCardLayout(model: model, symbol: "arrow.down", tint: .green,
                            title: "Updating Islandly…", subtitle: step) {
                ProgressView().controlSize(.small).tint(.green)
                Footnote(text: "Restarts by itself · keep working")
            } buttons: { EmptyView() }
        case .failed(let message):
            NotchCardLayout(model: model, symbol: "exclamationmark.triangle.fill", tint: .orange,
                            title: "Update didn't finish", subtitle: message) {
                Footnote(text: "Nothing changed")
            } buttons: {
                CardButton(title: "Close") { updates.dismissOffer() }
                CardButton(title: "Try again", primary: true, tint: .orange) { updates.update() }
            }
        default:
            NotchCardLayout(model: model, symbol: "arrow.down", tint: .green,
                            title: "Update ready", subtitle: Self.highlights(updates.availableChanges)) {
                Footnote(text: "About a minute · restarts by itself")
            } buttons: {
                CardButton(title: "Later") { updates.dismissOffer() }
                CardButton(title: "Update", primary: true, tint: .green) { updates.update() }
            }
        }
    }

    /// Commit subjects → a short, readable line ("Name Alert engine, one-click updates and 2 more").
    static func highlights(_ subjects: [String]) -> String {
        let parts = subjects.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ";,")) }
            .map { $0.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = parts.first else { return "Fixes and improvements." }
        let shown = parts.prefix(2).joined(separator: " · ")
        return parts.count > 2 ? "\(shown) · +\(parts.count - 2) more" : (parts.count == 2 ? shown : first)
    }
}

/// After an update: what's new, one page per feature.
struct WhatsNewCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let whatsNew = model.whatsNew
        let notes = whatsNew.unseenNotes
        if let note = notes.first {
            let total = max(whatsNew.batchSize, notes.count)
            NotchCardLayout(model: model, symbol: note.symbol, tint: note.tint, title: note.title, subtitle: note.subtitle) {
                HStack(spacing: 8) {
                    Text("NEW").font(.system(size: 9, weight: .heavy)).tracking(1).foregroundStyle(note.tint)
                    if total > 1 { PageDots(count: total, current: total - notes.count) }
                }
            } buttons: {
                if notes.count > 1 {
                    CardButton(title: "Skip") { whatsNew.markNotesSeen() }
                    CardButton(title: "Next", primary: true) { whatsNew.markSeen([note.id]) }
                } else {
                    CardButton(title: "Done", primary: true) { whatsNew.markSeen([note.id]) }
                }
            }
        }
    }
}

/// A new feature that needs switching on.
struct FeatureOfferCard: View {
    @ObservedObject var model: IslandModel
    let offer: FeatureOffer

    var body: some View {
        NotchCardLayout(model: model, symbol: offer.symbol, tint: offer.tint, title: offer.title, subtitle: offer.subtitle,
                        agentIcon: offer.id == "codex-agent" ? "codex" : (offer.id == "claude-agent" ? "claude" : nil)) {
            Footnote(text: offer.footnote)
        } buttons: {
            CardButton(title: "Not now") { model.whatsNew.markSeen([offer.id]) }
            CardButton(title: offer.button, primary: true, tint: offer.tint) {
                model.whatsNew.markSeen([offer.id])
                model.acceptFeature(offer)
            }
        }
    }
}

/// Whichever card the island is showing.
struct NotchCardView: View {
    @ObservedObject var model: IslandModel
    let card: NotchCard

    var body: some View {
        switch card {
        case .agent:
            if let request = model.agents.pending { AgentRequestView(model: model, request: request) }
        case .update:
            UpdateOfferCard(model: model)
        case .whatsNew:
            WhatsNewCard(model: model)
        case .feature(let id):
            if let offer = WhatsNewModel.features.first(where: { $0.id == id }) {
                FeatureOfferCard(model: model, offer: offer)
            }
        }
    }
}
