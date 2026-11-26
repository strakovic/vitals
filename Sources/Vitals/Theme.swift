import SwiftUI

/// Colours and type. Lime on near-black, with system fonts.
enum Theme {
    static let lime = Color(red: 213 / 255, green: 1, blue: 95 / 255)
    static let green = Color(red: 57 / 255, green: 153 / 255, blue: 71 / 255)
    static let orange = Color(red: 1, green: 0.66, blue: 0.24)
    static let red = Color(red: 1, green: 0.36, blue: 0.32)
    static let base = Color(red: 22 / 255, green: 22 / 255, blue: 22 / 255)
    static let card = Color.white.opacity(0.05)
    static let hairline = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.28)

    static let gradient = LinearGradient(colors: [lime, green], startPoint: .topTrailing, endPoint: .bottomLeading)

    // System fonts only (SF Pro and SF Mono): native, crisp at every size, nothing to bundle or license.
    static func thin(_ size: CGFloat) -> Font { .system(size: size, weight: .thin) }
    static func light(_ size: CGFloat) -> Font { .system(size: size, weight: .light) }
    static func regular(_ size: CGFloat) -> Font { .system(size: size, weight: .regular) }
    /// Small uppercase labels: SF Mono, semibold, tracked out by the callers.
    static func caps(_ size: CGFloat) -> Font { .system(size: size + 0.5, weight: .semibold, design: .monospaced) }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }

    /// Lime when calm, orange when busy, red when maxed out.
    static func heat(_ level: Double) -> Color {
        level > 0.85 ? red : level > 0.6 ? orange : lime
    }
}
