import AppKit

/// Draws the menu bar item as one small image: a few tight columns (name on top, number below),
/// fixed widths so nothing jitters as numbers change.
enum BarRenderer {
    static let height: CGFloat = 22

    static func render(_ monitor: Monitor, prefs: Prefs, dark: Bool) -> NSImage {
        let ink = dark ? NSColor.white : NSColor.black
        let metrics = prefs.bar.isEmpty ? [Metric.cpu] : prefs.bar
        let columns = metrics.map { column(for: $0, monitor: monitor, prefs: prefs, ink: ink) }
        let gap: CGFloat = 5
        let width = columns.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, columns.count - 1)) + 2

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for column in columns {
                column.draw(x)
                x += column.width + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private struct Column {
        var width: CGFloat
        var draw: (CGFloat) -> Void
    }

    // MARK: Widths and colors

    /// The widest a metric's value can get, so the column keeps its width.
    private static func widest(_ metric: Metric) -> String {
        switch metric {
        case .cpu, .gpu, .ram, .battery: "100%"
        case .temp: "100°"
        case .power: "88.8W"
        case .net, .disk: "888K"
        case .claude: "8/8"
        }
    }

    private static func color(_ metric: Metric, monitor: Monitor, prefs: Prefs, ink: NSColor) -> NSColor {
        guard prefs.colorAlerts else { return ink }
        let s = monitor.system
        let red = NSColor(red: 1, green: 0.33, blue: 0.3, alpha: 1)
        let orange = NSColor(red: 1, green: 0.62, blue: 0.2, alpha: 1)
        switch metric {
        case .cpu: return s.cpu > 0.9 ? red : ink
        case .gpu: return s.gpu > 0.9 ? red : ink
        case .ram: return s.memory.pressure >= 4 ? red : s.memory.pressure >= 2 ? orange : ink
        case .temp: return s.cpuTemp >= 95 ? red : s.cpuTemp >= 85 ? orange : ink
        case .battery: return s.power.hasBattery && !s.power.pluggedIn && s.power.batteryPercent <= 15 ? red : ink
        case .claude:
            // Lime while Claude is working (on a dark menu bar, where lime reads well).
            let lime = NSColor(red: 0.84, green: 1, blue: 0.37, alpha: 1)
            return monitor.sessions.contains(where: \.isBusy) && ink == .white ? lime : ink
        default: return ink
        }
    }

    private static let label = NSFont.systemFont(ofSize: 7, weight: .bold)
    private static let value = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    private static let small = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)

    /// The name on top, the number below. Network and disk show their two directions instead.
    private static func column(for metric: Metric, monitor: Monitor, prefs: Prefs, ink: NSColor) -> Column {
        let text = monitor.barValue(metric)
        let tint = color(metric, monitor: monitor, prefs: prefs, ink: ink)
        if let pair = monitor.pair(metric) {
            let w = max(size("↑888K", small).width, size(metric.label, label).width)
            return Column(width: w) { x in
                drawText(pair.0, small, ink.withAlphaComponent(0.85), x: x, y: 11, width: w, align: .right)
                drawText(pair.1, small, ink, x: x, y: 1.5, width: w, align: .right)
            }
        }
        let w = max(size(widest(metric), value).width, size(metric.label, label).width + 0.4 * CGFloat(metric.label.count))
        return Column(width: w) { x in
            drawText(metric.label, label, ink.withAlphaComponent(0.6), x: x, y: 13.5, width: w, align: .center, kern: 0.4)
            drawText(text, value, tint, x: x, y: 0.5, width: w, align: .center)
        }
    }

    // MARK: Drawing helpers

    private static func size(_ text: String, _ font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private static func drawText(_ text: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, align: NSTextAlignment, kern: CGFloat = 0) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style, .kern: kern]
        (text as NSString).draw(in: NSRect(x: x, y: y, width: width, height: font.pointSize + 4), withAttributes: attrs)
    }

}
