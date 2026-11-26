// Renders the Vitals app icon at every size and builds Resources/AppIcon.icns.
// Run: swift tools/make-icon.swift
import AppKit
import SwiftUI

let lime = Color(red: 213 / 255, green: 1, blue: 95 / 255)
let green = Color(red: 57 / 255, green: 153 / 255, blue: 71 / 255)

/// The heartbeat: flat, a small bump, the spike, the dip, flat again (in a 0...1 box).
struct Pulse: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [
            (0.00, 0.55), (0.30, 0.55), (0.36, 0.47), (0.42, 0.55), (0.48, 0.55),
            (0.54, 0.16), (0.61, 0.86), (0.67, 0.42), (0.71, 0.55), (1.00, 0.55),
        ]
        var p = Path()
        for (i, pt) in pts.enumerated() {
            let point = CGPoint(x: r.minX + pt.0 * r.width, y: r.minY + pt.1 * r.height)
            i == 0 ? p.move(to: point) : p.addLine(to: point)
        }
        return p
    }
}

struct Icon: View {
    var body: some View {
        // Apple's grid: an 824 pt body inside the 1024 canvas.
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.145, blue: 0.11), Color(red: 0.045, green: 0.05, blue: 0.04)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(RadialGradient(colors: [lime.opacity(0.22), .clear], center: .init(x: 0.28, y: 0.18), startRadius: 0, endRadius: 520))
            // The gauge: a faint full track and a lime arc three quarters round.
            Circle()
                .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 46, lineCap: .round))
                .frame(width: 500, height: 500)
            Circle()
                .trim(from: 0, to: 0.74)
                .stroke(AngularGradient(colors: [green, lime, lime], center: .center, startAngle: .degrees(0), endAngle: .degrees(266)),
                        style: StrokeStyle(lineWidth: 46, lineCap: .round))
                .rotationEffect(.degrees(-90 + 0))
                .frame(width: 500, height: 500)
                .shadow(color: lime.opacity(0.55), radius: 26)
            // The pulse across the middle, glowing.
            Pulse()
                .stroke(lime.opacity(0.35), style: StrokeStyle(lineWidth: 64, lineCap: .round, lineJoin: .round))
                .blur(radius: 22)
                .frame(width: 640, height: 300)
            Pulse()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
                .frame(width: 640, height: 300)
                .shadow(color: lime, radius: 10)
            // A fine inner edge so it reads as glass on any wallpaper.
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 3)
        }
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(_ size: Int) -> Data {
    let renderer = ImageRenderer(content: Icon().scaleEffect(CGFloat(size) / 1024).frame(width: CGFloat(size), height: CGFloat(size)))
    renderer.scale = 1
    renderer.isOpaque = false
    let image = renderer.nsImage!
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try MainActor.assumeIsolated { render(base) }.write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try MainActor.assumeIsolated { render(base * 2) }.write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try MainActor.assumeIsolated { render(1024) }.write(to: root.appendingPathComponent("docs/assets/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print("Wrote Resources/AppIcon.icns and docs/assets/icon.png")
