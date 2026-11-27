import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable { case apps, claude, bar }

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs
    @ObservedObject private var awake = KeepAwake.shared
    @State var tab: PanelTab = .apps
    @State var detail: Metric?
    @State var boosting = false
    @State private var appOrder = StableOrder<String>()
    @State private var holdingList = false
    /// While the pointer is on the live chart: how many samples back it points.
    @State private var chartBack: Int?
    var quit: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
            if boosting {
                BoostView(monitor: monitor, prefs: prefs, back: { withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { boosting = false } })
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else if let detail {
                DetailView(metric: detail, monitor: monitor, back: { open(nil) })
                    .id(detail)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            } else {
                overview
                    .transition(.opacity)
            }
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(width: 392, height: 668, alignment: .top)
        .background(background)
        .preferredColorScheme(.dark)
    }

    private func open(_ metric: Metric?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { detail = metric }
    }

    private var overview: some View {
        VStack(spacing: 0) {
            liveCard
                .padding(.horizontal, 14)
                .padding(.top, 12)
            statsStrip
                .padding(.horizontal, 14)
                .padding(.top, 8)
            tabs
                .padding(.horizontal, 14)
                .padding(.top, 12)
            Group {
                switch tab {
                case .apps: appsList
                case .claude: claudeList
                case .bar: BarSettings(monitor: monitor, prefs: prefs)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        }
    }

    private var background: some View {
        ZStack {
            Theme.base
            RadialGradient(colors: [Theme.lime.opacity(0.09), .clear], center: .init(x: 0.15, y: 0), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Theme.green.opacity(0.08), .clear], center: .init(x: 1, y: 0.25), startRadius: 0, endRadius: 260)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.gradient).frame(width: 7, height: 7)
            Text("VITALS").font(Theme.caps(13)).foregroundStyle(Theme.lime).kerning(1)
            Spacer()
            if awake.isOn {
                Chip(text: "AWAKE", color: Theme.lime, symbol: "cup.and.saucer.fill")
                    .help("\(awake.duration): \(awake.reason)")
                    .clickable(radius: 12) { withAnimation { detail = nil; boosting = false; tab = .bar } }
            }
            if monitor.system.thermalState != .nominal {
                // Only worth a chip when it isn't cool.
                Chip(text: thermalText, color: thermalColor, symbol: "flame").clickable(radius: 12) { open(.temp) }
            }
            if !boosting {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { detail = nil; boosting = true }
                } label: {
                    Label("Boost", systemImage: "bolt.fill")
                        .font(Theme.regular(11.5))
                        .foregroundStyle(Theme.base)
                        .padding(.horizontal, 12).padding(.vertical, 4.5)
                        .background(Capsule().fill(Theme.gradient))
                        .shadow(color: Theme.lime.opacity(0.25), radius: 6)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .hoverLift()
                .help("Close what you don't need so Claude gets the memory")
                .transition(.opacity)
            }
        }
        .frame(height: 24)
    }

    private var thermalText: String {
        switch monitor.system.thermalState {
        case .nominal: "COOL"
        case .fair: "WARM"
        case .serious: "HOT"
        case .critical: "THROTTLING"
        @unknown default: "OK"
        }
    }

    private var thermalColor: Color {
        switch monitor.system.thermalState {
        case .nominal: Theme.lime
        case .fair: Theme.orange.opacity(0.9)
        default: Theme.red
        }
    }

    // MARK: Live chart

    static let cpuColor = Theme.lime
    static let gpuColor = Color(red: 0.45, green: 0.68, blue: 1)
    static let ramColor = Color(red: 0.74, green: 0.55, blue: 1)

    private var ramColor: Color {
        let p = monitor.system.memory.pressure
        return p >= 4 ? Theme.red : p >= 2 ? Theme.orange : Self.ramColor
    }

    private func past(_ metric: Metric) -> Double? {
        guard let back = chartBack, let values = monitor.history[metric], values.count > back else { return nil }
        return values[values.count - 1 - back]
    }

    /// CPU, GPU and memory on one chart, with the three numbers above it and the cores below.
    private var liveCard: some View {
        let s = monitor.system
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                LiveStat(label: "CPU", value: Fmt.percent(past(.cpu) ?? s.cpu),
                         caption: chartBack.map(Ago.text) ?? "\(s.cores.count) cores", color: Self.cpuColor, past: chartBack != nil)
                    .clickable(inset: -6) { open(.cpu) }
                LiveStat(label: "GPU", value: Fmt.percent(past(.gpu) ?? s.gpu),
                         caption: chartBack.map(Ago.text) ?? Fmt.bytes(s.gpuMemory) + " used", color: Self.gpuColor, past: chartBack != nil)
                    .clickable(inset: -6) { open(.gpu) }
                LiveStat(label: "MEMORY", value: Fmt.percent(past(.ram) ?? s.memory.share),
                         caption: chartBack.map(Ago.text) ?? "\(Fmt.bytes(s.memory.used)) of \(Int((Double(s.memory.total) / 1_073_741_824).rounded())) GB",
                         color: ramColor, past: chartBack != nil)
                    .clickable(inset: -6) { open(.ram) }
            }
            SharedChart(series: [
                .init(label: "Memory", values: monitor.normalizedHistory(.ram), color: ramColor),
                .init(label: "GPU", values: monitor.normalizedHistory(.gpu), color: Self.gpuColor),
                .init(label: "CPU", values: monitor.normalizedHistory(.cpu), color: Self.cpuColor),
            ], back: $chartBack)
            .frame(height: 66)
            HStack(spacing: 8) {
                Text("CORES").font(Theme.caps(6.5)).kerning(0.5).foregroundStyle(Theme.faint).fixedSize()
                cores
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private var cores: some View {
        let s = monitor.system
        return HStack(spacing: 3) {
            ForEach(Array(s.cores.enumerated()), id: \.offset) { index, value in
                let efficiency = index < s.efficiencyCores
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    GeometryReader { geo in
                        Capsule()
                            .fill(efficiency ? AnyShapeStyle(Theme.green.opacity(0.95)) : AnyShapeStyle(Theme.gradient))
                            .frame(width: max(3, geo.size.width * value))
                    }
                }
                .frame(height: 4)
            }
        }
        .animation(.easeOut(duration: 0.4), value: s.cores)
        .help("How busy each processor core is: 4 efficiency cores (green), then 4 performance cores")
        .clickable(inset: -5, radius: 7) { open(.cpu) }
    }

    /// Temperature, power, network and battery in one slim card. Each graph sits under its number.
    private var statsStrip: some View {
        let s = monitor.system
        let p = s.power
        let batteryTemp = p.batteryTemp > 0 ? p.batteryTemp : s.batteryTemp
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                MiniStat(label: "TEMP", value: s.cpuTemp > 0 ? "\(Int(s.cpuTemp.rounded()))°" : "--",
                         history: monitor.normalizedHistory(.temp),
                         raw: monitor.history[.temp] ?? [], format: { "\(Int($0.rounded()))°" },
                         tint: s.cpuTemp >= 95 ? Theme.red : s.cpuTemp >= 85 ? Theme.orange : Theme.lime)
                    .clickable(inset: 3, radius: 9) { open(.temp) }
                // Desktop Macs without a battery may not report power at all; then the cell steps aside.
                if p.hasBattery || p.systemWatts > 0 {
                    divider
                    MiniStat(label: "POWER", value: p.systemWatts > 0 ? Fmt.watts(p.systemWatts) : "--",
                             history: monitor.normalizedHistory(.power),
                             raw: monitor.history[.power] ?? [], format: { Fmt.watts($0) }, tint: Theme.lime)
                        .clickable(inset: 3, radius: 9) { open(.power) }
                }
                divider
                MiniStat(label: "NETWORK", value: Fmt.rate(s.netIn + s.netOut),
                         history: monitor.normalizedHistory(.net),
                         raw: monitor.history[.net] ?? [], format: { Fmt.rate($0) }, tint: Theme.lime)
                    .clickable(inset: 3, radius: 9) { open(.net) }
                divider
                if p.hasBattery {
                    batteryCell(p, temp: batteryTemp)
                        .clickable(inset: 3, radius: 9) { open(.battery) }
                } else {
                    // iMac, Mac mini, Mac Studio, Mac Pro: no battery, so disk activity takes its place.
                    MiniStat(label: "DISK", value: Fmt.rate(s.diskRead + s.diskWrite),
                             history: monitor.normalizedHistory(.disk),
                             raw: monitor.history[.disk] ?? [], format: { Fmt.rate($0) }, tint: Theme.lime)
                        .clickable(inset: 3, radius: 9) { open(.disk) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if p.hasBattery, batteryTemp >= 36 { heatNote(batteryTemp) }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Charge, whether macOS is holding it at its limit, in the same shape as the others.
    private func batteryCell(_ p: PowerInfo, temp: Double) -> some View {
        let limit = ChargeLimit.current()
        let state = p.held ? "held at \(limit.map { "\($0)%" } ?? "limit")"
            : p.charging ? "charging" + (limit.map { " to \($0)%" } ?? "")
            : p.pluggedIn ? "full" : "on battery"
        let color: Color = p.charging || p.held ? Theme.lime : .white.opacity(0.88)
        return VStack(alignment: .leading, spacing: 3) {
            Text("BATTERY").font(Theme.caps(7)).kerning(0.6).foregroundStyle(Theme.lime.opacity(0.9))
            HStack(spacing: 5) {
                Text("\(Int(p.batteryPercent))%").font(Theme.light(15)).monospacedDigit().foregroundStyle(.white)
                BatteryGlyph(level: p.batteryPercent / 100, color: color, bolt: p.charging)
                    .scaleEffect(0.75, anchor: .leading)
                    .frame(width: 22, alignment: .leading)
            }
            Text(state).font(Theme.light(8.5)).foregroundStyle(p.held ? Theme.lime.opacity(0.8) : Theme.faint).lineLimit(1)
                .frame(height: 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .help("Health \(p.health > 0 ? "\(Int((p.health * 100).rounded()))%" : "--") · \(p.cycleCount) cycles · \(temp > 0 ? "\(Int(temp.rounded()))°" : "--")"
              + (limit.map { "\nmacOS stops charging at \($0)% (System Settings > Battery)" } ?? ""))
    }

    /// Shown only when the battery is warm: how hot, and which app is working hardest.
    private func heatNote(_ temp: Double) -> some View {
        let busiest = monitor.apps.max { $0.cpu + $0.gpu < $1.cpu + $1.gpu }
        let hot = temp >= 40
        return HStack(spacing: 6) {
            Image(systemName: "flame.fill").font(.system(size: 9))
            Text("Battery \(Int(temp.rounded()))°" + (hot ? ", too warm" : ", warm")).font(Theme.regular(10.5))
            Spacer(minLength: 4)
            if let busiest, busiest.cpu + busiest.gpu >= 5 {
                Text("busiest: \(busiest.name) \(Int(busiest.cpu.rounded()))%")
                    .font(Theme.light(10)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .foregroundStyle(hot ? Theme.red : Theme.orange)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Rectangle().fill((hot ? Theme.red : Theme.orange).opacity(0.08)))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .help("Heat wears a battery fastest. Close what you don't need, or give the Mac some air.")
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 10)
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 4) {
            TabPill(title: "Apps", selected: tab == .apps) { tab = .apps }
            TabPill(title: "AI", badge: busyCount > 0 ? "\(busyCount)" : nil, selected: tab == .claude) { tab = .claude }
            TabPill(title: "Settings", selected: tab == .bar) { tab = .bar }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    private var busyCount: Int { monitor.sessions.filter(\.isBusy).count }

    // MARK: Apps

    private var sortedApps: [AppUsage] { sorted(monitor.apps) }

    private func sorted(_ list: [AppUsage]) -> [AppUsage] {
        let ram = Double(max(1, monitor.system.memory.total))
        return list.sorted { $0.load(ram: ram) > $1.load(ram: ram) }
    }

    private var appsList: some View {
        VStack(spacing: 4) {
            // One table, everything together, heaviest first. Column titles instead of filters.
            HStack(spacing: 0) {
                Group {
                    if holdingList {
                        Label("ORDER HELD", systemImage: "pause.fill").foregroundStyle(Theme.lime.opacity(0.85))
                    } else {
                        Text("BY LOAD ON YOUR MAC").foregroundStyle(Theme.dim)
                    }
                }
                .font(Theme.caps(7.5)).kerning(0.6)
                Spacer()
                ForEach(AppColumn.allCases, id: \.self) { column in
                    Text(column.title).font(Theme.caps(7.5)).kerning(0.6).foregroundStyle(Theme.dim)
                        .frame(width: column.width, alignment: .trailing)
                }
                Color.clear.frame(width: AppColumn.stopWidth, height: 1)
            }
            .padding(.leading, 18).padding(.trailing, 18)

            if monitor.apps.isEmpty {
                Placeholder(symbol: "waveform.path.ecg", text: "Measuring…")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    let apps = displayedApps
                    let ram = Double(max(1, monitor.system.memory.total))
                    VStack(spacing: 2) {
                        ForEach(apps) { app in
                            AppRow(app: app, ram: ram, refresh: refresh)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onHover { inside in
                    holdingList = inside
                    if !inside { reorderApps(force: false) }
                }
            }
        }
        .onReceive(monitor.$apps) { reorderApps(force: false, apps: $0) }
    }

    /// Rows in a calm order: held while the pointer is on the list, otherwise re-ranked every 4 s.
    private var displayedApps: [AppUsage] {
        let byId = Dictionary(uniqueKeysWithValues: monitor.apps.map { ($0.id, $0) })
        let ordered = appOrder.ids.isEmpty ? sortedApps.map(\.id) : appOrder.ids
        return Array(ordered.lazy.compactMap { byId[$0] }.prefix(25))
    }

    private func reorderApps(force: Bool, apps: [AppUsage]? = nil) {
        let ranked = sorted(apps ?? monitor.apps).map(\.id)
        var order = appOrder
        if order.update(ranked, frozen: holdingList, every: 4, force: force) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) { appOrder = order }
        } else {
            appOrder = order
        }
    }

    private func refresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { monitor.tick(forceScan: true) }
    }

    // MARK: Claude

    /// AI desktop apps that are running (ChatGPT, Cursor, Ollama...), biggest first.
    private var aiApps: [AppUsage] {
        monitor.apps.filter { AITool.apps.contains($0.name) && $0.id != "claude-code" }.sorted { $0.memory > $1.memory }
    }

    /// Every coding agent at work, grouped by tool, then AI apps.
    private var claudeList: some View {
        let sessions = monitor.sessions
        let apps = aiApps
        return Group {
            if sessions.isEmpty && apps.isEmpty {
                Placeholder(symbol: "sparkle", text: "No AI agents or AI apps running")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(AITool.allCases, id: \.self) { tool in
                            let group = sessions.filter { $0.tool == tool }
                            if !group.isEmpty {
                                sectionTitle(tool.title, detail: "\(group.filter(\.isBusy).count) of \(group.count) working")
                                ForEach(group) { session in
                                    SessionCard(session: session, refresh: refresh)
                                }
                            }
                        }
                        if !apps.isEmpty {
                            sectionTitle("AI APPS", detail: "\(apps.count) open")
                            let ram = Double(max(1, monitor.system.memory.total))
                            ForEach(apps) { app in
                                AppRow(app: app, ram: ram, refresh: refresh)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title.uppercased()).font(Theme.caps(7.5)).kerning(0.6).foregroundStyle(Theme.lime.opacity(0.8))
            Spacer()
            Text(detail).font(Theme.light(9.5)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 4).padding(.top, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            QuietButton(title: "Activity Monitor", symbol: "arrow.up.forward.app") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Spacer()
            QuietButton(title: "Quit", action: quit)
        }
        .padding(.horizontal, -8)
    }
}

// MARK: - Pieces

struct Chip: View {
    var text: String
    var color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)) }
            Text(text).font(Theme.caps(8.5)).kerning(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// A small battery outline filled to its level.
struct BatteryGlyph: View {
    var level: Double
    var color: Color
    var bolt = false
    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5).stroke(Color.white.opacity(0.4), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2).fill(color)
                    .frame(width: max(2, 19 * min(1, max(0, level))))
                    .padding(2)
                if bolt {
                    Image(systemName: "bolt.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.base)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(width: 25, height: 13)
            RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.4)).frame(width: 2, height: 5)
        }
    }
}

/// One of the three numbers above the shared chart.
struct LiveStat: View {
    var label: String
    var value: String
    var caption: String
    var color: Color
    var past = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(Theme.caps(8)).kerning(0.7).foregroundStyle(color)
            }
            Text(value).font(Theme.light(24)).monospacedDigit().foregroundStyle(past ? color : .white)
            Text(caption).font(Theme.light(9.5)).foregroundStyle(past ? color.opacity(0.7) : Theme.dim).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// "now", "40 s ago", "2 min 10 s ago" for a point `back` samples before the newest.
enum Ago {
    static func text(_ back: Int) -> String {
        let secs = Int((Double(back) * Prefs.shared.interval).rounded())
        if secs < 2 { return "now" }
        if secs < 60 { return "\(secs) s ago" }
        return secs % 60 == 0 ? "\(secs / 60) min ago" : "\(secs / 60) min \(secs % 60) s ago"
    }
}

/// Several 0...1 series drawn on one chart with light guide lines at 25, 50 and 75 percent.
/// Hovering shows a guide line and dots; the numbers above the chart switch to that moment.
struct SharedChart: View {
    struct Series {
        var label: String
        var values: [Double]
        var color: Color
        var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    }
    var series: [Series]
    var length = 90
    /// Samples back from the newest that the pointer is on; the numbers above follow it.
    @Binding var back: Int?
    /// Snapshots can set VITALS_HOVER=<x> to render the hover state.
    @State private var hoverX: CGFloat? = ProcessInfo.processInfo.environment["VITALS_HOVER"].flatMap(Double.init).map { CGFloat($0) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = w / CGFloat(max(1, length - 1))
            ZStack(alignment: .topLeading) {
                ForEach([0.25, 0.5, 0.75], id: \.self) { level in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h * (1 - level)))
                        p.addLine(to: CGPoint(x: w, y: h * (1 - level)))
                    }
                    .stroke(Color.white.opacity(level == 0.5 ? 0.08 : 0.045), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).offset(y: h - 1)
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    let pts = points(item.values, w: w, h: h)
                    if pts.count > 1 {
                        Path { p in
                            p.move(to: CGPoint(x: pts[0].x, y: h))
                            pts.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: pts.last!.x, y: h))
                            p.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [item.color.opacity(0.16), item.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                        Path { p in p.addLines(pts) }
                            .stroke(item.color.opacity(hoverX == nil ? 0.95 : 0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        if hoverX == nil {
                            Circle().fill(item.color).frame(width: 5, height: 5)
                                .shadow(color: item.color.opacity(0.7), radius: 4)
                                .position(pts.last!)
                        }
                    }
                }
                if let hoverX, let back = backIndex(hoverX, w: w, step: step) {
                    let x = w - step * CGFloat(back)
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: h).position(x: x, y: h / 2)
                    ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                        if let v = value(item.values, back: back) {
                            Circle().fill(item.color).frame(width: 6, height: 6)
                                .overlay(Circle().stroke(Theme.base, lineWidth: 1.5))
                                .position(x: x, y: 2 + (h - 4) * (1 - CGFloat(min(1, max(0, v)))))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverX = location.x
                    back = backIndex(location.x, w: w, step: step)
                case .ended:
                    hoverX = nil
                    back = nil
                }
            }
            .onAppear { if let hoverX { back = backIndex(hoverX, w: w, step: step) } }
        }
    }

    /// How many samples before the newest the pointer is on, if there is data there.
    private func backIndex(_ x: CGFloat, w: CGFloat, step: CGFloat) -> Int? {
        let back = Int(((w - x) / step).rounded())
        let available = (series.map { min($0.values.count, length) }.max() ?? 0) - 1
        guard available >= 0 else { return nil }
        return min(max(0, back), available)
    }

    private func value(_ values: [Double], back: Int) -> Double? {
        let i = values.count - 1 - back
        return values.indices.contains(i) ? values[i] : nil
    }

    /// Newest point on the right edge; a short history starts part way in, so the time axis stays fixed.
    private func points(_ values: [Double], w: CGFloat, h: CGFloat) -> [CGPoint] {
        let recent = Array(values.suffix(length))
        let step = w / CGFloat(max(1, length - 1))
        let start = w - step * CGFloat(recent.count - 1)
        return recent.enumerated().map { i, v in
            CGPoint(x: start + CGFloat(i) * step, y: 2 + (h - 4) * (1 - CGFloat(min(1, max(0, v)))))
        }
    }
}

/// A compact stat: label, number, and its graph underneath. Hovering the graph shows that moment.
struct MiniStat: View {
    var label: String
    var value: String
    var history: [Double]
    var raw: [Double] = []
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var tint: Color
    @State private var hover: Int?

    var body: some View {
        let recent = Array(raw.suffix(60))
        let hovered = hover.flatMap { recent.indices.contains($0) ? recent[$0] : nil }
        VStack(alignment: .leading, spacing: 3) {
            Text(hover.map { Ago.text(recent.count - 1 - $0).uppercased() } ?? label)
                .font(Theme.caps(7)).kerning(0.6).foregroundStyle(tint.opacity(hover == nil ? 0.9 : 0.6)).lineLimit(1)
            Text(hovered.map(format) ?? value).font(Theme.light(15)).monospacedDigit()
                .foregroundStyle(hovered == nil ? .white : tint).lineLimit(1).minimumScaleFactor(0.7)
            Sparkline(values: history, tint: tint, highlight: hover)
                .frame(height: 12)
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle())
                            .onContinuousHover { phase in
                                let count = min(60, history.count)
                                switch phase {
                                case .active(let p) where count > 1:
                                    let step = geo.size.width / CGFloat(count - 1)
                                    hover = min(count - 1, max(0, Int((p.x / step).rounded())))
                                default: hover = nil
                                }
                            }
                    }
                    .padding(.vertical, -8)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var highlight: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let points = Array(values.suffix(60))
            let step = geo.size.width / CGFloat(max(1, points.count - 1))
            let y = { (v: Double) in geo.size.height * (1 - CGFloat(min(1, max(0, v)))) }
            let path = Path { p in
                for (i, v) in points.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) * step, y: y(v))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
            }
            if points.count > 1 {
                path.applying(.identity)
                    .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                Path { p in
                    p.addPath(path)
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                if let i = highlight, points.indices.contains(i) {
                    let x = CGFloat(i) * step
                    Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: geo.size.height + 6)
                        .position(x: x, y: geo.size.height / 2)
                    Circle().fill(tint).frame(width: 5, height: 5)
                        .overlay(Circle().stroke(Theme.base, lineWidth: 1.2))
                        .position(x: x, y: y(points[i]))
                }
            }
        }
    }
}

struct TabPill: View {
    var title: String
    var badge: String?
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(Theme.regular(12))
                if let badge {
                    Text(badge).font(Theme.caps(8)).foregroundStyle(Theme.base)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(selected ? Theme.base.opacity(0.0) : Theme.lime))
                        .overlay(Capsule().stroke(selected ? Theme.base.opacity(0.5) : .clear, lineWidth: 1))
                }
            }
            .foregroundStyle(selected ? Theme.base : .white.opacity(hovering ? 0.95 : 0.7))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(hovering ? 0.07 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

struct Placeholder: View {
    var symbol: String
    var text: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(Theme.lime.opacity(0.6))
            Text(text).font(Theme.light(12)).foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Icons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        cache[path] = image
        return image
    }
    private static var existing: [String: Bool] = [:]
    static func exists(_ path: String) -> Bool {
        if let known = existing[path] { return known }
        let found = FileManager.default.fileExists(atPath: path)
        existing[path] = found
        return found
    }
}

enum StopState { case none, stopping, stuck }

/// The small quit control at the end of a row: an x on hover, a spinner while it goes,
/// and a red "Force" if it is still alive a few seconds later.
struct StopButton: View {
    var state: StopState
    var visible: Bool
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            switch state {
            case .stopping:
                ProgressView().controlSize(.mini).frame(width: 18, height: 18)
            case .stuck:
                Button(action: action) {
                    // One line, always: the pill grows to the left over the row instead of wrapping.
                    Text("FORCE").font(Theme.caps(7)).kerning(0.5)
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.red))
                        .shadow(color: Theme.red.opacity(0.45), radius: 6)
                }
                .buttonStyle(.plain)
                .pointer()
                .help("Still running. Click to force quit")
            case .none:
                Button(action: action) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(hovering ? .white : Theme.dim)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(hovering ? Color.red.opacity(0.7) : Color.white.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(help)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
            }
        }
        .frame(minWidth: 18, alignment: .trailing)
    }
}

enum AppColumn: CaseIterable {
    case cpu, memory, gpu
    var title: String { switch self { case .cpu: "CPU"; case .memory: "MEMORY"; case .gpu: "GPU" } }
    var width: CGFloat { switch self { case .cpu: 46; case .memory: 62; case .gpu: 40 } }
    static let stopWidth: CGFloat = 24
}

extension AppUsage {
    /// One number for "how much is this costing my Mac": CPU share of the chip, plus GPU,
    /// plus its share of RAM, weighted so a busy app outranks a merely big one.
    func load(ram: Double) -> Double { cpu + gpu * 0.6 + Double(memory) / ram * 100 * 0.4 }
}

struct AppRow: View {
    var app: AppUsage
    var ram: Double
    var refresh: () -> Void = {}
    @State private var hovering = false
    @State private var stopping: StopState = ProcessInfo.processInfo.environment["VITALS_STUCK"] != nil ? .stuck : .none   // snapshots can show the force state

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let path = app.iconPath, Icons.exists(path) {
                    Image(nsImage: Icons.icon(path)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                }
            }
            .frame(width: 22, height: 22)
            .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(app.name).font(Theme.regular(12)).foregroundStyle(.white).lineLimit(1)
                    if app.isClaude {
                        Image(systemName: "sparkle").font(.system(size: 8)).foregroundStyle(Theme.lime)
                    }
                }
                if app.processes > 1 {
                    Text("\(app.processes) processes").font(Theme.light(9.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 6)

            cell(String(format: app.cpu < 10 ? "%.1f%%" : "%.0f%%", app.cpu),
                 heat: app.cpu / 40, width: AppColumn.cpu.width)
            cell(Fmt.bytes(app.memory), heat: Double(app.memory) / ram * 4, width: AppColumn.memory.width)
            cell(app.gpu >= 0.5 ? String(format: "%.0f%%", app.gpu) : "–",
                 heat: app.gpu / 50, width: AppColumn.gpu.width)
                .opacity(stopping == .stuck ? 0 : 1)   // the Force pill sits here

            StopButton(state: stopping, visible: hovering && Killer.canQuit(app), help: "Quit \(app.name)") {
                switch stopping {
                case .none:
                    Killer.quit(app)
                    stopping = .stopping
                    refresh()
                    let pids = app.ownPids
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if stopping == .stopping, Killer.isAlive(pids) { stopping = .stuck }
                    }
                case .stuck:
                    Killer.force(app)
                    stopping = .stopping
                    refresh()
                case .stopping: break
                }
            }
            .frame(width: AppColumn.stopWidth, alignment: .trailing)
        }
        .opacity(stopping == .stopping ? 0.45 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0.025)))
        .onHover { hovering = $0 }
    }

    /// A value in a column: dim when it's nothing, white normally, orange then red as it gets heavy.
    private func cell(_ text: String, heat: Double, width: CGFloat) -> some View {
        Text(text)
            .font(Theme.regular(11.5)).monospacedDigit()
            .foregroundStyle(heat >= 1 ? Theme.red : heat >= 0.45 ? Theme.orange : heat < 0.02 ? Theme.faint : .white.opacity(0.88))
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
}

struct SessionCard: View {
    var session: ClaudeSession
    var refresh: () -> Void = {}
    @State private var showBackground = false
    @State private var hovering = false
    @State private var stopping: StopState = .none
    @State private var order = StableOrder<pid_t>()

    private var statusColor: Color {
        switch session.status {
        case "busy": Theme.lime
        case "waiting": Theme.orange
        default: Color.white.opacity(0.3)
        }
    }

    var body: some View {
        let byPid = Dictionary(session.tasks.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let tasks = order.ids.isEmpty ? session.tasks : order.ids.compactMap { byPid[$0] }
        let active = tasks.filter { !$0.isBackground }
        let background = tasks.filter(\.isBackground)
        VStack(alignment: .leading, spacing: 3) {
            // One line: status, name, what it costs, state.
            HStack(spacing: 7) {
                StatusDot(color: statusColor, pulsing: session.isBusy)
                Text(session.name).font(Theme.regular(12)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 6)
                Metric3(cpu: session.cpu, memory: session.memory, gpu: session.gpu)
                    .font(Theme.light(10)).monospacedDigit()
                Text(session.status.uppercased()).font(Theme.caps(7)).kerning(0.5).foregroundStyle(statusColor)
                    .frame(width: 40, alignment: .trailing)
                StopButton(state: stopping, visible: hovering, help: "End this \(session.tool.title) session") {
                    switch stopping {
                    case .none:
                        Killer.stop(session)
                        stopping = .stopping
                        refresh()
                        let pids = [session.pid]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if stopping == .stopping, Killer.isAlive(pids) { stopping = .stuck }
                        }
                    case .stuck:
                        Killer.forceStop(session)
                        stopping = .stopping
                        refresh()
                    case .stopping: break
                    }
                }
                .scaleEffect(0.9)
            }
            // Where and how long, and the helpers toggle, in one small line.
            HStack(spacing: 5) {
                Text((session.folder as NSString).lastPathComponent).lineLimit(1)
                if let started = session.startedAt {
                    Text("·")
                    Text(Fmt.age(Date().timeIntervalSince(started)))
                }
                if !background.isEmpty {
                    Text("·")
                    Button { withAnimation(.easeOut(duration: 0.2)) { showBackground.toggle() } } label: {
                        HStack(spacing: 3) {
                            Text("\(background.count) \(background.count == 1 ? "helper" : "helpers")")
                            Image(systemName: showBackground ? "chevron.up" : "chevron.down").font(.system(size: 6.5, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .pointer()
                }
                Spacer(minLength: 0)
            }
            .font(Theme.light(9.5))
            .foregroundStyle(Theme.faint)
            .padding(.leading, 20)

            if !active.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(active.prefix(5)) { task in TaskRow(task: task, refresh: refresh) }
                }
                .padding(.leading, 20)
                .padding(.top, 2)
            }
            if showBackground && !background.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(background) { task in TaskRow(task: task, dim: true, refresh: refresh) }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.card.opacity(hovering ? 1.6 : 1)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(session.isBusy ? Theme.lime.opacity(hovering ? 0.4 : 0.26) : Theme.hairline.opacity(hovering ? 2 : 1), lineWidth: 1))
        .animation(.easeOut(duration: 0.16), value: hovering)
        .opacity(stopping == .stopping ? 0.45 : 1)
        .onHover { hovering = $0 }
        .onAppear { order.update(session.tasks.map(\.pid), frozen: false, every: 0) }
        .onChange(of: session.tasks.map(\.pid)) { _, ranked in
            var next = order
            if next.update(ranked, frozen: hovering, every: 4) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { order = next }
            } else { order = next }
        }
    }
}

struct Metric3: View {
    var cpu: Double
    var memory: UInt64
    var gpu: Double
    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%.0f%%", cpu)).monospacedDigit()
            Text(Fmt.bytes(memory))
            if gpu >= 1 { Text(String(format: "GPU %.0f%%", gpu)) }
        }
        .foregroundStyle(.white.opacity(0.7))
    }
}

struct TaskRow: View {
    var task: ClaudeTask
    var dim = false
    var refresh: () -> Void = {}
    @State private var hovering = false
    @State private var stopping: StopState = .none
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: dim ? "server.rack" : "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(dim ? Theme.faint : Theme.lime.opacity(0.8))
                .frame(width: 12)
            Text(task.command)
                .font(Theme.mono(9.5))
                .foregroundStyle(.white.opacity(dim ? 0.4 : 0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(Fmt.age(task.age)).font(Theme.light(9.5)).foregroundStyle(Theme.faint)
            Text(String(format: task.cpu < 10 ? "%.1f%%" : "%.0f%%", task.cpu))
                .font(Theme.regular(10)).monospacedDigit()
                .foregroundStyle(task.cpu > 12 ? Theme.orange : .white.opacity(0.7))
                .frame(width: 34, alignment: .trailing)
            StopButton(state: stopping, visible: hovering, help: "Stop this task") {
                switch stopping {
                case .none:
                    Killer.stop(task)
                    stopping = .stopping
                    refresh()
                    let pids = task.pids + [task.pid]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if stopping == .stopping, Killer.isAlive(pids) { stopping = .stuck }
                    }
                case .stuck:
                    Killer.forceStop(task)
                    stopping = .stopping
                    refresh()
                case .stopping: break
                }
            }
            .scaleEffect(0.75)
            .frame(height: 15)
        }
        .opacity(stopping == .stopping ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct StatusDot: View {
    var color: Color
    var pulsing: Bool
    @State private var phase = false
    var body: some View {
        ZStack {
            if pulsing {
                Circle().fill(color.opacity(0.35))
                    .frame(width: 13, height: 13)
                    .scaleEffect(phase ? 1 : 0.5)
                    .opacity(phase ? 0 : 1)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 13, height: 13)
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = true }
        }
    }
}
