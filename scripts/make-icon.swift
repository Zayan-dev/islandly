// Draws the Islandly app icon (Resources/AppIcon.icns) on Apple's 1024 grid.
//
//   swiftc -parse-as-library scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon icon.png
//   then build an .iconset with sips and run: iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns

import AppKit
import SwiftUI

/// Islandly app icon, drawn on Apple's 1024 grid (824 pt squircle, 100 pt margin).
struct Icon: View {
    var body: some View {
        let squircle = RoundedRectangle(cornerRadius: 186, style: .continuous)
        ZStack {
            Color.clear
            ZStack {
                // Night-sky body with light spilling down from the island
                squircle.fill(LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.27), Color(red: 0.02, green: 0.03, blue: 0.07)],
                                             startPoint: .top, endPoint: .bottom))
                RadialGradient(colors: [Color(red: 0.25, green: 0.85, blue: 0.80).opacity(0.55), .clear],
                               center: UnitPoint(x: 0.5, y: 0.26), startRadius: 10, endRadius: 430)
                    .clipShape(squircle)
                RadialGradient(colors: [Color(red: 0.62, green: 0.36, blue: 1.0).opacity(0.35), .clear],
                               center: UnitPoint(x: 0.5, y: 0.95), startRadius: 10, endRadius: 520)
                    .clipShape(squircle)
                // Ripples: the island "expanding"
                ForEach(0..<3) { i in
                    Capsule()
                        .stroke(Color.white.opacity(0.10 - Double(i) * 0.028), lineWidth: 5)
                        .frame(width: 560 + CGFloat(i) * 110, height: 176 + CGFloat(i) * 110)
                        .offset(y: -150)
                }
                .clipShape(squircle)
                // The island
                ZStack {
                    Capsule().fill(.black)
                    Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 4)
                    HStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.55), Color(red: 1.0, green: 0.62, blue: 0.25)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 104, height: 104)
                            .overlay(Image(systemName: "music.note").font(.system(size: 54, weight: .bold)).foregroundStyle(.white))
                        Spacer()
                        Image(systemName: "waveform")
                            .font(.system(size: 92, weight: .semibold))
                            .foregroundStyle(Color(red: 0.2, green: 0.95, blue: 0.45))
                            .shadow(color: .green.opacity(0.8), radius: 16)
                    }
                    .padding(.horizontal, 36)
                }
                .frame(width: 560, height: 176)
                .shadow(color: Color(red: 0.25, green: 0.9, blue: 0.85).opacity(0.55), radius: 40)
                .offset(y: -150)
                // Hairline edge like glass
                squircle.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 3)
            }
            .frame(width: 824, height: 824)
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }
}

@main struct Make { @MainActor static func main() {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("ok")
}}
