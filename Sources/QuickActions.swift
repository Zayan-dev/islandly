import AppKit
import CoreImage.CIFilterBuiltins
import ScreenCaptureKit
import Vision

// MARK: - Quick action tiles

enum QuickAction: CaseIterable {
    case colorPicker, darkMode, grabText, qrBeam, prompter, nameAlert

    var label: String {
        switch self {
        case .colorPicker: return "Pick Color"
        case .darkMode: return "Dark Mode"
        case .grabText: return "Grab Text"
        case .qrBeam: return "QR Beam"
        case .prompter: return "Prompter"
        case .nameAlert: return "Name Alert"
        }
    }
}

/// Panels that open inside the Home tab (replacing the media card until closed).
enum HomePanel: Equatable {
    case qr, prompter, nameAlert

    var title: String {
        switch self {
        case .qr: return "QR Beam"
        case .prompter: return "Teleprompter"
        case .nameAlert: return "Name Alert"
        }
    }

    /// Height of the panel content (header included).
    var height: CGFloat {
        switch self {
        case .qr: return 164
        case .prompter: return 150
        case .nameAlert: return 204
        }
    }
}

@discardableResult
func runTool(_ path: String, _ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

/// Needed after granting Screen Recording — macOS only applies it to a fresh process.
func relaunchApp() {
    let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 0.7; open '\(path)'"]
    try? process.run()
    NSApp.terminate(nil)
}

// MARK: - Color picker + dark mode

final class QuickActionsModel: ObservableObject {
    @Published private(set) var darkMode = false

    private var sampler: NSColorSampler?

    func refreshState() {
        darkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    func pickColor(completion: @escaping (String?) -> Void) {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            self?.sampler = nil
            guard let rgb = color?.usingColorSpace(.sRGB) else { completion(nil); return }
            let hex = String(format: "#%02X%02X%02X",
                             Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()),
                             Int((rgb.blueComponent * 255).rounded()))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            completion(hex)
        }
    }

    func toggleDarkMode() {
        darkMode.toggle()
        DispatchQueue.global(qos: .userInitiated).async {
            runAppleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshState() }
        }
    }
}

// MARK: - Screen capture, OCR, QR

enum ScreenTools {
    /// Lets the user drag a box on screen (system crosshair). nil if cancelled.
    /// Captured in-process with ScreenCaptureKit so the app's own Screen Recording permission applies.
    static func captureRegion(completion: @escaping (CGImage?) -> Void) {
        RegionSelector.select { rect in
            guard let rect else {
                lastCaptureFailed = false
                completion(nil)
                return
            }
            // Cocoa (bottom-left origin) → CoreGraphics global (top-left origin of the primary display).
            let primaryHeight = NSScreen.screens[0].frame.height
            let cgRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
            captureRect(cgRect, completion: completion)
        }
    }

    /// True when the last capture threw (e.g. Screen Recording not allowed) rather than being cancelled.
    static var lastCaptureFailed = false

    static func captureRect(_ cgRect: CGRect, completion: @escaping (CGImage?) -> Void) {
        lastCaptureFailed = false
        Task {
            do {
                let image = try await SCScreenshotManager.captureImage(in: cgRect)
                await MainActor.run { completion(image) }
            } catch {
                await MainActor.run {
                    lastCaptureFailed = true
                    completion(nil)
                }
            }
        }
    }

    /// On-device text recognition (Apple Vision).
    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    static func detectQR(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue).first
    }

    static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
