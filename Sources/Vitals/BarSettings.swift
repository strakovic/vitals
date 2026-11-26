import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pick what the menu bar shows and how often it updates.
struct BarSettings: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                preview
                section("SHOW IN MENU BAR") {
                    VStack(spacing: 0) {
                        ForEach(orderedMetrics) { metric in
                            MetricRow(metric: metric, monitor: monitor, prefs: prefs)
                            if metric != orderedMetrics.last { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 34) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                }
                section("UPDATE EVERY") {
                    Segments(options: [(1.0, "1 s"), (2.0, "2 s"), (5.0, "5 s")], selection: $prefs.interval)
                }
                LoginRow()
                ExportRow(monitor: monitor)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Warning colors").font(Theme.regular(12)).foregroundStyle(.white)
                        Text("Orange or red when hot, full or low").font(Theme.light(10)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    LimeSwitch(isOn: $prefs.colorAlerts)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    /// Enabled metrics first, in bar order, then the rest.
    private var orderedMetrics: [Metric] {
        (prefs.bar + Metric.allCases.filter { !prefs.bar.contains($0) })
            .filter { $0 != .battery || monitor.system.power.hasBattery }   // desktop Macs have none
    }

    private var preview: some View {
        HStack {
            Spacer()
            Image(nsImage: BarRenderer.render(monitor, prefs: prefs, dark: true))
                .interpolation(.high)
            Image(systemName: "wifi").font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
            Text(Date.now.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(alignment: .topLeading) {
            Text("PREVIEW").font(Theme.caps(7)).kerning(0.6).foregroundStyle(Theme.faint).offset(x: 10, y: -12)
        }
        .padding(.top, 12)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.caps(8)).kerning(0.8).foregroundStyle(Theme.lime.opacity(0.8)).padding(.leading, 4)
            content()
        }
    }
}

private struct MetricRow: View {
    let metric: Metric
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs

    var body: some View {
        let on = prefs.bar.contains(metric)
        let index = prefs.bar.firstIndex(of: metric)
        HStack(spacing: 10) {
            Image(systemName: metric.symbol)
                .font(.system(size: 11))
                .foregroundStyle(on ? Theme.lime : Theme.faint)
                .frame(width: 16)
            Text(metric.title).font(Theme.regular(12)).foregroundStyle(on ? .white : .white.opacity(0.6))
            Spacer()
            Text(monitor.barValue(metric)).font(Theme.light(11)).monospacedDigit().foregroundStyle(Theme.dim)
            if on, let index {
                HStack(spacing: 0) {
                    arrow("chevron.up", enabled: index > 0) { prefs.move(metric, by: -1) }
                    arrow("chevron.down", enabled: index < prefs.bar.count - 1) { prefs.move(metric, by: 1) }
                }
            }
            LimeSwitch(isOn: Binding(get: { on }, set: { _ in prefs.toggle(metric) }))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.2), value: on)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
                .frame(width: 16, height: 18)
                .foregroundStyle(enabled ? Theme.dim : Theme.faint.opacity(0.4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct Segments<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { option in
                SegmentButton(title: option.1, selected: selection == option.0) { selection = option.0 }
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.card))
    }
}

private struct SegmentButton: View {
    var title: String
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.regular(11.5))
                .foregroundStyle(selected ? Theme.base : .white.opacity(hovering ? 0.95 : 0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(hovering ? 0.07 : 0))))
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointer()
    }
}

struct LimeSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.12)))
                Circle().fill(isOn ? Theme.base : Color.white.opacity(0.7)).padding(2.5)
            }
            .frame(width: 30, height: 17)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        }
        .buttonStyle(.plain)
        .hoverLift(1.06)
    }
}

/// "Open at login", with the state macOS actually has.
private struct LoginRow: View {
    @State private var on = LoginItem.isOn
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open at login").font(Theme.regular(12)).foregroundStyle(.white)
                Text(LoginItem.hasLaunchAgent ? "Set up by build.sh install" : "Always in your menu bar after a restart")
                    .font(Theme.light(10)).foregroundStyle(Theme.faint)
            }
            Spacer()
            LimeSwitch(isOn: Binding(get: { on }, set: { value in
                LoginItem.set(value)
                on = LoginItem.isOn
            }))
            .disabled(LoginItem.hasLaunchAgent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }
}

/// Saves everything Vitals has recorded as a CSV file.
private struct ExportRow: View {
    var monitor: Monitor
    @State private var saved: String?
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export all history").font(Theme.regular(12)).foregroundStyle(.white)
                Text(saved ?? "CSV for Numbers, Excel or Sheets: every hour, minute and sample kept")
                    .font(Theme.light(10)).foregroundStyle(saved == nil ? Theme.faint : Theme.lime.opacity(0.85)).lineLimit(1)
            }
            Spacer()
            QuietButton(title: "Export…", symbol: "square.and.arrow.up", size: 11) { export() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func export() {
        let panel = NSSavePanel()
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Vitals history \(day).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitor.store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            saved = "Saved \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            saved = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
