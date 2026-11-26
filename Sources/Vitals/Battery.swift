import AppKit
import SwiftUI
import UserNotifications

/// Talks to macOS's own charge limit, the same one System Settings > Battery changes, through
/// PowerUI's PowerUISmartChargeClient (manual charge limit, "MCL"). No admin rights needed and
/// nothing below macOS is touched: powerd keeps doing the actual charging control.
enum ChargeControl {
    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              let made = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              made.responds(to: NSSelectorFromString("initWithClientName:")) else { return nil }
        return made.perform(NSSelectorFromString("initWithClientName:"), with: "Vitals")?.takeUnretainedValue() as? NSObject
    }()

    private typealias GetByte = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>?) -> UInt8
    private typealias SetByte = @convention(c) (NSObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?) -> Bool
    private typealias GetObject = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>?) -> Unmanaged<AnyObject>?
    private typealias Enable = @convention(c) (NSObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

    private static var cached: (Date, Int?) = (.distantPast, nil)

    static var isAvailable: Bool { client != nil }

    /// The limit in percent (100 means no limit), read at most every 10 s.
    static func limit() -> Int? {
        if Date().timeIntervalSince(cached.0) < 10 { return cached.1 }
        var value: Int?
        if let client, let sel = selector("getMCLLimitWithError:", on: client) {
            var error: NSError?
            let raw = unsafeBitCast(client.method(for: sel), to: GetByte.self)(client, sel, &error)
            if error == nil, raw > 0 { value = Int(raw) }
        }
        cached = (Date(), value)
        return value
    }

    /// The steps macOS accepts, like 80, 85, 90, 95, 100.
    static func choices() -> [Int] {
        guard let client, let sel = selector("availableChargeLimitsWithError:", on: client) else { return [80, 100] }
        var error: NSError?
        let list = unsafeBitCast(client.method(for: sel), to: GetObject.self)(client, sel, &error)?.takeUnretainedValue() as? [NSNumber]
        let values = list?.map(\.intValue).filter { $0 > 0 && $0 <= 100 } ?? []
        return values.isEmpty ? [80, 100] : values
    }

    /// Sets the limit; 100 switches it off.
    @discardableResult
    static func setLimit(_ percent: Int) -> Bool {
        guard let client, let sel = selector("setMCLLimit:error:", on: client) else { return false }
        if percent < 100, let enable = selector("enableMCL:", on: client) {
            var error: NSError?
            _ = unsafeBitCast(client.method(for: enable), to: Enable.self)(client, enable, &error)
        }
        var error: NSError?
        let ok = unsafeBitCast(client.method(for: sel), to: SetByte.self)(client, sel, UInt8(min(100, max(50, percent))), &error)
        cached = (.distantPast, nil)
        return ok && error == nil
    }

    /// Lets it charge to 100% this one time; the limit comes back on its own afterwards.
    @discardableResult
    static func chargeToFullOnce() -> Bool {
        guard let client, let sel = selector("temporarilyOverrideMCLTargetSoC:error:", on: client) else { return false }
        var error: NSError?
        return unsafeBitCast(client.method(for: sel), to: SetByte.self)(client, sel, 100, &error) && error == nil
    }

    private static func selector(_ name: String, on client: NSObject) -> Selector? {
        let sel = NSSelectorFromString(name)
        return client.responds(to: sel) ? sel : nil
    }
}

/// Watches battery heat, the thing that wears a battery fastest after sitting at 100%.
/// When it stays hot for a minute it sends one notification naming the busiest app, then
/// waits half an hour before it would say so again.
final class BatteryGuard {
    static let shared = BatteryGuard()
    static let hot: Double = 38

    private var hotSince: Date?
    private var lastAlert: Date = .distantPast

    func check(system: SystemSnapshot, apps: [AppUsage]) {
        let p = system.power
        let temp = p.batteryTemp > 0 ? p.batteryTemp : system.batteryTemp
        guard Prefs.shared.heatAlerts, p.hasBattery, temp >= Self.hot else { hotSince = nil; return }
        let since = hotSince ?? Date()
        hotSince = since
        guard Date().timeIntervalSince(since) >= 60, Date().timeIntervalSince(lastAlert) >= 30 * 60 else { return }
        lastAlert = Date()
        let busiest = apps.max { $0.cpu + $0.gpu < $1.cpu + $1.gpu }
        let content = UNMutableNotificationContent()
        content.title = "Battery is hot: \(Int(temp.rounded()))°"
        content.body = (busiest.map { "\($0.name) is working hardest (\(Int($0.cpu.rounded()))% CPU). " } ?? "")
            + "Heat wears the battery fastest; close what you don't need or give the Mac some air."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "battery-heat", content: content, trigger: nil))
    }

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}

/// The battery's own screen: is it protected, the charge limit, heat alerts, health and wear.
struct BatteryCare: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Prefs

    var body: some View {
        let p = monitor.system.power
        let temp = p.batteryTemp > 0 ? p.batteryTemp : monitor.system.batteryTemp
        let limit = ChargeLimit.current()
        let warm = temp >= 35
        let protected = limit != nil && !warm
        VStack(spacing: 0) {
            // Verdict first.
            HStack(spacing: 10) {
                Image(systemName: protected ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(protected ? Theme.lime : Theme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(protected ? "Battery is protected" : warm ? "Battery is running warm" : "Battery charges to full")
                        .font(Theme.regular(13)).foregroundStyle(.white)
                    Text(protected ? "Kept below full and cool, the two things that slow wear most"
                         : warm ? "Heat wears a battery fastest. Close heavy apps or give it air"
                         : "Set a charge limit so it doesn't sit at 100% on the adapter")
                        .font(Theme.light(10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)

            divider
            chargeLimitRow(p: p, limit: limit)
            divider
            row("thermometer.medium", "Heat alert",
                detail: "Notify me at \(Int(BatteryGuard.hot))° with the app heating it · now \(temp > 0 ? "\(Int(temp.rounded()))°" : "--")") {
                LimeSwitch(isOn: Binding(get: { prefs.heatAlerts }, set: { on in
                    prefs.heatAlerts = on
                    if on { BatteryGuard.requestPermission() }
                }))
            }
            divider
            row("heart.text.square", "Health",
                detail: p.capacityDesign > 0 ? "Holds \(p.capacityNow) of \(p.capacityDesign) mAh it had new" : "Capacity compared with new") {
                Text(p.health > 0 ? "\(Int((p.health * 100).rounded()))%" : "--").font(Theme.regular(13)).monospacedDigit()
                    .foregroundStyle(p.health > 0 && p.health < 0.8 ? Theme.orange : .white)
            }
            divider
            row("arrow.triangle.2.circlepath", "Cycles",
                detail: "Full charges used so far; Apple rates Mac batteries for 1,000") {
                Text(p.cycleCount > 0 ? "\(p.cycleCount)" : "--").font(Theme.regular(13)).monospacedDigit().foregroundStyle(.white)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    @State private var fullOnce = false

    /// The limit as segments (80 ... Off), plus "Charge to 100% once" for days you need it all.
    private func chargeLimitRow(p: PowerInfo, limit: Int?) -> some View {
        let current = ChargeControl.limit() ?? 100
        let charging = fullOnce && p.pluggedIn && p.batteryPercent < 99
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.batteryblock").font(.system(size: 12)).foregroundStyle(Theme.lime.opacity(0.85)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Charge limit").font(Theme.regular(12)).foregroundStyle(.white)
                    Text(charging ? "Charging to 100% this once, then back to \(current)%"
                         : limit.map { "Stops charging at \($0)% on the adapter" } ?? "Off: charges to 100% every time")
                        .font(Theme.light(9.5)).foregroundStyle(charging ? Theme.lime.opacity(0.85) : Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(limit.map { "\($0)%" } ?? "Off").font(Theme.regular(13)).monospacedDigit()
                    .foregroundStyle(limit == nil ? Theme.orange : Theme.lime)
            }
            if ChargeControl.isAvailable {
                Segments(options: ChargeControl.choices().map { ($0, $0 >= 100 ? "Off" : "\($0)%") },
                         selection: Binding(get: { current }, set: { value in
                             ChargeControl.setLimit(value)
                             fullOnce = false
                             monitor.objectWillChange.send()
                         }))
                if limit != nil {
                    OutlineButton(title: charging ? "Charging to 100% once" : "Charge to 100% once", symbol: "bolt.fill", active: charging) {
                        fullOnce = ChargeControl.chargeToFullOnce()
                        monitor.objectWillChange.send()
                    }
                    .disabled(charging)
                    .help("For a long day away from power. The limit comes back after this charge.")
                }
            } else {
                QuietButton(title: "Open Battery settings", symbol: "gearshape", size: 10.5) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 40) }

    private func row<Trailing: View>(_ symbol: String, _ title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.lime.opacity(0.85)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.regular(12)).foregroundStyle(.white)
                Text(detail).font(Theme.light(9.5)).foregroundStyle(Theme.faint).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
