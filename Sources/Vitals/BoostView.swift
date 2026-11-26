import AppKit
import SwiftUI

/// Boost: one click to close what you don't need while you work, so Claude and your build
/// get the memory. You tick what may be closed once; Vitals remembers it for next time.
struct BoostView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs
    @ObservedObject private var janitor = SimulatorJanitor.shared
    var back: () -> Void

    @State private var phase: Phase = .ready
    @State private var before: UInt64 = 0
    @State private var simulatorCount = 0

    enum Phase: Equatable { case ready, working, done(freed: Int64) }

    private struct Candidate: Identifiable {
        var id: String          // bundle path
        var name: String
        var memory: UInt64
        var app: AppUsage?
    }

    /// Regular apps that are open but not the one you're using, biggest first.
    private var candidates: [Candidate] {
        let usage = Dictionary(monitor.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        var seen = Set<String>()
        var list: [Candidate] = []
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let path = running.bundleURL?.path, path != front, seen.insert(path).inserted else { continue }
            if path == ProcessScanner.simulatorApp || path.hasSuffix("/Finder.app") { continue }
            let app = usage[path]
            if let app, !Killer.canQuit(app) { continue }
            if app == nil, path.hasSuffix("/Claude.app") || path.hasSuffix("/Vitals.app") { continue }
            list.append(Candidate(id: path, name: running.localizedName ?? (path as NSString).lastPathComponent,
                                  memory: app?.memory ?? 0, app: app))
        }
        return list.sorted { $0.memory > $1.memory }
    }

    private var simulators: AppUsage? { monitor.apps.first { $0.id == ProcessScanner.simulatorsKey } }

    private var selectedBytes: UInt64 {
        let apps = candidates.filter { prefs.boostApps.contains($0.id) }.reduce(UInt64(0)) { $0 + $1.memory }
        let sims = prefs.boostSimulators ? (simulators?.memory ?? 0) : 0
        return apps + sims
    }

    private var pressureBytes: UInt64 { monitor.system.memory.used + monitor.system.memory.swap }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                BackButton(action: back)
                Spacer()
                Label("Boost", systemImage: "bolt.fill").font(Theme.regular(15)).foregroundStyle(Theme.lime)
            }

            memoryMap

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    if let sims = simulators, sims.memory > 0 {
                        section("SIMULATORS")
                        BoostRow(name: "iOS Simulators", detail: "shuts down every running simulator, other sessions included",
                                 memory: sims.memory, icon: ProcessScanner.simulatorApp,
                                 color: Self.simColor, on: prefs.boostSimulators) { prefs.boostSimulators.toggle() }
                    }
                    autoRow
                    section("APPS IN THE BACKGROUND")
                    if candidates.isEmpty {
                        Text("Nothing else is open.").font(Theme.light(11)).foregroundStyle(Theme.dim).padding(.vertical, 6)
                    }
                    ForEach(candidates) { c in
                        BoostRow(name: c.name, detail: nil, memory: c.memory, icon: c.id,
                                 color: colorMap[c.id], on: prefs.boostApps.contains(c.id)) {
                            if prefs.boostApps.contains(c.id) { prefs.boostApps.remove(c.id) } else { prefs.boostApps.insert(c.id) }
                        }
                    }
                    Text("Ticked apps are remembered, so next time Boost is one click. Claude, Finder and Vitals are never closed.")
                        .font(Theme.light(10)).foregroundStyle(Theme.faint)
                        .padding(.top, 8)
                }
            }

            boostButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// The standing rule: simulators go away by themselves when Claude is done with them.
    private var autoRow: some View {
        Button { prefs.autoSimulators.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: prefs.autoSimulators ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(prefs.autoSimulators ? Theme.lime : Theme.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Shut simulators down automatically").font(Theme.regular(12)).foregroundStyle(.white)
                    Text(autoDetail).font(Theme.light(9.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .rowHover(radius: 9)
        }
        .buttonStyle(.plain)
        .pointer()
    }

    private var autoDetail: String {
        var text = "after every Claude session has been idle for \(Int(SimulatorJanitor.idleMinutes)) min"
        if let last = janitor.lastShutdown {
            text += " · last " + last.formatted(date: .omitted, time: .shortened)
        }
        return text
    }

    // MARK: Load map

    static let simColor = LoadMap.simColor

    /// The four biggest background apps get their own colour, shared by the bars and the list.
    private var colorMap: [String: Color] { LoadMap.colors(candidates.prefix(4).map(\.id)) }

    /// CPU, GPU and memory as three stacked bars in the same colours, with one shared legend.
    private var memoryMap: some View {
        let featured = Array(candidates.prefix(4).map(\.id))
        let bars = LoadKind.allCases.map {
            ($0, LoadMap.build($0, monitor: monitor, featured: featured, freeing: prefs.boostApps, simsFreeing: prefs.boostSimulators))
        }
        let memory = bars.last!.1
        let freeing = memory.segments.filter(\.freeing).reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(bars, id: \.0) { kind, bar in
                LoadBarCard(kind: kind, segments: bar.segments, capacity: bar.capacity, total: bar.total, legend: false)
            }
            sharedLegend(bars.map(\.1.segments))
            if freeing > 0 {
                Text("Boost frees about \(Fmt.bytes(UInt64(freeing))) (striped)")
                    .font(Theme.light(10)).foregroundStyle(Theme.lime)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func sharedLegend(_ bars: [[LoadSegment]]) -> some View {
        var order: [LoadSegment] = []
        for seg in bars.flatMap({ $0 }) where !order.contains(where: { $0.id == seg.id }) { order.append(seg) }
        func value(_ id: String, _ i: Int) -> Double { bars[i].first { $0.id == id }?.value ?? 0 }
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 4) {
            ForEach(order) { seg in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(seg.color).frame(width: 7, height: 7)
                    Text(seg.name).font(Theme.light(10)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Text([value(seg.id, 0) > 0.05 ? LoadKind.cpu.format(value(seg.id, 0)) : nil,
                          value(seg.id, 2) > 0 ? LoadKind.memory.format(value(seg.id, 2)) : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.light(9)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
        }
    }

    private var status: some View {
        let m = monitor.system.memory
        return HStack(spacing: 0) {
            stat(Fmt.percent(m.share), "RAM USED", tint: m.pressure >= 2 ? Theme.orange : .white)
            stat(Fmt.bytes(m.swap), "ON DISK (SWAP)", tint: m.swap > 4 << 30 ? Theme.orange : .white)
            stat(Fmt.bytes(m.compressed), "COMPRESSED", tint: .white)
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func stat(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(Theme.light(17)).monospacedDigit().foregroundStyle(tint)
            Text(label).font(Theme.caps(7.5)).kerning(0.6).foregroundStyle(Theme.lime.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Theme.caps(8)).kerning(0.7).foregroundStyle(Theme.dim).padding(.top, 6).padding(.bottom, 2)
    }

    private var boostButton: some View {
        Button(action: boost) {
            HStack(spacing: 8) {
                switch phase {
                case .working:
                    ProgressView().controlSize(.small)
                    Text("Closing…")
                case .done(let freed):
                    Image(systemName: "checkmark")
                    Text(freed > 50 << 20 ? "Freed \(Fmt.bytes(UInt64(freed)))" : "Done")
                case .ready:
                    Image(systemName: "bolt.fill")
                    Text(selectedBytes > 0 ? "Free up \(Fmt.bytes(selectedBytes))" : "Tick what to close")
                }
            }
            .font(Theme.regular(13))
            .foregroundStyle(Theme.base)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.gradient))
            .opacity(phase == .ready && selectedBytes == 0 ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .hoverLift(1.015)
        .disabled(phase == .working || (phase == .ready && selectedBytes == 0))
    }

    private func boost() {
        before = pressureBytes
        phase = .working
        for c in candidates where prefs.boostApps.contains(c.id) {
            NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == c.id }.forEach { $0.terminate() }
        }
        if prefs.boostSimulators, simulators != nil { SimulatorJanitor.shared.shutdownAll() }
        // Give apps time to save and exit, then measure what came back.
        for delay in [2.0, 5.0, 8.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { monitor.tick(forceScan: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.6) {
            phase = .done(freed: Int64(before) - Int64(pressureBytes))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if case .done = phase { phase = .ready } }
        }
    }
}

private struct BoostRow: View {
    var name: String
    var detail: String?
    var memory: UInt64
    var icon: String
    var color: Color? = nil
    var on: Bool
    var toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(on ? Theme.lime : Theme.faint)
                Group {
                    if Icons.exists(icon) {
                        Image(nsImage: Icons.icon(icon)).resizable().interpolation(.high)
                    } else {
                        Image(systemName: icon == ProcessScanner.simulatorApp ? "iphone" : "app.dashed")
                            .font(.system(size: 14)).foregroundStyle(Theme.dim)
                    }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Theme.regular(12)).foregroundStyle(.white).lineLimit(1)
                    if let detail {
                        Text(detail).font(Theme.light(9.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8) }
                Text(memory > 0 ? Fmt.bytes(memory) : "")
                    .font(Theme.regular(12)).monospacedDigit()
                    .foregroundStyle(memory > 1 << 30 ? Theme.orange : .white.opacity(0.8))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Theme.lime.opacity(0.07) : Color.white.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
    }
}

