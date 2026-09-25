import AppKit

// MARK: - Media sources

enum Player: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var scriptName: String { self == .spotify ? "Spotify" : "Music" }
}

let chromeBundleID = "com.google.Chrome"

enum Source: Hashable {
    case app(Player)
    case chrome(window: Int, tab: Int)

    var bundleID: String {
        switch self {
        case .app(let player): return player.rawValue
        case .chrome: return chromeBundleID
        }
    }

    var appName: String {
        switch self {
        case .app(let player): return player.scriptName
        case .chrome: return "Chrome"
        }
    }
}

struct Track: Equatable, Identifiable {
    var source: Source
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkURL: URL?
    /// False when Chrome's "Allow JavaScript from Apple Events" is off.
    var canControl = true
    /// Seconds, as of `fetchedAt`.
    var position: Double = 0
    var duration: Double = 0
    var fetchedAt = Date()

    var id: Source { source }

    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(fetchedAt) : 0
        return duration > 0 ? min(duration, position + elapsed) : position + elapsed
    }
}

@discardableResult
func runAppleScript(_ source: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// JS run inside YouTube / YouTube Music tabs. Single quotes only — it is embedded in an AppleScript string.
enum YouTubeJS {
    static let state = """
    (function(){var v=document.querySelector('video');var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
    var a=(m&&m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'';\
    var t=(m&&m.title)||document.title.replace(/ - YouTube( Music)?$/,'').replace(/^[(][0-9]+[)] */,'');\
    var d=(v&&isFinite(v.duration))?Math.floor(v.duration):0;\
    return [(v&&!v.paused)?'playing':'paused',t,(m&&m.artist)||'',a,v?Math.floor(v.currentTime):0,d]\
    .join(String.fromCharCode(9));})()
    """
    static let playPause = "(function(){var v=document.querySelector('video');if(v){if(v.paused){v.play()}else{v.pause()}}})()"
    static let pause = "(function(){var v=document.querySelector('video');if(v)v.pause()})()"
    static let next = """
    (function(){var b=document.querySelector('ytmusic-player-bar .next-button')||document.querySelector('.ytp-next-button');if(b)b.click();})()
    """
    static let previous = """
    (function(){var v=document.querySelector('video');var b=document.querySelector('ytmusic-player-bar .previous-button');\
    if(b){b.click();return}if(v&&v.currentTime>3){v.currentTime=0}else{history.back()}})()
    """
    static func seek(_ seconds: Double) -> String {
        "(function(){var v=document.querySelector('video');if(v)v.currentTime=\(Int(seconds))})()"
    }
}

enum Command: Equatable {
    case playPause, pause, next, previous
    case seek(Double)
}

func chromeTabScript(window w: Int, tab t: Int, js: String) -> String {
    "tell application \"Google Chrome\" to tell window id \(w) to tell tab id \(t) to execute javascript \"\(js)\""
}

// MARK: - Model

final class MediaModel: ObservableObject {
    /// Every media source currently open (Music, Spotify, each YouTube tab).
    @Published var sources: [Track] = []
    /// The source the island is showing / controlling. Sticky: pausing doesn't move it elsewhere.
    @Published var selected: Source?

    /// Fired when a new song starts playing (drives the "now playing" pop-up).
    var onTrackChange: ((Track) -> Void)?

    var track: Track? { sources.first { $0.source == selected } }

    private var fetching = false
    private var lastPlaying: Set<Source> = []
    private var lastAnnounced: String?
    private var loadedOnce = false

    func refresh() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let players = Player.allCases.filter { running.contains($0.rawValue) }
        let chromeRunning = running.contains(chromeBundleID)
        guard !players.isEmpty || chromeRunning else { apply([]); return }
        guard !fetching else { return }
        fetching = true

        DispatchQueue.global(qos: .utility).async {
            var found: [Track] = []
            for player in players { found += Self.fetchApp(player) }
            if chromeRunning { found += Self.fetchChrome() }
            DispatchQueue.main.async {
                self.apply(found)
                self.fetching = false
            }
        }
    }

    /// Selection rules: jump to something that *just started* playing elsewhere; otherwise stay put.
    private func apply(_ found: [Track]) {
        sources = found
        let playing = Set(found.filter(\.isPlaying).map(\.source))
        let newlyPlaying = found.first { playing.contains($0.source) && !lastPlaying.contains($0.source) }
        lastPlaying = playing

        if let newlyPlaying {
            selected = newlyPlaying.source
        } else if track == nil {
            selected = found.first(where: \.isPlaying)?.source ?? found.first?.source
        }

        if let track, track.isPlaying {
            let key = "\(track.source)|\(track.title)"
            if loadedOnce, key != lastAnnounced { onTrackChange?(track) }
            lastAnnounced = key
        }
        loadedOnce = true
    }

    private static func fetchApp(_ player: Player) -> [Track] {
        let art = player == .spotify ? "(artwork url of current track)" : "\"\""
        // Spotify reports duration in ms, Music in seconds.
        let dur = player == .spotify ? "((duration of current track) / 1000)" : "(duration of current track)"
        let script = """
        tell application "\(player.scriptName)"
            set s to player state as string
            if s is "stopped" then return ""
            return s & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & \(art) \
        & linefeed & ((round (player position)) as text) & linefeed & ((round \(dur)) as text)
        end tell
        """
        guard let out = runAppleScript(script), !out.isEmpty else { return [] }
        let p = out.components(separatedBy: "\n")
        guard p.count >= 3 else { return [] }
        return [Track(source: .app(player), title: p[1], artist: p[2], isPlaying: p[0] == "playing",
                      artworkURL: p.count > 3 && !p[3].isEmpty ? URL(string: p[3]) : nil,
                      position: p.count > 4 ? Double(p[4]) ?? 0 : 0,
                      duration: p.count > 5 ? Double(p[5]) ?? 0 : 0)]
    }

    private static func fetchChrome() -> [Track] {
        let script = """
        set sep to ASCII character 9
        tell application "Google Chrome"
            set out to ""
            repeat with w in windows
                set wid to id of w
                repeat with t in tabs of w
                    set u to URL of t
                    if u contains "youtube.com/watch" or u contains "youtube.com/shorts" or u contains "music.youtube.com" then
                        try
                            set r to execute t javascript "\(YouTubeJS.state)"
                        on error
                            set r to "nojs" & sep & (title of t)
                        end try
                        set out to out & (wid as text) & sep & ((id of t) as text) & sep & r & linefeed
                    end if
                end repeat
            end repeat
            return out
        end tell
        """
        guard let out = runAppleScript(script), !out.isEmpty else { return [] }
        return out.components(separatedBy: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 4, let w = Int(f[0]), let t = Int(f[1]) else { return nil }
            let noJS = f[2] == "nojs"
            // Strip the " - YouTube" suffix and the "(441) " notification-count prefix.
            let title = f[3]
                .replacingOccurrences(of: #" - YouTube( Music)?$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            func field(_ i: Int) -> String { f.count > i ? f[i] : "" }
            return Track(source: .chrome(window: w, tab: t),
                         title: title,
                         artist: noJS || field(4).isEmpty ? "YouTube" : field(4),
                         isPlaying: f[2] == "playing",
                         artworkURL: field(5).isEmpty ? nil : URL(string: field(5)),
                         canControl: !noJS,
                         position: Double(field(6)) ?? 0,
                         duration: Double(field(7)) ?? 0)
        }
    }

    // MARK: Controls

    func send(_ command: Command, to target: Track? = nil) {
        guard let track = target ?? self.track, track.canControl else { return }
        selected = track.source

        var scripts = [Self.script(for: command, on: track.source)]
        // Only one thing plays at a time: starting this one pauses the others.
        if command == .playPause && !track.isPlaying {
            for other in sources where other.isPlaying && other.source != track.source {
                scripts.append(Self.script(for: .pause, on: other.source))
            }
        }
        optimisticUpdate(command, on: track.source)

        DispatchQueue.global(qos: .userInitiated).async {
            for script in scripts { runAppleScript(script) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
        }
    }

    private func optimisticUpdate(_ command: Command, on source: Source) {
        let now = Date()
        for i in sources.indices {
            sources[i].position = sources[i].position(at: now)
            sources[i].fetchedAt = now
            if sources[i].source == source {
                switch command {
                case .playPause: sources[i].isPlaying.toggle()
                case .pause: sources[i].isPlaying = false
                case .seek(let s): sources[i].position = s
                default: break
                }
            } else if command == .playPause && sources[i].isPlaying {
                sources[i].isPlaying = false
            }
        }
        lastPlaying = Set(sources.filter(\.isPlaying).map(\.source))
    }

    private static func script(for command: Command, on source: Source) -> String {
        switch source {
        case .app(let player):
            let verb: String
            switch command {
            case .playPause: verb = "playpause"
            case .pause: verb = "pause"
            case .next: verb = "next track"
            case .previous: verb = "previous track"
            case .seek(let s): verb = "set player position to \(Int(s))"
            }
            return "tell application \"\(player.scriptName)\" to \(verb)"
        case .chrome(let w, let t):
            let js: String
            switch command {
            case .playPause: js = YouTubeJS.playPause
            case .pause: js = YouTubeJS.pause
            case .next: js = YouTubeJS.next
            case .previous: js = YouTubeJS.previous
            case .seek(let s): js = YouTubeJS.seek(s)
            }
            return chromeTabScript(window: w, tab: t, js: js)
        }
    }

    /// Bring the app / Chrome tab to the front.
    func focus(_ track: Track) {
        switch track.source {
        case .app(let player):
            NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first?.activate()
        case .chrome(let w, let t):
            let script = """
            tell application "Google Chrome"
                set w to window id \(w)
                repeat with k from 1 to count of tabs of w
                    if id of tab k of w is \(t) then set active tab index of w to k
                end repeat
                set index of w to 1
                activate
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async { runAppleScript(script) }
        }
    }

    func icon(for source: Source) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)!
    }
}
