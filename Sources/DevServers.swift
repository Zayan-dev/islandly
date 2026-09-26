import AppKit
import Darwin
import SwiftUI

// MARK: - Dev servers: what your own processes are serving on local ports

struct DevServer: Identifiable, Equatable {
    let pid: Int32
    let port: Int
    let command: String
    /// "Django", "Vite", "PostgreSQL"… or the script that's running.
    let title: String
    /// Folder the process was started from.
    let folder: String
    let isWeb: Bool
    let canStop: Bool
    /// Listening on all interfaces (not just 127.0.0.1), so a phone on the same Wi-Fi can reach it.
    var onNetwork = false

    var id: String { "\(pid):\(port)" }
    /// Chip-sized name: "Next.js", "Django", or the project folder for generic servers.
    var shortName: String {
        if title.count <= 10 { return title }
        let project = (folder as NSString).lastPathComponent
        return String((project.isEmpty ? title : project).prefix(14))
    }
    var url: URL? { isWeb ? URL(string: "http://localhost:\(port)") : nil }
}

final class DevServerModel: ObservableObject {
    @Published private(set) var servers: [DevServer] = []
    @Published private(set) var loaded = false
    /// pid → when SIGTERM was sent; still listening a few seconds later offers Force Quit.
    @Published private(set) var stopping: [Int32: Date] = [:]
    /// Server whose "open on phone" QR code is showing.
    @Published private(set) var phone: PhoneLink?

    struct PhoneLink: Equatable {
        let server: DevServer
        /// nil when there's no Wi-Fi / Ethernet address.
        let url: URL?
        let qr: NSImage?
    }

    func showPhone(_ server: DevServer) {
        let url = Self.lanAddress().flatMap { URL(string: "http://\($0):\(server.port)") }
        phone = PhoneLink(server: server, url: url, qr: url.flatMap { ScreenTools.qrImage(for: $0.absoluteString) })
    }

    func hidePhone() { phone = nil }

    /// This Mac's private IPv4 address on Wi-Fi / Ethernet (e.g. 192.168.1.5).
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }  // skip VPN tunnels, bridges, Docker
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.range(of: #"^172\.(1[6-9]|2\d|3[01])\."#, options: .regularExpression) != nil
            else { continue }
            candidates.append((name, ip))
        }
        return candidates.sorted { $0.name < $1.name }.first?.ip
    }

    private var busy = false

    /// Runs lsof off the main thread; called only while the Dev tab is on screen.
    func refresh() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let found = Self.scan()
            DispatchQueue.main.async {
                self.busy = false
                self.loaded = true
                if found != self.servers { self.servers = found }
                let alive = Set(found.map(\.pid))
                self.stopping = self.stopping.filter { alive.contains($0.key) }
                if let phone = self.phone {
                    if let fresh = found.first(where: { $0.id == phone.server.id }) {
                        if fresh.onNetwork != phone.server.onNetwork { self.showPhone(fresh) }
                    } else {
                        self.phone = nil
                    }
                }
            }
        }
    }

    func open(_ server: DevServer) {
        if let url = server.url { NSWorkspace.shared.open(url) }
    }

    /// Only ever our own processes: the scan is limited to the current user, and kill() refuses anything else.
    func stop(_ server: DevServer, force: Bool = false) {
        guard server.canStop, Self.stillSame(server) else { refresh(); return }
        kill(server.pid, force ? SIGKILL : SIGTERM)
        if !force { stopping[server.pid] = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
    }

    /// The pid still belongs to the same program (guards against the OS reusing the number after it exited).
    private static func stillSame(_ server: DevServer) -> Bool {
        var name = [CChar](repeating: 0, count: 256)
        guard proc_name(server.pid, &name, UInt32(name.count)) > 0 else { return false }
        let current = String(cString: name)
        return !current.isEmpty && (server.command.hasPrefix(current) || current.hasPrefix(server.command))
    }

    func isStuck(_ server: DevServer, now: Date) -> Bool {
        stopping[server.pid].map { now.timeIntervalSince($0) > 3 } ?? false
    }

    // MARK: Scanning

    private static func scan() -> [DevServer] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(getuid())", "-F", "pcn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var pid: Int32 = 0
        var command = ""
        var result: [DevServer] = []
        var index: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]), pid > 0 else { continue }
                let host = String(value[..<colon])
                let loopback = host.hasPrefix("127.") || host == "[::1]" || host == "localhost"
                let key = "\(pid):\(port)"
                if let i = index[key] {
                    if !loopback { result[i].onNetwork = true }  // same server, IPv4 + IPv6 sockets
                    continue
                }
                guard var server = describe(pid: pid, port: port, command: command) else { continue }
                server.onNetwork = !loopback
                index[key] = result.count
                result.append(server)
            default: break
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// Everyday apps that listen on local ports but aren't "your" servers.
    private static let ignoredApps = ["ControlCenter", "rapportd", "Spotify", "Dropbox", "Raycast", "Slack", "Discord",
                                      "zoom.us", "Figma", "Adobe", "Creative Cloud", "Code Helper", "Cursor", "Electron",
                                      "Google Chrome", "Chrome", "Microsoft", "Teams", "OneDrive", "Islandly", "WhatsApp",
                                      "Notion", "sharingd", "logioptionsplus", "Claude", "1Password", "Arc", "Brave",
                                      "Firefox", "Safari", "Postman", "Docker Desktop", "LM Studio", "ollama", "Antigravity",
                                      "Windsurf", "Zed", "JetBrains", "idea", "pycharm", "webstorm", "Xcode"]
    private static let devCommands = ["python", "node", "ruby", "php", "java", "bun", "deno", "go", "dotnet", "uvicorn",
                                      "gunicorn", "daphne", "hypercorn", "postgres", "mysqld", "mariadbd", "mongod", "redis-server",
                                      "ssh", "nginx", "httpd", "caddy", "hugo", "beam.smp", "puma", "com.docker.backend", "vpnkit"]

    private static func describe(pid: Int32, port: Int, command: String) -> DevServer? {
        let lower = command.lowercased()
        // 49152+ is the range the OS hands out at random: editor helpers, language servers, app internals.
        // Real dev servers pick a fixed, lower port.
        guard port < 49152, !lower.contains("helper") else { return nil }
        let isDev = devCommands.contains { lower == $0 || lower.hasPrefix($0) }
        if !isDev, ignoredApps.contains(where: { lower.hasPrefix($0.lowercased()) }) { return nil }
        let args = arguments(of: pid)
        let joined = args.joined(separator: " ").lowercased()

        var title: String
        var isWeb = true
        var canStop = true
        switch true {
        case lower.hasPrefix("postgres"): title = "PostgreSQL"; isWeb = false
        case lower.hasPrefix("mysqld"), lower.hasPrefix("mariadbd"): title = "MySQL"; isWeb = false
        case lower.hasPrefix("mongod"): title = "MongoDB"; isWeb = false
        case lower.hasPrefix("redis"): title = "Redis"; isWeb = false
        case lower == "ssh": title = "SSH tunnel"; isWeb = false
        case lower.hasPrefix("com.docker"), lower == "vpnkit": title = "Docker container"; canStop = false
        case joined.contains("manage.py") && joined.contains("runserver"): title = "Django"
        case joined.contains("uvicorn"): title = "Uvicorn"
        case joined.contains("gunicorn"): title = "Gunicorn"
        case joined.contains("daphne"): title = "Daphne"
        case joined.contains("flask"): title = "Flask"
        case joined.contains("http.server"): title = "Python file server"
        case joined.contains("next"): title = "Next.js"
        case joined.contains("vite"): title = "Vite"
        case joined.contains("react-scripts"): title = "React"
        case joined.contains("webpack"): title = "webpack"
        case joined.contains("expo"), joined.contains("metro"): title = "Expo / Metro"
        case joined.contains("rails"), lower == "puma": title = "Rails"
        default: title = scriptLabel(args) ?? command
        }
        if [5432, 3306, 3307, 3308, 6379, 27017].contains(port), title == command { isWeb = false }
        return DevServer(pid: pid, port: port, command: command, title: title,
                         folder: workingFolder(of: pid), isWeb: isWeb, canStop: canStop)
    }

    /// "node /x/y/server.js --port 3000" → "server.js"
    private static func scriptLabel(_ args: [String]) -> String? {
        args.dropFirst().first { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Command-line arguments of one of our processes (KERN_PROCARGS2).
    private static func arguments(of pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }  // executable path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private static func workingFolder(of pid: Int32) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path == "/" ? "" : (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Views

struct DevServersView: View {
    @ObservedObject var model: IslandModel
    @State private var confirmStop: String?

    var body: some View {
        let dev = model.devServers
        if let phone = dev.phone {
            PhonePanel(link: phone) { dev.hidePhone() }
                .transition(.opacity)
        } else {
            list(dev)
        }
    }

    private func list(_ dev: DevServerModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: dev.servers.isEmpty ? "Dev servers" : "Dev servers · \(dev.servers.count)")
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { dev.refresh() }
            }
            if dev.servers.isEmpty {
                Text(dev.loaded ? "Nothing is listening right now.\nStart a server (runserver, npm run dev…) and it shows up here."
                                : "Looking for local servers…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(dev.servers) { server in row(server, dev) }
                    }
                }
            }
        }
        .onAppear { dev.refresh() }
    }

    private func row(_ server: DevServer, _ dev: DevServerModel) -> some View {
        let stopping = dev.stopping[server.pid] != nil
        let stuck = dev.isStuck(server, now: model.system.now)
        return HStack(spacing: 10) {
            Circle()
                .fill(stopping ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
                .shadow(color: (stopping ? Color.orange : Color.green).opacity(0.7), radius: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(server.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(":\(String(server.port))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
                Text([server.folder, "\(server.command) · pid \(server.pid)"].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            if server.isWeb {
                IconButton(symbol: "iphone", help: "Open on phone") { Haptics.tap(); dev.showPhone(server) }
                IconButton(symbol: "arrow.up.right.square", help: "Open in browser") { dev.open(server) }
            }
            if server.canStop {
                if stuck {
                    stopButton("Force quit", tint: .red) { dev.stop(server, force: true) }
                } else if stopping {
                    ProgressView().controlSize(.mini).tint(.white).frame(width: 22)
                } else if confirmStop == server.id {
                    stopButton("Stop?", tint: .red) {
                        Haptics.tap()
                        confirmStop = nil
                        dev.stop(server)
                    }
                } else {
                    IconButton(symbol: "stop.circle", help: "Stop") {
                        confirmStop = server.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if confirmStop == server.id { confirmStop = nil }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .card(12)
    }

    private func stopButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.35)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }
}

struct PhonePanel: View {
    let link: DevServerModel.PhoneLink
    let onClose: () -> Void

    var body: some View {
        let server = link.server
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "Open on phone · \(server.title)")
                Spacer()
                IconButton(symbol: "xmark", help: "Back", action: onClose)
            }
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if server.onNetwork, let qr = link.qr {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay(Image(systemName: server.onNetwork ? "wifi.slash" : "lock.fill")
                                .font(.system(size: 28)).foregroundStyle(.secondary))
                    }
                }
                .frame(width: 122, height: 122)

                VStack(alignment: .leading, spacing: 6) {
                    if !server.onNetwork {
                        Text("Only this Mac can reach it").font(.system(size: 12, weight: .semibold))
                        Text("The server is listening on localhost. Restart it on all interfaces:")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.restartHint(for: server))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07)))
                            .lineLimit(2)
                    } else if let url = link.url {
                        Text("Scan with your phone's camera").font(.system(size: 12, weight: .semibold))
                        Text(url.absoluteString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .textSelection(.enabled)
                        Text("Your phone must be on the same Wi-Fi. If it doesn't load, check the Mac's firewall\(server.title == "Django" ? " and ALLOWED_HOSTS" : "").")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Not on a network").font(.system(size: 12, weight: .semibold))
                        Text("Connect this Mac to Wi-Fi so your phone can reach it.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: 122)
            }
        }
    }

    static func restartHint(for server: DevServer) -> String {
        switch server.title {
        case "Django": return "manage.py runserver 0.0.0.0:\(server.port)"
        case "Vite": return "npm run dev -- --host"
        case "Next.js": return "next dev -H 0.0.0.0"
        case "Uvicorn": return "uvicorn app:app --host 0.0.0.0"
        case "Flask": return "flask run --host 0.0.0.0"
        case "Python file server": return "python3 -m http.server \(server.port) --bind 0.0.0.0"
        default: return "bind to 0.0.0.0 instead of 127.0.0.1"
        }
    }
}
