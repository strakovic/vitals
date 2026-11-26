import SwiftUI

/// Who is using the CPU, the GPU or the memory right now, as one stacked bar.
enum LoadKind: CaseIterable {
    case cpu, gpu, memory
    var title: String { switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "MEMORY" } }

    func value(_ app: AppUsage) -> Double {
        switch self {
        case .cpu: app.cpu
        case .gpu: app.gpu
        case .memory: Double(app.memory)
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .cpu, .gpu: String(format: v < 10 ? "%.1f%%" : "%.0f%%", v)
        case .memory: Fmt.bytes(UInt64(max(0, v)))
        }
    }
}

struct LoadSegment: Identifiable {
    var id: String
    var name: String
    var value: Double
    var color: Color
    var freeing = false
}

enum LoadMap {
    static let claudeColor = Theme.lime
    static let simColor = Color(red: 1, green: 0.42, blue: 0.42)
    static let otherColor = Color.white.opacity(0.28)
    static let systemColor = Color.white.opacity(0.14)
    static let palette: [Color] = [
        Color(red: 1, green: 0.66, blue: 0.24), Color(red: 0.45, green: 0.68, blue: 1),
        Color(red: 0.74, green: 0.55, blue: 1), Color(red: 0.3, green: 0.85, blue: 0.78),
    ]

    static func isClaude(_ app: AppUsage) -> Bool { app.isClaude || app.id.hasSuffix("/Claude.app") }

    /// The apps that get their own colour: the biggest users of `kind` that aren't Claude or simulators.
    static func featured(_ apps: [AppUsage], by kind: LoadKind) -> [String] {
        apps.filter { !isClaude($0) && $0.id != ProcessScanner.simulatorsKey && kind.value($0) > 0 }
            .sorted { kind.value($0) > kind.value($1) }
            .prefix(4).map(\.id)
    }

    static func colors(_ featured: [String]) -> [String: Color] {
        Dictionary(uniqueKeysWithValues: featured.prefix(4).enumerated().map { ($1, palette[$0]) })
    }

    /// Segments for one bar, plus its capacity (100% or the RAM size) and the system's own total.
    static func build(_ kind: LoadKind, monitor: Monitor, featured: [String], freeing: Set<String> = [], simsFreeing: Bool = false)
        -> (segments: [LoadSegment], capacity: Double, total: Double)
    {
        let apps = monitor.apps
        let s = monitor.system
        let capacity: Double, total: Double
        switch kind {
        case .cpu: capacity = 100; total = s.cpu * 100
        case .gpu: capacity = 100; total = s.gpu * 100
        case .memory: capacity = Double(s.memory.total); total = Double(s.memory.used + s.memory.swap)
        }
        let colors = colors(featured)
        var list: [LoadSegment] = []
        let claude = apps.filter(isClaude).reduce(0) { $0 + kind.value($1) }
        list.append(LoadSegment(id: "claude", name: "Claude", value: claude, color: claudeColor))
        if let sims = apps.first(where: { $0.id == ProcessScanner.simulatorsKey }) {
            list.append(LoadSegment(id: "sims", name: "Simulators", value: kind.value(sims), color: simColor, freeing: simsFreeing))
        }
        let byId = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in featured.prefix(4) {
            guard let app = byId[id] else { continue }
            list.append(LoadSegment(id: id, name: app.name, value: kind.value(app), color: colors[id] ?? otherColor,
                                    freeing: freeing.contains(id)))
        }
        let named = Set(featured.prefix(4)).union([ProcessScanner.simulatorsKey])
        let others = apps.filter { !named.contains($0.id) && !isClaude($0) }.reduce(0) { $0 + kind.value($1) }
        list.append(LoadSegment(id: "other", name: "Everything else", value: others, color: otherColor))

        // Per-app numbers never add up exactly to the system's; fit them to what the system reports.
        let sum = list.reduce(0) { $0 + $1.value }
        if sum > total, sum > 0 {
            list = list.map { var seg = $0; seg.value *= total / sum; return seg }
        } else if total - sum > capacity * 0.005 {
            list.append(LoadSegment(id: "system", name: "macOS", value: total - sum, color: systemColor))
        }
        return (list.filter { $0.value > capacity * 0.002 }, capacity, total)
    }
}

/// The bar itself: segments left to right, empty track for what's free, and for memory an orange
/// stretch past the RAM line for what had to go to the disk.
struct StackBar: View {
    var segments: [LoadSegment]
    var capacity: Double
    var height: CGFloat = 22

    var body: some View {
        let total = segments.reduce(0) { $0 + $1.value }
        let width = max(capacity, total, 0.0001)
        GeometryReader { geo in
            let w = geo.size.width
            let capX = w * capacity / width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05))
                if width > capacity {
                    Rectangle().fill(Theme.orange.opacity(0.14)).frame(width: w - capX).offset(x: capX)
                }
                HStack(spacing: 1.5) {
                    ForEach(segments) { seg in
                        Rectangle()
                            .fill(seg.color.opacity(seg.freeing ? 0.3 : 0.9))
                            .overlay(seg.freeing ? Stripes().stroke(seg.color.opacity(0.95), lineWidth: 1.5).clipped() : nil)
                            .frame(width: max(1, w * seg.value / width - 1.5))
                    }
                    Spacer(minLength: 0)
                }
                if width > capacity {
                    Rectangle().fill(.white.opacity(0.85)).frame(width: 1.5).offset(x: min(capX, w - 1.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .animation(.spring(response: 0.5, dampingFraction: 0.85), value: segments.map(\.value))
            .animation(.easeOut(duration: 0.2), value: segments.map(\.freeing))
        }
        .frame(height: height)
    }
}

/// One labelled bar: title, total, the bar, and (optionally) its own legend.
struct LoadBarCard: View {
    var kind: LoadKind
    var segments: [LoadSegment]
    var capacity: Double
    var total: Double
    var legend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(kind.title).font(Theme.caps(8)).kerning(0.6).foregroundStyle(Theme.lime.opacity(0.85))
                Spacer()
                Text(kind.format(total)).font(Theme.regular(12)).monospacedDigit().foregroundStyle(.white)
                if kind == .memory {
                    Text("of \(Fmt.bytes(UInt64(capacity)))").font(Theme.light(10)).foregroundStyle(Theme.faint)
                    if total > capacity {
                        Text("· \(Fmt.bytes(UInt64(total - capacity))) on disk").font(Theme.light(10)).foregroundStyle(Theme.orange)
                    }
                }
            }
            StackBar(segments: segments, capacity: capacity, height: legend ? 20 : 14)
            if legend { LoadLegend(segments: segments, kind: kind) }
        }
    }
}

struct LoadLegend: View {
    var segments: [LoadSegment]
    var kind: LoadKind
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
            ForEach(segments) { seg in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(seg.color).frame(width: 7, height: 7)
                    Text(seg.name).font(Theme.light(10)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text(kind.format(seg.value)).font(Theme.light(9.5)).monospacedDigit().foregroundStyle(Theme.faint)
                }
            }
        }
    }
}

/// Diagonal hatching for the parts Boost is about to free.
struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        return p
    }
}
