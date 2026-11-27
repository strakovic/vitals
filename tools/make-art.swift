// Renders the README's designed images from the app's own screenshots (run after `--snapshot <dir> --demo`
// has refreshed docs/assets): a hero banner and one card per feature, each screen framed with rounded
// corners, a soft lime glow and a short headline. Run: swift tools/make-art.swift
import AppKit
import SwiftUI

let lime = Color(red: 213 / 255, green: 1, blue: 95 / 255)
let green = Color(red: 57 / 255, green: 153 / 255, blue: 71 / 255)
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("docs/assets")
let out = root.appendingPathComponent("docs/art")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func image(_ name: String) -> NSImage { NSImage(contentsOf: assets.appendingPathComponent(name))! }

/// The dark stage everything sits on: deep gradient, lime and green light, faint dot grid.
struct Stage: View {
    var glowX: CGFloat = 0.72
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.075, green: 0.085, blue: 0.065), Color(red: 0.035, green: 0.04, blue: 0.032)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [lime.opacity(0.16), .clear], center: .init(x: glowX, y: 0.15), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [green.opacity(0.2), .clear], center: .init(x: 0.1, y: 1.05), startRadius: 0, endRadius: 700)
            Canvas { ctx, size in
                let step: CGFloat = 28
                var y: CGFloat = step / 2
                while y < size.height {
                    var x: CGFloat = step / 2
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.white.opacity(0.05)))
                        x += step
                    }
                    y += step
                }
            }
        }
    }
}

/// A screen from the app, framed like a floating panel.
struct Screen: View {
    var name: String
    var height: CGFloat
    var body: some View {
        let img = image(name)
        let width = height * img.size.width / img.size.height
        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: height * 0.034, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height * 0.034, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5))
            .shadow(color: lime.opacity(0.22), radius: 60)
            .shadow(color: .black.opacity(0.7), radius: 40, y: 30)
    }
}

struct Kicker: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 20, weight: .semibold, design: .monospaced)).kerning(3).foregroundStyle(lime)
    }
}

struct Points: View {
    var items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Capsule().fill(lime).frame(width: 16, height: 3).offset(y: -6)
                    Text(item).font(.system(size: 25, weight: .regular)).foregroundStyle(.white.opacity(0.68))
                }
            }
        }
    }
}

struct Feature {
    var kicker: String
    var title: String
    var text: String
    var points: [String]
    var shots: [String]
    var content: some View {
        ZStack {
            Stage()
            HStack(spacing: 80) {
                VStack(alignment: .leading, spacing: 0) {
                    Kicker(text: kicker)
                    Text(title).font(.system(size: 64, weight: .bold)).kerning(-2).foregroundStyle(.white)
                        .lineSpacing(-4).padding(.top, 18).fixedSize(horizontal: false, vertical: true)
                    Text(text).font(.system(size: 27, weight: .regular)).foregroundStyle(.white.opacity(0.6))
                        .lineSpacing(6).padding(.top, 24).fixedSize(horizontal: false, vertical: true)
                    Points(items: points).padding(.top, 34)
                }
                .frame(width: 680, alignment: .leading)
                HStack(alignment: .top, spacing: 36) {
                    ForEach(Array(shots.enumerated()), id: \.offset) { i, shot in
                        Screen(name: shot, height: 820).offset(y: i == 1 ? 50 : 0)
                    }
                }
            }
            .padding(.horizontal, 110)
        }
        .frame(width: 1920, height: 1080)
    }
}

/// The Vitals item as it sits in the menu bar: tiny labels over numbers.
struct BarItem: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach([("CPU", "34%"), ("GPU", "27%"), ("RAM", "68%"), ("TEMP", "58°"), ("AI", "3/4")], id: \.0) { label, value in
                VStack(spacing: 2) {
                    Text(label).font(.system(size: 11, weight: .bold)).kerning(0.6).foregroundStyle(.white.opacity(0.6))
                    Text(value).font(.system(size: 19, weight: .bold)).monospacedDigit().foregroundStyle(label == "AI" ? lime : .white)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.2)))
    }
}

struct MenuBar: View {
    var body: some View {
        HStack(spacing: 30) {
            Text("\u{F8FF}").font(.system(size: 26))
            Text("Finder").font(.system(size: 22, weight: .bold))
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 22)) }
            Spacer()
            BarItem()
            ForEach(["speaker.wave.2.fill", "wifi", "battery.75percent", "magnifyingglass", "switch.2"], id: \.self) {
                Image(systemName: $0).font(.system(size: 24, weight: .medium))
            }
            Text("Wed 9:41").font(.system(size: 22, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 26)
        .frame(width: 1640, height: 58)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

struct Hero: View {
    var body: some View {
        ZStack {
            Stage(glowX: 0.68)
            VStack(spacing: 0) {
                HStack(spacing: 26) {
                    Image(nsImage: image("icon.png")).resizable().frame(width: 120, height: 120).shadow(color: lime.opacity(0.18), radius: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vitals").font(.system(size: 88, weight: .bold)).kerning(-3).foregroundStyle(.white)
                        Text("Your Mac's vital signs, one click away.").font(.system(size: 32)).foregroundStyle(.white.opacity(0.62))
                    }
                }
                HStack(spacing: 12) {
                    ForEach(["CPU · GPU · Memory", "AI agents", "Stop anything in one click", "Battery care", "Boost", "History"], id: \.self) { chip in
                        Text(chip).font(.system(size: 21, weight: .medium)).foregroundStyle(.white.opacity(0.78))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(.white.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    }
                }
                .padding(.top, 30)
            }
            .position(x: 960, y: 210)

            MenuBar().position(x: 960, y: 420)
            // The panel hangs from the Vitals item with the popover's arrow.
            RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.1, green: 0.11, blue: 0.095))
                .frame(width: 30, height: 30).rotationEffect(.degrees(45))
                .position(x: 1172, y: 470)
            Screen(name: "panel.png", height: 800).position(x: 1172, y: 474 + 400)
            Screen(name: "ai.png", height: 640).opacity(0.94).position(x: 470, y: 560 + 320)
            Screen(name: "battery.png", height: 640).opacity(0.94).position(x: 1640, y: 560 + 320)
        }
        .frame(width: 1920, height: 1340)
        .clipped()
    }
}

@MainActor func save(_ view: some View, _ name: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: out.appendingPathComponent(name))
    print("wrote docs/art/\(name)")
}

/// GitHub's social preview (1280 x 640): what X, LinkedIn, Slack and iMessage show for a repo link.
struct Social: View {
    var body: some View {
        ZStack {
            Stage(glowX: 0.75)
            HStack(spacing: 60) {
                VStack(alignment: .leading, spacing: 0) {
                    Image(nsImage: image("icon.png")).resizable().frame(width: 128, height: 128)
                    Text("Vitals").font(.system(size: 92, weight: .bold)).kerning(-3).foregroundStyle(.white).padding(.top, 18)
                    Text("Your Mac's vital signs,\none click away.").font(.system(size: 34)).foregroundStyle(.white.opacity(0.65)).lineSpacing(4).padding(.top, 6)
                    Text("Free · Open source · Notarized").font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(lime).padding(.top, 26)
                }
                .frame(width: 600, alignment: .leading)
                Screen(name: "panel.png", height: 560).offset(y: 70)
            }
        }
        .frame(width: 1280, height: 640)
        .clipped()
    }
}

MainActor.assumeIsolated {
    save(Social(), "social-preview.png")
    save(Hero(), "hero.png")
    save(Feature(kicker: "Live", title: "Everything your Mac is doing, on one calm screen.",
                 text: "CPU, GPU and memory share one live chart. Hover it and the numbers rewind. Then every app, heaviest first.",
                 points: ["Quit any app in one click", "The list holds still under your pointer", "Heat, power, network and battery underneath"],
                 shots: ["panel.png"]).content, "live.png")
    save(Feature(kicker: "AI agents", title: "See exactly what your agents are doing.",
                 text: "Claude Code, Codex, Gemini CLI and more, with the commands they run right now.",
                 points: ["Every task with what it costs", "Stop any task or session in one click", "AI apps listed alongside"],
                 shots: ["ai.png"]).content, "agents.png")
    save(Feature(kicker: "Battery care", title: "A battery that lasts years longer.",
                 text: "Set macOS's charge limit from the menu bar, charge to 100% once when you need it, and know when heat is the problem.",
                 points: ["Limit at 80, 85, 90, 95% or off", "Health, cycles and heat alerts", "On desktop Macs, disk takes its place"],
                 shots: ["battery.png"]).content, "battery.png")
    save(Feature(kicker: "Boost and history", title: "Free memory in one click. See any day again.",
                 text: "Where your memory went as one bar, and every number's history from 15 minutes to a month.",
                 points: ["Tick what you don't need, press Boost", "Idle iOS Simulators shut themselves down", "Kept on your Mac, about 5 MB a year"],
                 shots: ["boost.png", "history.png"]).content, "boost.png")
}
