import AppKit
import Network
import SwiftUI

/// The Phone panel's three modes (one tile, no clutter on Home).
enum PhoneMode: String, CaseIterable {
    case send, receive, sign

    var label: String {
        switch self {
        case .send: return "Send"
        case .receive: return "Receive"
        case .sign: return "Sign"
        }
    }

    var symbol: String {
        switch self {
        case .send: return "arrow.up.forward"
        case .receive: return "arrow.down.backward"
        case .sign: return "signature"
        }
    }
}

// MARK: - Receive: a tiny upload page on this Mac that your phone opens by QR

/// Serves one page on the local network while the Receive mode is on. The URL carries a random
/// one-time key, every other path gets 404, and it shuts itself down after 10 idle minutes.
final class PhoneReceiver: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var qr: NSImage?
    @Published private(set) var problem: String?
    @Published private(set) var received: [String] = []
    /// Texts sent from the phone. Never copied automatically: you see them first, then click Copy.
    @Published private(set) var texts: [String] = []
    /// The phone this link is locked to (the first device that used it).
    @Published private(set) var pairedHost: String?
    /// Bytes arrived / expected for the upload in progress (nil when idle).
    @Published private(set) var progress: (done: Int64, total: Int64)?

    /// Latest signature drawn on the phone (transparent PNG, already on the clipboard).
    @Published private(set) var signature: NSImage?
    /// Which page the phone gets: the upload page or the signing pad. Same link, same paired phone.
    var page: ReceivePage = .upload { didSet { gate?.page = page } }

    var isRunning: Bool { listener != nil }
    var onFile: ((URL) -> Void)?
    var onText: ((String) -> Void)?
    var onSignature: ((URL) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: UploadConnection] = [:]
    private var gate: ReceiveGate?
    private var idleTimer: Timer?
    private let queue = DispatchQueue(label: "islandly.receiver")
    static let maxFileBytes: Int64 = 2 << 30  // 2 GB per file
    static let idleLimit: TimeInterval = 600

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Islandly", isDirectory: true)
    }

    func start() {
        guard listener == nil else { return }
        problem = nil
        guard let ip = DevServerModel.lanAddress() else {
            problem = "Connect this Mac to Wi-Fi first."
            return
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            problem = "Couldn't create a secure link."
            return
        }
        let gate = ReceiveGate(token: bytes.map { String(format: "%02x", $0) }.joined())
        gate.page = page
        gate.onPaired = { [weak self] host in DispatchQueue.main.async { self?.pairedHost = host } }
        gate.onActivity = { [weak self] in DispatchQueue.main.async { self?.touch() } }
        self.gate = gate
        pairedHost = nil

        // Bound to this Mac's Wi-Fi/Ethernet address only: not reachable over VPN tunnels or other interfaces.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch {
            problem = "Couldn't open a port on this Mac."
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    let url = URL(string: "http://\(ip):\(port)/\(gate.token)")
                    self.url = url
                    self.qr = url.flatMap { ScreenTools.qrImage(for: $0.absoluteString) }
                case .failed:
                    self.problem = "The receiver stopped. Switch modes to restart it."
                    self.stop()
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        touch()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        gate = nil
        pairedHost = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
        url = nil
        qr = nil
        progress = nil
    }

    func clearReceived() { received.removeAll() }

    /// Decodes and re-encodes the drawing (so only clean pixels survive), saves it, and puts it on the clipboard.
    private func acceptSignature(_ data: Data) {
        // Check the PNG header's size before handing anything to the image decoder.
        guard data.count > 24, data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return }
        let width = data[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = data[20..<24].reduce(0) { $0 << 8 | Int($1) }
        guard (1...4096).contains(width), (1...4096).contains(height) else { return }
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), rep.pixelsWide <= 4096, rep.pixelsHigh <= 4096,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let url = UploadConnection.uniqueURL(in: Self.folder, name: "Signature \(stamp).png")
        guard (try? png.write(to: url)) != nil else { return }
        let clean = NSImage(data: png) ?? image
        clean.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)  // drawn at 2x
        signature = clean
        copySignature()
        onSignature?(url)
    }

    /// Clipboard gets PNG (keeps transparency in Preview, Docs, Figma) plus TIFF for older apps.
    func copySignature() {
        guard let signature, let tiff = signature.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
        board.setData(tiff, forType: .tiff)
    }

    func clearSignature() { signature = nil }

    /// Copy (or with nil, just dismiss) a text the phone sent.
    func copyText(_ text: String, into clipboard: ClipboardModel?) {
        clipboard?.copy(text)
        texts.removeAll { $0 == text }
    }

    /// Closes the link after 10 minutes without any request, even if Receive is still showing.
    private func touch() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleLimit, repeats: false) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.stop()
            self.problem = "The link closed after 10 quiet minutes, so nobody else can use it."
        }
    }

    private func accept(_ connection: NWConnection) {
        DispatchQueue.main.async {
            guard self.listener != nil, let gate = self.gate, self.connections.count < 6 else { connection.cancel(); return }
            let upload = UploadConnection(connection: connection, gate: gate, queue: self.queue)
            let id = ObjectIdentifier(upload)
            upload.onDone = { [weak self] in DispatchQueue.main.async { self?.connections[id] = nil } }
            upload.onProgress = { [weak self] done, total in
                DispatchQueue.main.async { self?.progress = done < total ? (done, total) : nil }
            }
            upload.onFile = { [weak self] url in
                DispatchQueue.main.async {
                    self?.received.insert(url.lastPathComponent, at: 0)
                    self?.progress = nil
                    self?.onFile?(url)
                }
            }
            upload.onSignature = { [weak self] data in
                DispatchQueue.main.async { self?.acceptSignature(data) }
            }
            upload.onText = { [weak self] text in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.texts.removeAll { $0 == text }
                    self.texts.insert(text, at: 0)
                    if self.texts.count > 5 { self.texts.removeLast() }
                    self.onText?(text)
                }
            }
            self.connections[id] = upload
            upload.start()
        }
    }
}

enum ReceivePage { case upload, sign }

/// Shared rules for one Receive session, checked from the network queue.
final class ReceiveGate {
    let token: String
    var onPaired: ((String) -> Void)?
    var onActivity: (() -> Void)?

    private let lock = NSLock()
    private var pinnedHost: String?
    private var bytesReserved: Int64 = 0
    private var files = 0
    static let maxSessionBytes: Int64 = 5 << 30  // 5 GB per session
    static let maxSessionFiles = 200

    init(token: String) { self.token = token }

    private var _page: ReceivePage = .upload
    var page: ReceivePage {
        get { lock.lock(); defer { lock.unlock() }; return _page }
        set { lock.lock(); _page = newValue; lock.unlock() }
    }

    /// Locks the link to the first device that uses it; anyone else gets 404 even with the link.
    func allow(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let pinnedHost { return pinnedHost == host }
        pinnedHost = host
        onPaired?(host)
        return true
    }

    func reserve(bytes: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard files < Self.maxSessionFiles, bytesReserved + bytes <= Self.maxSessionBytes else { return false }
        files += 1
        bytesReserved += bytes
        return true
    }
}

/// One HTTP/1.1 request, parsed by hand (GET the page, POST a file or text). Streams file bodies to disk.
final class UploadConnection {
    var onDone: (() -> Void)?
    var onProgress: ((Int64, Int64) -> Void)?
    var onFile: ((URL) -> Void)?
    var onText: ((String) -> Void)?
    var onSignature: ((Data) -> Void)?

    private let connection: NWConnection
    private let gate: ReceiveGate
    private let queue: DispatchQueue
    private var watchdog: DispatchWorkItem?
    private var lastProgress = Date.distantPast
    private var header = Data()
    private var body = Data()
    private var expected: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var file: FileHandle?
    private var partURL: URL?
    private var finalURL: URL?
    private var isText = false
    private var isSignature = false
    private var finished = false

    init(connection: NWConnection, gate: ReceiveGate, queue: DispatchQueue) {
        self.connection = connection
        self.gate = gate
        self.queue = queue
    }

    private var remoteHost: String {
        guard case .hostPort(let host, _) = connection.endpoint else { return "" }
        let text = "\(host)"
        return text.components(separatedBy: "%").first ?? text  // drop an interface suffix
    }

    func start() {
        connection.start(queue: queue)
        armWatchdog()
        receive()
    }

    /// Drops connections that go quiet for 30 s, so a stalled client can't hold a slot forever.
    private func armWatchdog() {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.cancel()
            self?.onDone?()
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + 30, execute: item)
    }

    func cancel() {
        watchdog?.cancel()
        cleanupPartial()
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.armWatchdog()
                self.consume(data)
            }
            if error != nil || (complete && self.expected > self.receivedBytes) {
                self.cancel()
                self.onDone?()
            } else if !complete {
                self.receive()
            }
        }
    }

    private func consume(_ data: Data) {
        guard !finished else { return }
        if finalURL == nil && !isText && !isSignature && expected == 0 {
            header.append(data)
            guard header.count < 16 * 1024 else { return respond(431, "Too large") }
            guard let end = header.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: header[..<end.lowerBound], as: UTF8.self)
            let rest = header[end.upperBound...]
            route(head, rest: Data(rest))
        } else {
            write(data)
        }
    }

    private func route(_ head: String, rest: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return respond(400, "Bad request") }
        let method = String(parts[0])
        guard let components = URLComponents(string: String(parts[1])) else { return respond(400, "Bad request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = components.path
        let length = Int64(headers["content-length"] ?? "") ?? -1
        let token = gate.token
        // Right key, but from a different device than the paired phone: pretend it doesn't exist.
        guard path == "/\(token)" || path.hasPrefix("/\(token)/") else { return respond(404, "Not found") }
        guard gate.allow(remoteHost) else { return respond(404, "Not found") }
        gate.onActivity?()

        switch (method, path) {
        case ("GET", "/\(token)"), ("GET", "/\(token)/"):
            respond(200, gate.page == .sign ? SignPage.html : PhonePage.html, type: "text/html; charset=utf-8")
        case ("POST", "/\(token)/sign"):
            // Only while the Mac is in Sign mode; PNG only; a signature is small.
            guard gate.page == .sign, length > 8, length <= 8_000_000 else { return respond(413, "Too large") }
            isSignature = true
            expected = length
            write(rest)
        case ("POST", "/\(token)/text"):
            guard length >= 0, length <= 100_000 else { return respond(413, "Too large") }
            isText = true
            expected = length
            write(rest)
        case ("POST", "/\(token)/file"):
            guard length > 0, length <= PhoneReceiver.maxFileBytes, gate.reserve(bytes: length) else { return respond(413, "Too large") }
            let name = Self.safeName(components.queryItems?.first { $0.name == "name" }?.value)
            let destination = Self.uniqueURL(in: PhoneReceiver.folder, name: name)
            let part = destination.appendingPathExtension("part")
            guard FileManager.default.createFile(atPath: part.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: part) else { return respond(500, "Can't save") }
            file = handle
            partURL = part
            finalURL = destination
            expected = length
            write(rest)
        default:
            respond(404, "Not found")
        }
    }

    private func write(_ data: Data) {
        guard !data.isEmpty || expected == 0 else { return }
        let room = Int(max(0, expected - receivedBytes))
        let chunk = data.prefix(room)
        receivedBytes += Int64(chunk.count)
        if isText || isSignature {
            body.append(chunk)
        } else if let file {
            do { try file.write(contentsOf: chunk) } catch { return respond(500, "Disk error") }
            // At most ~10 progress updates a second, however fast the bytes arrive.
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 0.1 || receivedBytes >= expected {
                lastProgress = now
                onProgress?(receivedBytes, expected)
            }
        }
        guard receivedBytes >= expected else { return }

        if isSignature {
            guard body.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return respond(400, "Not a PNG") }
            onSignature?(body)
            respond(200, "ok")
        } else if isText {
            let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { onText?(text) }
            respond(200, "ok")
        } else if let file, let partURL, let finalURL {
            try? file.close()
            self.file = nil
            do {
                try FileManager.default.moveItem(at: partURL, to: finalURL)
                self.partURL = nil
                Self.quarantine(finalURL)
                onFile?(finalURL)
                respond(200, "ok")
            } catch {
                respond(500, "Can't save")
            }
        }
    }

    private func respond(_ code: Int, _ text: String, type: String = "text/plain; charset=utf-8") {
        let status = [200: "OK", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large",
                      431: "Request Header Fields Too Large", 500: "Internal Server Error"][code] ?? "Error"
        let body = Data(text.utf8)
        var head = "HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        guard !finished else { return }
        finished = true
        if code != 200 { cleanupPartial() }
        watchdog?.cancel()
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.onDone?()
        })
    }

    private func cleanupPartial() {
        try? file?.close()
        file = nil
        if let partURL { try? FileManager.default.removeItem(at: partURL) }
        partURL = nil
    }

    /// Marks the file like a browser download, so macOS checks it (Gatekeeper) before an app or script from it runs.
    static func quarantine(_ url: URL) {
        let value = String(format: "0081;%08x;Islandly;%@", Int(Date().timeIntervalSince1970), UUID().uuidString)
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }

    /// Phone-supplied names can't escape the folder: last path component only, no leading dots or odd characters.
    static func safeName(_ raw: String?) -> String {
        let base = (raw ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        let cleaned = base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        var name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "phone-\(Int(Date().timeIntervalSince1970))" }
        return String(name.prefix(120))
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: url.path + ".part") {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

/// The page the phone sees. Plain HTML + JS, no external resources.
private enum PhonePage {
    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <title>Send to Mac · Islandly</title>
    <style>
    :root{color-scheme:dark}*{box-sizing:border-box}
    body{margin:0;min-height:100vh;background:radial-gradient(120% 60% at 50% 0%,#1d2a3a,#07080b 70%);color:#f2f4f7;
    font:16px/1.4 -apple-system,system-ui,Roboto,sans-serif;display:flex;flex-direction:column;align-items:center;padding:32px 20px}
    .pill{width:120px;height:34px;border-radius:20px;background:#000;box-shadow:0 0 0 1px #ffffff1a,0 10px 30px #0008;margin-bottom:22px}
    h1{font-size:24px;margin:0 0 6px}p{margin:0 0 26px;color:#9aa4b2;text-align:center}
    .card{width:100%;max-width:420px;background:#ffffff0d;border:1px solid #ffffff14;border-radius:22px;padding:18px;margin-bottom:14px}
    label.big{display:flex;align-items:center;justify-content:center;gap:10px;height:64px;border-radius:16px;
    background:linear-gradient(180deg,#2ec4b6,#1a9e93);color:#fff;font-weight:600;font-size:18px}
    input[type=file]{display:none}
    textarea{width:100%;min-height:90px;border-radius:14px;border:1px solid #ffffff1f;background:#0006;color:#fff;padding:12px;font:inherit;resize:vertical}
    button{margin-top:10px;width:100%;height:48px;border:0;border-radius:14px;background:#ffffff1f;color:#fff;font:600 16px system-ui}
    .bar{height:6px;border-radius:3px;background:#ffffff14;overflow:hidden;margin-top:14px;display:none}
    .bar i{display:block;height:100%;width:0;background:#2ec4b6;transition:width .15s}
    ul{list-style:none;padding:0;margin:8px 0 0}li{padding:8px 0;border-top:1px solid #ffffff10;color:#c9d1db;font-size:14px}
    li:first-child{border:0}.ok{color:#2ec4b6}.err{color:#ff6b6b}
    </style></head><body>
    <div class="pill"></div><h1>Send to your Mac</h1><p>Files land on the Islandly shelf and in Downloads&nbsp;▸&nbsp;Islandly.</p>
    <div class="card"><label class="big">＋ Choose photos or files<input id="f" type="file" multiple></label>
    <div class="bar" id="bar"><i id="fill"></i></div><ul id="log"></ul></div>
    <div class="card"><textarea id="t" placeholder="Or type / paste text… it goes to the Mac's clipboard"></textarea>
    <button id="send">Send text</button></div>
    <script>
    const base=location.pathname.replace(/\\/$/,''),log=document.getElementById('log'),bar=document.getElementById('bar'),fill=document.getElementById('fill');
    function note(t,c){const li=document.createElement('li');li.textContent=t;if(c)li.className=c;log.prepend(li)}
    function up(file){return new Promise(r=>{const x=new XMLHttpRequest();x.open('POST',base+'/file?name='+encodeURIComponent(file.name));
    x.upload.onprogress=e=>{if(e.lengthComputable)fill.style.width=(e.loaded/e.total*100)+'%'};
    x.onload=()=>{note((x.status==200?'✓ ':'✕ ')+file.name,x.status==200?'ok':'err');r()};
    x.onerror=()=>{note('✕ '+file.name+' (Mac not reachable)','err');r()};x.send(file)})}
    document.getElementById('f').onchange=async e=>{bar.style.display='block';for(const f of e.target.files){fill.style.width='0';await up(f)}
    bar.style.display='none';e.target.value=''};
    document.getElementById('send').onclick=async()=>{const t=document.getElementById('t');if(!t.value.trim())return;
    try{const r=await fetch(base+'/text',{method:'POST',body:t.value});note(r.ok?'✓ Text sent':'✕ Text failed',r.ok?'ok':'err');if(r.ok)t.value=''}
    catch(e){note('✕ Mac not reachable','err')}};
    </script></body></html>
    """
}

/// The signing pad. Smooth, pressure-like strokes (width follows speed), exported as a tight transparent PNG at 2x.
private enum SignPage {
    static let html = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
    <title>Sign · Islandly</title>
    <style>
    :root{color-scheme:dark}*{box-sizing:border-box;-webkit-user-select:none;user-select:none}
    html,body{margin:0;height:100%;overscroll-behavior:none}
    body{background:radial-gradient(120% 60% at 50% 0%,#1d2a3a,#07080b 70%);color:#f2f4f7;
    font:16px/1.4 -apple-system,system-ui,Roboto,sans-serif;display:flex;flex-direction:column;padding:18px 16px calc(16px + env(safe-area-inset-bottom))}
    header{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}
    h1{font-size:20px;margin:0}.sw{display:flex;gap:10px}
    .sw button{width:30px;height:30px;border-radius:50%;border:2px solid #ffffff30;padding:0}
    .sw button.on{border-color:#fff;box-shadow:0 0 0 3px #2ec4b666}
    .pad{position:relative;flex:1;min-height:200px;background:#fff;border-radius:22px;overflow:hidden;box-shadow:0 20px 50px #0009}
    canvas{position:absolute;inset:0;width:100%;height:100%;touch-action:none}
    .line{position:absolute;left:8%;right:8%;bottom:28%;border-bottom:2px solid #d9dde3;pointer-events:none}
    .x{position:absolute;left:8%;bottom:calc(28% + 6px);color:#b4bac4;font:600 22px system-ui;pointer-events:none}
    .hint{position:absolute;width:100%;top:40%;text-align:center;color:#b4bac4;pointer-events:none;transition:opacity .2s}
    .row{display:flex;gap:10px;margin-top:14px}
    .row button{height:54px;border:0;border-radius:16px;font:600 16px system-ui;color:#fff;background:#ffffff1c;flex:1}
    .row .send{flex:2;background:linear-gradient(180deg,#2ec4b6,#1a9e93)}.row .send:disabled{opacity:.4}
    #msg{text-align:center;height:22px;margin-top:10px;color:#9aa4b2;font-size:14px}.ok{color:#2ec4b6!important}.err{color:#ff6b6b!important}
    </style></head><body>
    <header><h1>Sign for your Mac</h1><div class="sw"><button class="on" data-c="#111418" style="background:#111418"></button>
    <button data-c="#1d3fae" style="background:#1d3fae"></button></div></header>
    <div class="pad"><div class="line"></div><div class="x">✕</div><div class="hint" id="hint">Sign here with your finger</div><canvas id="c"></canvas></div>
    <div class="row"><button id="undo">Undo</button><button id="clear">Clear</button><button class="send" id="send" disabled>Send to Mac</button></div>
    <div id="msg"></div>
    <script>
    const cv=document.getElementById('c'),ctx=cv.getContext('2d'),hint=document.getElementById('hint'),sendB=document.getElementById('send'),msg=document.getElementById('msg');
    const base=location.pathname.replace(/\\/$/,'');let strokes=[],cur=null,color='#111418';
    function fit(){const r=cv.getBoundingClientRect(),d=devicePixelRatio||1;cv.width=r.width*d;cv.height=r.height*d;ctx.setTransform(d,0,0,d,0,0);draw(ctx,0,0)}
    addEventListener('resize',fit);
    function seg(g,a,b,c,col){g.strokeStyle=col;g.lineCap='round';g.lineJoin='round';g.lineWidth=(a.w+c.w)/2;
      g.beginPath();g.moveTo((a.x+b.x)/2,(a.y+b.y)/2);g.quadraticCurveTo(b.x,b.y,(b.x+c.x)/2,(b.y+c.y)/2);g.stroke()}
    function strokeDraw(g,s,dx,dy){const p=s.pts.map(q=>({x:q.x-dx,y:q.y-dy,w:q.w}));if(p.length==1){g.fillStyle=s.c;g.beginPath();g.arc(p[0].x,p[0].y,p[0].w/2,0,7);g.fill();return}
      p.unshift(p[0]);p.push(p[p.length-1]);for(let i=1;i<p.length-1;i++)seg(g,p[i-1],p[i],p[i+1],s.c)}
    function draw(g,dx,dy){g.clearRect(0,0,cv.width,cv.height);for(const s of strokes)strokeDraw(g,s,dx,dy);
      hint.style.opacity=strokes.length?0:1;sendB.disabled=!strokes.length}
    function pt(e){const r=cv.getBoundingClientRect();return{x:e.clientX-r.left,y:e.clientY-r.top,t:performance.now()}}
    cv.onpointerdown=e=>{cv.setPointerCapture(e.pointerId);const p=pt(e);p.w=3.2;cur={c:color,pts:[p]};strokes.push(cur);draw(ctx,0,0)};
    cv.onpointermove=e=>{if(!cur)return;const evs=e.getCoalescedEvents?e.getCoalescedEvents():[e];for(const ev of evs){const p=pt(ev),l=cur.pts[cur.pts.length-1];
      const d=Math.hypot(p.x-l.x,p.y-l.y);if(d<1.2)continue;const v=d/Math.max(1,p.t-l.t);p.w=l.w*0.6+Math.max(1.3,Math.min(4.2,4.4-v*1.6))*0.4;cur.pts.push(p)}draw(ctx,0,0)};
    cv.onpointerup=cv.onpointercancel=()=>{cur=null};
    document.getElementById('undo').onclick=()=>{strokes.pop();draw(ctx,0,0)};
    document.getElementById('clear').onclick=()=>{strokes=[];draw(ctx,0,0);msg.textContent=''};
    document.querySelectorAll('.sw button').forEach(b=>b.onclick=()=>{document.querySelectorAll('.sw button').forEach(x=>x.classList.remove('on'));b.classList.add('on');color=b.dataset.c});
    sendB.onclick=async()=>{let x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;for(const s of strokes)for(const p of s.pts){x0=Math.min(x0,p.x-p.w);y0=Math.min(y0,p.y-p.w);x1=Math.max(x1,p.x+p.w);y1=Math.max(y1,p.y+p.w)}
      const pad=10,S=2,o=document.createElement('canvas');o.width=Math.ceil((x1-x0+pad*2)*S);o.height=Math.ceil((y1-y0+pad*2)*S);
      const g=o.getContext('2d');g.setTransform(S,0,0,S,0,0);for(const s of strokes)strokeDraw(g,s,x0-pad,y0-pad);
      msg.className='';msg.textContent='Sending…';
      o.toBlob(async b=>{try{const r=await fetch(base+'/sign',{method:'POST',body:b});
        if(r.ok){msg.className='ok';msg.textContent='✓ On your Mac’s clipboard. Paste with ⌘V'}else{msg.className='err';msg.textContent='✕ The Mac refused it (is Sign still open?)'}}
        catch(e){msg.className='err';msg.textContent='✕ Mac not reachable'}},'image/png')};
    fit();
    </script></body></html>
    """
}

// MARK: - Views

struct PhoneModePicker: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PhoneMode.allCases, id: \.self) { mode in
                let selected = model.phoneMode == mode
                Button {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.phoneMode = mode }
                } label: {
                    Label(mode.label, systemImage: mode.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .foregroundStyle(selected ? .white : .secondary)
                        .background {
                            if selected {
                                Capsule().fill(.teal.opacity(0.4))
                                    .overlay(Capsule().strokeBorder(.teal.opacity(0.8), lineWidth: 0.8))
                                    .matchedGeometryEffect(id: "phoneMode", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.07)))
    }

    @Namespace private var namespace
}

/// Left side of every Phone mode: the code, or a placeholder symbol.
struct PhoneCode: View {
    let image: NSImage?
    var placeholder = "qrcode"
    var busy = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        if busy { ProgressView().controlSize(.small).tint(.white) }
                        else { Image(systemName: placeholder).font(.system(size: 30)).foregroundStyle(.secondary) }
                    }
            }
        }
        .frame(width: 128, height: 128)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: image != nil)
    }
}

struct ReceivePanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let receiver = model.receiver
        HStack(alignment: .top, spacing: 14) {
            PhoneCode(image: receiver.qr, placeholder: "arrow.down.to.line", busy: receiver.isRunning && receiver.qr == nil)
            VStack(alignment: .leading, spacing: 6) {
                if let problem = receiver.problem, !receiver.isRunning {
                    Text("Receive is off").font(.system(size: 12, weight: .semibold))
                    Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PillButton(title: "New link", symbol: "arrow.clockwise", tint: .teal.opacity(0.4)) {
                        Haptics.tap()
                        receiver.start()
                    }
                } else if let text = receiver.texts.first {
                    Text("Text from your phone").font(.system(size: 12, weight: .semibold))
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.07)))
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        PillButton(title: "Copy", symbol: "doc.on.doc", tint: .teal.opacity(0.4)) {
                            Haptics.tap()
                            receiver.copyText(text, into: model.clipboard)
                        }
                        PillButton(title: "Dismiss", symbol: "xmark") { receiver.copyText(text, into: nil) }
                    }
                } else {
                    Text("Scan to send from your phone").font(.system(size: 12, weight: .semibold))
                    Text("Photos, files or text · iPhone and Android. Files go to the Shelf and Downloads ▸ Islandly.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let progress = receiver.progress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(.teal)
                    Text("Receiving… \(formatBytes(Double(progress.done))) of \(formatBytes(Double(progress.total)))")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                } else if let last = receiver.received.first {
                    Label(receiver.received.count > 1 ? "\(last)  +\(receiver.received.count - 1) more" : last,
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                } else if receiver.pairedHost != nil {
                    Label("Locked to your phone · other devices can't use this link", systemImage: "lock.iphone")
                        .font(.system(size: 10)).foregroundStyle(.teal.opacity(0.8)).lineLimit(1)
                } else {
                    Label("Same Wi-Fi only · locks to the first phone that scans", systemImage: "lock.fill")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .frame(maxHeight: 128)
        }
    }
}

struct SignPanel: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let receiver = model.receiver
        HStack(alignment: .top, spacing: 14) {
            if let signature = receiver.signature {
                // The signature itself, on paper-white so dark ink reads.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white)
                    .overlay(Image(nsImage: signature).resizable().scaledToFit().padding(10))
                    .frame(width: 128, height: 128)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                PhoneCode(image: receiver.qr, placeholder: "signature", busy: receiver.isRunning && receiver.qr == nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let problem = receiver.problem, !receiver.isRunning {
                    Text("Sign is off").font(.system(size: 12, weight: .semibold))
                    Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    PillButton(title: "New link", symbol: "arrow.clockwise", tint: .teal.opacity(0.4)) { receiver.start() }
                } else if receiver.signature != nil {
                    Text("Signature copied").font(.system(size: 12, weight: .semibold))
                    Text("Paste it with ⌘V into Preview, Pages, Word, Google Docs or Figma. Transparent background, saved to the Shelf too.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        PillButton(title: "Copy again", symbol: "doc.on.doc", tint: .teal.opacity(0.4)) {
                            Haptics.tap()
                            receiver.copySignature()
                        }
                        PillButton(title: "Sign again", symbol: "arrow.counterclockwise") { receiver.clearSignature() }
                    }
                } else {
                    Text("Scan and sign with your finger").font(.system(size: 12, weight: .semibold))
                    Text("Tap Send on the phone and the signature lands on this Mac's clipboard, ready to paste into any document.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Label(receiver.pairedHost != nil ? "Locked to your phone" : "Same Wi-Fi only · locks to the first phone that scans",
                          systemImage: receiver.pairedHost != nil ? "lock.iphone" : "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(receiver.pairedHost != nil ? AnyShapeStyle(.teal.opacity(0.8)) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
            .frame(maxHeight: 128)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: receiver.signature != nil)
    }
}
