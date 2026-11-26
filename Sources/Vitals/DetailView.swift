import Charts
import SwiftUI

enum ChartRange: Double, CaseIterable, Identifiable {
    case quarter = 900, hour = 3600, six = 21600, day = 86400, week = 604800, month = 2_592_000
    var id: Double { rawValue }
    var title: String {
        switch self {
        case .quarter: "15 m"
        case .hour: "1 h"
        case .six: "6 h"
        case .day: "24 h"
        case .week: "Week"
        case .month: "Month"
        }
    }
}

/// What a metric's history chart draws and how it reads.
private struct ChartSpec {
    var series: [(key: String, name: String)]
    var unit: Unit
    var top: TopKind?
    var topTitle: String

    enum Unit { case percent, celsius, watts, rate, count }

    static func of(_ metric: Metric) -> ChartSpec {
        switch metric {
        case .cpu: ChartSpec(series: [("cpu", "CPU")], unit: .percent, top: .cpu, topTitle: "USING THE CPU")
        case .gpu: ChartSpec(series: [("gpu", "GPU")], unit: .percent, top: .gpu, topTitle: "USING THE GPU")
        case .ram: ChartSpec(series: [("ram", "Memory")], unit: .percent, top: .memory, topTitle: "USING MEMORY")
        case .temp: ChartSpec(series: [("temp", "CPU die")], unit: .celsius, top: .cpu, topTitle: "HEATING IT UP")
        case .power: ChartSpec(series: [("power", "System")], unit: .watts, top: .energy, topTitle: "DRAWING POWER")
        case .net: ChartSpec(series: [("netIn", "Down"), ("netOut", "Up")], unit: .rate, top: nil, topTitle: "TRANSFERRED")
        case .disk: ChartSpec(series: [("diskRead", "Read"), ("diskWrite", "Write")], unit: .rate, top: nil, topTitle: "TRANSFERRED")
        case .battery: ChartSpec(series: [("battery", "Battery")], unit: .percent, top: .energy, topTitle: "DRAINING IT")
        case .claude: ChartSpec(series: [("claude", "Working sessions")], unit: .count, top: .claude, topTitle: "BUSIEST SESSIONS")
        }
    }

    func format(_ v: Double) -> String {
        switch unit {
        case .percent: String(format: "%.0f%%", v)
        case .celsius: String(format: "%.0f°", v)
        case .watts: Fmt.watts(v)
        case .rate: Fmt.rate(v) + "/s"
        case .count: String(format: v.rounded() == v ? "%.0f" : "%.1f", v)
        }
    }

    func formatTop(_ v: Double) -> String {
        switch top {
        case .memory: Fmt.bytes(UInt64(max(0, v)))
        case .energy: String(format: v < 1 ? "%.2f W" : "%.1f W", v)
        default: String(format: "%.0f%%", v)
        }
    }
}

struct DetailView: View {
    @State var metric: Metric
    @ObservedObject var monitor: Monitor
    var back: () -> Void
    @State private var range: ChartRange = .hour
    @State private var hover: HistoryPoint?

    private var spec: ChartSpec { .of(metric) }
    private var now: Double { Date().timeIntervalSince1970 }

    var body: some View {
        let points = monitor.store.points(span: range.rawValue, now: now)
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            metricPicker
            readout(points)
            chart(points)
                .frame(height: metric == .battery ? 110 : 170)
            Segments(options: ChartRange.allCases.map { ($0, $0.title) }, selection: $range)
            if metric == .battery {
                BatteryCare(monitor: monitor, prefs: Prefs.shared)
            } else {
                liveSplit
                stats(points)
                breakdown(points)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        }
    }

    /// Right now, who makes up this number: the same stacked bar Boost shows.
    @ViewBuilder private var liveSplit: some View {
        if let kind: LoadKind = metric == .cpu ? .cpu : metric == .gpu ? .gpu : metric == .ram ? .memory : nil {
            let bar = LoadMap.build(kind, monitor: monitor, featured: LoadMap.featured(monitor.apps, by: kind))
            LoadBarCard(kind: kind, segments: bar.segments, capacity: bar.capacity, total: bar.total)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        }
    }

    // MARK: Header

    private var topBar: some View {
        HStack(spacing: 10) {
            BackButton(action: back)
            Spacer()
            Image(systemName: metric.symbol).font(.system(size: 12)).foregroundStyle(Theme.lime)
            Text(metric.title).font(Theme.light(16)).foregroundStyle(.white)
        }
    }

    private var metricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Metric.allCases) { m in
                    Button { metric = m; hover = nil } label: {
                        Text(m.label)
                            .font(Theme.caps(8))
                            .kerning(0.6)
                            .foregroundStyle(m == metric ? Theme.base : Theme.dim)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(m == metric ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The big number: the hovered moment, or right now.
    private func readout(_ points: [HistoryPoint]) -> some View {
        let point = hover ?? points.last
        return HStack(alignment: .lastTextBaseline, spacing: 10) {
            ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                VStack(alignment: .leading, spacing: 0) {
                    Text(point.map { spec.format($0.v[series.key] ?? 0) } ?? "--")
                        .font(Theme.thin(index == 0 ? 34 : 24)).monospacedDigit()
                        .foregroundStyle(.white)
                    if spec.series.count > 1 {
                        Text(series.name.uppercased()).font(Theme.caps(7.5)).kerning(0.6).foregroundStyle(color(index))
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(hover == nil ? "LIVE" : "AT").font(Theme.caps(7.5)).kerning(0.6).foregroundStyle(Theme.lime.opacity(0.8))
                Text(hover.map { timeLabel($0.t) } ?? "hover the chart").font(Theme.light(11)).foregroundStyle(Theme.dim)
                if let users = hover.flatMap(topAt), let first = users.first {
                    Text("\(first.n) \(spec.formatTop(first.v))")
                        .font(Theme.light(10)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
            }
        }
        .frame(height: 50)
    }

    // MARK: Chart

    private func chart(_ points: [HistoryPoint]) -> some View {
        let maxValue = points.flatMap { p in spec.series.map { p.v[$0.key] ?? 0 } }.max() ?? 1
        let yTop: Double = {
            switch spec.unit {
            case .percent: return 100
            case .celsius: return max(60, (maxValue / 10).rounded(.up) * 10 + 5)
            case .count: return max(2, maxValue.rounded(.up) + 1)
            default: return max(maxValue * 1.15, spec.unit == .watts ? 5 : 1024)
            }
        }()
        let yBottom: Double = spec.unit == .celsius ? max(0, ((points.compactMap { $0.v["temp"] }.min() ?? 30) / 10).rounded(.down) * 10 - 5) : 0

        return Group {
            if points.count < 2 {
                Placeholder(symbol: "chart.xyaxis.line", text: "Collecting history…")
            } else {
                Chart {
                    ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                        ForEach(points, id: \.t) { p in
                            if let value = p.v[series.key] {
                                AreaMark(
                                    x: .value("Time", Date(timeIntervalSince1970: p.t)),
                                    yStart: .value("Base", yBottom),
                                    yEnd: .value(series.name, value),
                                    series: .value("Series", series.name)
                                )
                                .foregroundStyle(LinearGradient(colors: [color(index).opacity(index == 0 ? 0.32 : 0.18), color(index).opacity(0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                                LineMark(
                                    x: .value("Time", Date(timeIntervalSince1970: p.t)),
                                    y: .value(series.name, value),
                                    series: .value("Series", series.name)
                                )
                                .foregroundStyle(color(index))
                                .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                                .interpolationMethod(.monotone)
                            }
                        }
                    }
                    if let hover {
                        RuleMark(x: .value("Time", Date(timeIntervalSince1970: hover.t)))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        if let value = hover.v[spec.series[0].key] {
                            PointMark(x: .value("Time", Date(timeIntervalSince1970: hover.t)), y: .value("Value", value))
                                .foregroundStyle(Theme.lime)
                                .symbolSize(36)
                        }
                    }
                }
                .chartYScale(domain: yBottom...yTop)
                .chartXScale(domain: Date(timeIntervalSince1970: now - range.rawValue)...Date(timeIntervalSince1970: now))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel(format: range.rawValue > 86400 ? .dateTime.day().month(.abbreviated) : .dateTime.hour().minute())
                            .font(Theme.light(9)).foregroundStyle(Theme.faint)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(spec.format(v)).font(Theme.light(9)).foregroundStyle(Theme.faint) }
                        }
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let frame = proxy.plotFrame else { return }
                                    let x = location.x - geo[frame].origin.x
                                    guard let date: Date = proxy.value(atX: x) else { return }
                                    let t = date.timeIntervalSince1970
                                    hover = points.min { abs($0.t - t) < abs($1.t - t) }
                                case .ended:
                                    hover = nil
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: Numbers under the chart

    private func stats(_ points: [HistoryPoint]) -> some View {
        let key = spec.series[0].key
        let values = points.compactMap { $0.v[key] }
        let peak = points.max { ($0.v[key] ?? 0) < ($1.v[key] ?? 0) }
        return HStack(spacing: 0) {
            stat(values.isEmpty ? "--" : spec.format(values.reduce(0, +) / Double(values.count)), "AVERAGE")
            stat(peak.flatMap { $0.v[key] }.map(spec.format) ?? "--", peak.map { "PEAK " + timeLabel($0.t).uppercased() } ?? "PEAK")
            stat(values.min().map(spec.format) ?? "--", "LOW")
        }
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(Theme.light(15)).monospacedDigit().foregroundStyle(.white)
            Text(label).font(Theme.caps(7)).kerning(0.5).foregroundStyle(Theme.lime.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    /// Who was behind it over this range, or (for network and disk) how much moved.
    @ViewBuilder
    private func breakdown(_ points: [HistoryPoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spec.topTitle + (spec.top == nil ? "" : " · \(range.title.uppercased())"))
                .font(Theme.caps(7.5)).kerning(0.7).foregroundStyle(Theme.lime.opacity(0.8))
            if let kind = spec.top {
                let users = monitor.store.topOver(span: range.rawValue, now: now, kind: kind)
                let top = max(users.first?.v ?? 1, 0.0001)
                if users.isEmpty {
                    Text("Nothing yet. Apps are recorded every 30 seconds.").font(Theme.light(11)).foregroundStyle(Theme.faint)
                } else {
                    VStack(spacing: 3) {
                        ForEach(users.prefix(4), id: \.n) { user in
                            HStack(spacing: 8) {
                                Text(user.n).font(Theme.regular(11.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(spec.formatTop(user.v)).font(Theme.light(11)).monospacedDigit().foregroundStyle(Theme.dim)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(alignment: .leading) {
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(LinearGradient(colors: [Theme.lime.opacity(0.14), Theme.green.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: geo.size.width * min(1, user.v / top))
                                }
                            }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(spec.series.enumerated()), id: \.offset) { index, series in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.bytes(UInt64(total(points, series.key)))).font(Theme.light(17)).foregroundStyle(.white)
                            Text(series.name.uppercased()).font(Theme.caps(7)).kerning(0.5).foregroundStyle(color(index))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                    }
                }
            }
        }
    }

    // MARK: Helpers

    /// Bytes moved: each rate times the gap to the next point.
    private func total(_ points: [HistoryPoint], _ key: String) -> Double {
        guard points.count > 1 else { return 0 }
        var sum = 0.0
        for (a, b) in zip(points, points.dropFirst()) { sum += (a.v[key] ?? 0) * min(b.t - a.t, range.rawValue > 86400 ? 3700 : 120) }
        return sum
    }

    private func topAt(_ point: HistoryPoint) -> [TopUser]? {
        guard let kind = spec.top else { return nil }
        if let list = point.top?[kind.rawValue] { return list }
        let nearest = monitor.store.minutes.min { abs($0.t - point.t) < abs($1.t - point.t) }
        if let nearest, abs(nearest.t - point.t) < 90, let list = nearest.top?[kind.rawValue] { return list }
        return monitor.store.currentTop[kind.rawValue]
    }

    private func color(_ index: Int) -> Color {
        index == 0 ? Theme.lime : Color(red: 0.45, green: 0.85, blue: 0.95)
    }

    private func timeLabel(_ t: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        let ago = now - t
        if ago < 90 { return "now" }
        if ago > 86400 { return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour()) }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
