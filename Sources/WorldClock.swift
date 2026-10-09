import AppKit
import SwiftUI

// World Clock: your time plus the cities you pick, with how far ahead/behind they are, day/night and work hours.
// A slider moves every clock together ("if it's 9 PM here, what is it in New York?") for planning meetings.
// Copying a time with a zone ("3pm EST", "15:30 UTC", "10am London") shows it in your time, no clicks needed.
// It rides the clipboard check Islandly already does, so it costs nothing extra.

final class WorldClockModel: ObservableObject {
    @Published private(set) var zones: [String] {
        didSet { UserDefaults.standard.set(zones, forKey: "worldClocks") }
    }
    /// Names picked from Time Zones ("Eastern Time") shown instead of the city.
    @Published private(set) var labels: [String: String] {
        didSet { UserDefaults.standard.set(labels, forKey: "worldClockLabels") }
    }
    /// Hours added to "now" by the slider (0 = live).
    @Published var offsetHours: Double = 0

    static let maxZones = 8

    init() {
        zones = UserDefaults.standard.stringArray(forKey: "worldClocks")
            ?? ["America/New_York", "Europe/London", "Asia/Dubai"]
        labels = UserDefaults.standard.dictionary(forKey: "worldClockLabels") as? [String: String] ?? [:]
    }

    func add(_ id: String, label: String? = nil) {
        guard !zones.contains(id), zones.count < Self.maxZones, TimeZone(identifier: id) != nil else { return }
        zones.append(id)
        if let label { labels[id] = label }
    }

    func remove(_ id: String) {
        zones.removeAll { $0 == id }
        labels[id] = nil
    }

    func name(_ id: String) -> String { labels[id] ?? Self.city(id) }

    func move(_ id: String, by delta: Int) {
        guard let i = zones.firstIndex(of: id) else { return }
        let j = min(max(0, i + delta), zones.count - 1)
        zones.swapAt(i, j)
    }

    // MARK: Names

    static func city(_ id: String) -> String {
        id.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? id
    }

    /// Friendly short names where macOS only gives "GMT+5".
    private static let nicknames: [String: String] = [
        "Asia/Karachi": "PKT", "Asia/Kolkata": "IST", "Asia/Calcutta": "IST", "Asia/Dubai": "GST",
        "Asia/Riyadh": "AST", "Asia/Singapore": "SGT", "Asia/Hong_Kong": "HKT", "Asia/Tokyo": "JST",
        "Asia/Seoul": "KST", "Asia/Shanghai": "CST", "Asia/Dhaka": "BST", "Asia/Jakarta": "WIB",
        "Europe/Istanbul": "TRT", "Europe/Moscow": "MSK", "Africa/Cairo": "EET", "Africa/Lagos": "WAT",
        "Africa/Nairobi": "EAT", "Africa/Johannesburg": "SAST", "America/Sao_Paulo": "BRT",
        "Australia/Sydney": "AET", "Pacific/Auckland": "NZT",
    ]

    /// Summer-time aware names macOS spells as "GMT+1".
    private static let seasonal: [String: (standard: String, summer: String)] = [
        "Europe/London": ("GMT", "BST"), "Europe/Dublin": ("GMT", "IST"), "Europe/Lisbon": ("WET", "WEST"),
        "Europe/Paris": ("CET", "CEST"), "Europe/Berlin": ("CET", "CEST"), "Europe/Madrid": ("CET", "CEST"),
        "Europe/Rome": ("CET", "CEST"), "Europe/Amsterdam": ("CET", "CEST"), "Europe/Brussels": ("CET", "CEST"),
        "Europe/Zurich": ("CET", "CEST"), "Europe/Stockholm": ("CET", "CEST"), "Europe/Vienna": ("CET", "CEST"),
        "Europe/Warsaw": ("CET", "CEST"), "Europe/Prague": ("CET", "CEST"), "Europe/Oslo": ("CET", "CEST"),
        "Europe/Copenhagen": ("CET", "CEST"), "Europe/Athens": ("EET", "EEST"), "Europe/Helsinki": ("EET", "EEST"),
        "Europe/Kiev": ("EET", "EEST"), "Europe/Kyiv": ("EET", "EEST"), "Europe/Bucharest": ("EET", "EEST"),
        "Australia/Sydney": ("AEST", "AEDT"), "Australia/Melbourne": ("AEST", "AEDT"), "Pacific/Auckland": ("NZST", "NZDT"),
    ]

    /// Which calendar day it is in `zone` (for "tomorrow" / "yesterday").
    static func dayNumber(_ date: Date, in zone: TimeZone) -> Int {
        Int(((date.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: date))) / 86400).rounded(.down))
    }

    static func abbreviation(_ zone: TimeZone, at date: Date = Date()) -> String {
        if let names = seasonal[zone.identifier] { return zone.isDaylightSavingTime(for: date) ? names.summer : names.standard }
        let abbr = zone.abbreviation(for: date) ?? ""
        if abbr.hasPrefix("GMT+") || abbr.hasPrefix("GMT-") || abbr.isEmpty, let nick = nicknames[zone.identifier] { return nick }
        return abbr
    }

    // MARK: City picker (Region ▸ City)

    static let popular = ["America/New_York", "America/Los_Angeles", "America/Chicago", "America/Toronto",
                          "Europe/London", "Europe/Berlin", "Europe/Paris", "Europe/Istanbul", "Asia/Dubai",
                          "Asia/Riyadh", "Asia/Karachi", "Asia/Kolkata", "Asia/Singapore", "Asia/Tokyo",
                          "Australia/Sydney"]

    // MARK: Countries (from the system's tz table: country code → zones)

    struct CountryZone: Hashable {
        let id: String
        let note: String?      // "Eastern (most areas)" for countries with several zones
    }

    /// Zone → country code, and country code → its zones, read once from /usr/share/zoneinfo/zone.tab.
    private static let table: (countryOf: [String: String], zonesOf: [String: [CountryZone]]) = {
        var countryOf: [String: String] = [:], zonesOf: [String: [CountryZone]] = [:]
        let text = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 3, TimeZone(identifier: cols[2]) != nil else { continue }
            countryOf[cols[2]] = cols[0]
            zonesOf[cols[0], default: []].append(CountryZone(id: cols[2], note: cols.count > 3 ? cols[3] : nil))
        }
        return (countryOf, zonesOf)
    }()

    static func country(_ id: String) -> String? {
        guard let code = table.countryOf[id] else { return nil }
        return Locale.current.localizedString(forRegionCode: code)
    }

    /// Every country, A–Z, with its zones.
    static let countries: [(name: String, zones: [CountryZone])] = {
        table.zonesOf.compactMap { code, zones in
            Locale.current.localizedString(forRegionCode: code).map { ($0, zones.sorted { city($0.id) < city($1.id) }) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// Countries on one clock (one zone, or several that always agree, like Germany), by English name, for copied
    /// text like "10am Germany". Countries with real differences (US, Australia…) are left out: too ambiguous.
    static let singleZoneCountries: [String: String] = {
        let english = Locale(identifier: "en_US")
        let january = Date(timeIntervalSince1970: 1_767_225_600), july = Date(timeIntervalSince1970: 1_782_864_000)
        var map: [String: String] = [:]
        for (code, zones) in table.zonesOf {
            let offsets = Set(zones.compactMap { TimeZone(identifier: $0.id) }.flatMap { [$0.secondsFromGMT(for: january), $0.secondsFromGMT(for: july) * 7] })
            guard let first = zones.first, offsets.count <= 2, let name = english.localizedString(forRegionCode: code) else { continue }
            map[name.lowercased()] = first.id
        }
        // Where people mean the main city even though the country has other zones.
        let main = ["uae": "Asia/Dubai", "uk": "Europe/London", "england": "Europe/London", "spain": "Europe/Madrid",
                    "portugal": "Europe/Lisbon", "turkey": "Europe/Istanbul", "türkiye": "Europe/Istanbul",
                    "brazil": "America/Sao_Paulo", "russia": "Europe/Moscow", "indonesia": "Asia/Jakarta",
                    "china": "Asia/Shanghai", "ksa": "Asia/Riyadh", "saudi": "Asia/Riyadh"]
        map.merge(main) { _, new in new }
        return map
    }()

    /// The zones people name directly.
    static let standardZones: [(label: String, id: String)] = [
        ("Eastern Time (ET)", "America/New_York"), ("Central Time (CT)", "America/Chicago"),
        ("Mountain Time (MT)", "America/Denver"), ("Pacific Time (PT)", "America/Los_Angeles"),
        ("Alaska Time (AKT)", "America/Anchorage"), ("Hawaii Time (HST)", "Pacific/Honolulu"),
        ("Brasília Time (BRT)", "America/Sao_Paulo"), ("UTC", "UTC"), ("UK Time (GMT/BST)", "Europe/London"),
        ("Central European (CET)", "Europe/Paris"), ("Eastern European (EET)", "Europe/Athens"),
        ("Moscow Time (MSK)", "Europe/Moscow"), ("Gulf Time (GST)", "Asia/Dubai"), ("Pakistan Time (PKT)", "Asia/Karachi"),
        ("India Time (IST)", "Asia/Kolkata"), ("Bangladesh Time (BST)", "Asia/Dhaka"), ("China Time (CST)", "Asia/Shanghai"),
        ("Singapore Time (SGT)", "Asia/Singapore"), ("Japan Time (JST)", "Asia/Tokyo"), ("Korea Time (KST)", "Asia/Seoul"),
        ("Australian Eastern (AET)", "Australia/Sydney"), ("New Zealand (NZT)", "Pacific/Auckland"),
    ]
}

// MARK: - Copied times → your time

struct TimeConversion: Equatable {
    let source: String          // "3:00 PM EST"
    let local: String           // "1:00 AM"
    let localZone: String       // "PKT"
    let localDay: String?       // "tomorrow" / "yesterday" relative to the source's day
    let others: [String]        // "London 8:00 PM"

    private static let zoneWords: [String: String] = [
        "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York", "eastern": "America/New_York",
        "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago", "central": "America/Chicago",
        "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver", "mountain": "America/Denver",
        "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles", "pacific": "America/Los_Angeles",
        "akst": "America/Anchorage", "hst": "Pacific/Honolulu",
        "utc": "UTC", "gmt": "GMT", "z": "UTC", "bst": "Europe/London", "uk": "Europe/London",
        "wet": "Europe/Lisbon", "cet": "Europe/Paris", "cest": "Europe/Paris", "eet": "Europe/Athens", "eest": "Europe/Athens",
        "msk": "Europe/Moscow", "trt": "Europe/Istanbul", "gst": "Asia/Dubai", "pkt": "Asia/Karachi", "ist": "Asia/Kolkata",
        "sgt": "Asia/Singapore", "hkt": "Asia/Hong_Kong", "jst": "Asia/Tokyo", "kst": "Asia/Seoul",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "awst": "Australia/Perth", "nzst": "Pacific/Auckland",
        "nzdt": "Pacific/Auckland", "sast": "Africa/Johannesburg", "wat": "Africa/Lagos", "eat": "Africa/Nairobi",
        "brt": "America/Sao_Paulo",
        // Cities people write that aren't tz names.
        "nyc": "America/New_York", "boston": "America/New_York", "miami": "America/New_York", "dc": "America/New_York",
        "washington": "America/New_York", "atlanta": "America/New_York", "sf": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles", "la": "America/Los_Angeles",
        "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
        "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "lahore": "Asia/Karachi", "islamabad": "Asia/Karachi", "pakistan": "Asia/Karachi", "india": "Asia/Kolkata",
        "abu dhabi": "Asia/Dubai", "uae": "Asia/Dubai", "beijing": "Asia/Shanghai", "munich": "Europe/Berlin",
    ]

    /// Every tz city name ("new york", "london", "karachi"…), for "10am London".
    private static let cityWords: [String: String] = {
        var map: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            map[WorldClockModel.city(id).lowercased()] = id
        }
        return map
    }()

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\d:])(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?\s*(?:\(|in\s+|)\s*((?:utc|gmt)\s*[+-]\s*\d{1,2}(?::?\d{2})?|[a-z]+(?:\s+[a-z]+){0,2})"#,
        options: [.caseInsensitive])

    /// "3pm EST", "15:30 UTC", "10:00 am New York time", "9 PM (GMT+1)". Needs a zone and either am/pm or hh:mm.
    static func parse(_ text: String, clocks: [String], now: Date = Date()) -> TimeConversion? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 120 else { return nil }
        let ns = trimmed as NSString
        for match in pattern.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            guard var hour = group(1).flatMap(Int.init) else { continue }
            let minute = group(2).flatMap(Int.init) ?? 0
            let meridiem = group(3)?.lowercased().replacingOccurrences(of: ".", with: "")
            guard meridiem != nil || group(2) != nil, minute < 60 else { continue }
            if let meridiem {
                guard (1...12).contains(hour) else { continue }
                if meridiem == "pm" && hour != 12 { hour += 12 }
                if meridiem == "am" && hour == 12 { hour = 0 }
            }
            guard hour < 24, let zoneText = group(4), let zone = zone(from: zoneText) else { continue }
            guard zone.identifier != TimeZone.current.identifier,
                  zone.secondsFromGMT(for: now) != TimeZone.current.secondsFromGMT(for: now) else { return nil }

            var sourceCalendar = Calendar(identifier: .gregorian)
            sourceCalendar.timeZone = zone
            var parts = sourceCalendar.dateComponents([.year, .month, .day], from: now)
            parts.hour = hour
            parts.minute = minute
            guard let instant = sourceCalendar.date(from: parts) else { continue }

            let shift = WorldClockModel.dayNumber(instant, in: .current) - WorldClockModel.dayNumber(instant, in: zone)
            let others = clocks.compactMap(TimeZone.init(identifier:))
                .filter { $0.secondsFromGMT(for: instant) != zone.secondsFromGMT(for: instant) && $0.identifier != TimeZone.current.identifier }
                .prefix(3)
                .map { "\(WorldClockModel.city($0.identifier)) \(format(instant, in: $0))" }
            return TimeConversion(source: "\(format(instant, in: zone)) \(WorldClockModel.abbreviation(zone, at: instant))",
                                  local: format(instant, in: .current),
                                  localZone: WorldClockModel.abbreviation(.current, at: instant),
                                  localDay: shift > 0 ? "next day" : (shift < 0 ? "previous day" : nil),
                                  others: Array(others))
        }
        return nil
    }

    private static func zone(from raw: String) -> TimeZone? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        // UTC+5, GMT-3:30
        let compact = text.replacingOccurrences(of: " ", with: "")
        if compact.hasPrefix("utc") || compact.hasPrefix("gmt"), compact.count > 3 {
            let rest = compact.dropFirst(3)
            let sign = rest.first == "-" ? -1 : 1
            let digits = rest.dropFirst().split(separator: ":")
            let h = Int(digits.first.map { $0.count > 2 ? String($0.prefix($0.count - 2)) : String($0) } ?? "") ?? 0
            let m = digits.count > 1 ? Int(digits[1]) ?? 0 : (digits.first.map { $0.count > 2 ? Int($0.suffix(2)) ?? 0 : 0 } ?? 0)
            return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
        }
        // Longest phrase first: "new york time" → "new york".
        let words = text.split(separator: " ").map(String.init)
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            let phrase = words.prefix(count).joined(separator: " ")
            if let id = zoneWords[phrase] ?? cityWords[phrase] ?? WorldClockModel.singleZoneCountries[phrase] { return TimeZone(identifier: id) }
        }
        return nil
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    /// "4:52 PM" in that zone (12/24-hour follows the Mac's setting).
    static func format(_ date: Date, in zone: TimeZone) -> String {
        formatter.timeZone = zone
        return formatter.string(from: date)
    }
}

// MARK: - View (World tab)

struct WorldClockView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let clocks = model.worldClock
        let date = model.system.now.addingTimeInterval(clocks.offsetHours * 3600)
        VStack(alignment: .leading, spacing: 8) {
            // You (the Mac's time zone), big.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(WorldClockModel.city(TimeZone.current.identifier)) · \(WorldClockModel.abbreviation(.current, at: date))")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(TimeConversion.format(date, in: .current))
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }

            // Time travel: move every clock together.
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { clocks.offsetHours }, set: { clocks.offsetHours = ($0 * 2).rounded() / 2 }), in: -12...12)
                    .controlSize(.mini)
                    .tint(.cyan)
                Text(clocks.offsetHours == 0 ? "Now" : String(format: "%@%gh", clocks.offsetHours > 0 ? "+" : "−", abs(clocks.offsetHours)))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(clocks.offsetHours == 0 ? Color.secondary : Color.cyan)
                    .frame(width: 40, alignment: .trailing)
                if clocks.offsetHours != 0 {
                    IconButton(symbol: "arrow.uturn.backward", help: "Back to now") { clocks.offsetHours = 0 }
                }
            }

            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(clocks.zones, id: \.self) { id in
                        if let zone = TimeZone(identifier: id) {
                            ZoneRow(model: model, zone: zone, date: date)
                        }
                    }
                }
            }

            HStack {
                AddCityMenu(model: model)
                Spacer()
                Text("Copy a time like “3pm EST” to convert it")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ZoneRow: View {
    @ObservedObject var model: IslandModel
    let zone: TimeZone
    let date: Date
    @State private var hovering = false

    var body: some View {
        let diff = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        let calendar = Self.calendar(zone)
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let working = (9..<18).contains(hour) && !(weekday == 1 || weekday == 7)
        let dayShift = WorldClockModel.dayNumber(date, in: zone) - WorldClockModel.dayNumber(date, in: .current)

        HStack(spacing: 10) {
            Text((6..<18).contains(hour) ? "☀️" : "🌙").font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.worldClock.name(zone.identifier)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Circle().fill(working ? Color.green : .white.opacity(0.2)).frame(width: 5, height: 5)
                        .help(working ? "Work hours there" : "Outside work hours there")
                }
                Text("\(WorldClockModel.abbreviation(zone, at: date))\(WorldClockModel.country(zone.identifier).map { " · \($0)" } ?? "") · \(Self.offset(diff))\(dayShift > 0 ? " · tomorrow" : (dayShift < 0 ? " · yesterday" : ""))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hovering {
                HStack(spacing: 8) {
                    IconButton(symbol: "chevron.up", help: "Move up") { model.worldClock.move(zone.identifier, by: -1) }
                    IconButton(symbol: "xmark", help: "Remove") { model.worldClock.remove(zone.identifier) }
                }
                .transition(.opacity)
            }
            Text(TimeConversion.format(date, in: zone))
                .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .card(12)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    static func offset(_ seconds: Int) -> String {
        if seconds == 0 { return "same time" }
        let h = abs(seconds) / 3600, m = abs(seconds) % 3600 / 60
        let amount = m == 0 ? "\(h)h" : "\(h)h \(m)m"
        return seconds > 0 ? "\(amount) ahead" : "\(amount) behind"
    }
}

private struct AddCityMenu: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let clocks = model.worldClock
        Menu {
            Section("Popular") {
                ForEach(WorldClockModel.popular.filter { !clocks.zones.contains($0) && $0 != TimeZone.current.identifier }, id: \.self) { id in
                    Button(label(id)) { clocks.add(id) }
                }
            }
            Menu("By Country") {
                ForEach(WorldClockModel.countries, id: \.name) { country in
                    if country.zones.count == 1, let zone = country.zones.first {
                        Button("\(country.name)   \(time(zone.id))") { clocks.add(zone.id) }
                            .disabled(clocks.zones.contains(zone.id))
                    } else {
                        Menu(country.name) {
                            ForEach(country.zones, id: \.self) { zone in
                                Button("\(WorldClockModel.city(zone.id))\(zone.note.map { " (\($0))" } ?? "")   \(time(zone.id))") { clocks.add(zone.id) }
                                    .disabled(clocks.zones.contains(zone.id))
                            }
                        }
                    }
                }
            }
            Menu("Time Zones") {
                ForEach(WorldClockModel.standardZones, id: \.label) { item in
                    Button("\(item.label)   \(time(item.id))") { clocks.add(item.id, label: item.label.components(separatedBy: " (").first) }
                        .disabled(clocks.zones.contains(item.id))
                }
            }
        } label: {
            Label("Add city", systemImage: "plus").font(.system(size: 11.5, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(clocks.zones.count >= WorldClockModel.maxZones)
    }

    private func label(_ id: String) -> String {
        "\(WorldClockModel.city(id))\(WorldClockModel.country(id).map { ", \($0)" } ?? "")   \(time(id))"
    }

    private func time(_ id: String) -> String {
        TimeZone(identifier: id).map { TimeConversion.format(Date(), in: $0) } ?? ""
    }
}
