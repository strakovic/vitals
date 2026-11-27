import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// When to keep the Mac from going to sleep on its own.
enum AwakeMode: String, CaseIterable {
    case off, working, always
    var title: String {
        switch self {
        case .off: "Off"
        case .working: "While AI works"
        case .always: "Always"
        }
    }
}

/// Keeps the Mac awake while AI agents work, while chosen apps are open, or until turned off,
/// with a standard power assertion (the same mechanism video players use). The display may
/// still sleep; the Mac itself keeps running, so long agent tasks finish.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    /// Agents often pause between steps; stay awake this long after the last busy moment.
    static let grace: TimeInterval = 3 * 60

    @Published private(set) var since: Date?
    @Published private(set) var reason = ""
    private var assertion: IOPMAssertionID = 0
    private var lastBusy: Date = .distantPast

    var isOn: Bool { since != nil }

    /// Called after every sample on the main thread.
    func check(sessions: [ClaudeSession]) {
        let prefs = Prefs.shared
        let busy = sessions.filter(\.isBusy)
        if !busy.isEmpty { lastBusy = Date() }
        var why: String?
        switch AwakeMode(rawValue: prefs.awakeMode) ?? .off {
        case .always: why = "until you turn it off"
        case .working:
            if let first = busy.first { why = busy.count == 1 ? "\(first.tool.title) is working" : "\(busy.count) agents are working" }
            else if Date().timeIntervalSince(lastBusy) < Self.grace { why = "an agent just finished" }
        case .off: break
        }
        if why == nil, !prefs.awakeApps.isEmpty {
            let open = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
            if let app = open.first(where: prefs.awakeApps.contains) {
                why = "\((app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) is open"
            }
        }
        set(why)
    }

    private func set(_ why: String?) {
        if let why {
            reason = why
            guard assertion == 0 else { return }
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Vitals is keeping the Mac awake" as CFString, &assertion)
            if ok == kIOReturnSuccess { since = Date() } else { assertion = 0 }
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
            since = nil
            reason = ""
        }
    }

    /// "Awake for 5 min".
    var duration: String {
        guard let since else { return "" }
        return "Awake for " + Fmt.age(Date().timeIntervalSince(since))
    }
}

/// The keep-awake settings: when, and which apps keep the Mac awake while they are open.
struct AwakeSettings: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var awake = KeepAwake.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: awake.isOn ? "cup.and.saucer.fill" : "moon.zzz").font(.system(size: 12))
                    .foregroundStyle(awake.isOn ? Theme.lime : Theme.dim).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(awake.isOn ? awake.duration : "Sleeps normally").font(Theme.regular(12)).foregroundStyle(.white)
                    Text(awake.isOn ? "Staying awake: \(awake.reason)" : "Your Mac sleeps on its usual schedule")
                        .font(Theme.light(10)).foregroundStyle(awake.isOn ? Theme.lime.opacity(0.85) : Theme.faint).lineLimit(1)
                }
            }
            Segments(options: AwakeMode.allCases.map { ($0.rawValue, $0.title) }, selection: $prefs.awakeMode)
            VStack(spacing: 0) {
                ForEach(prefs.awakeApps.sorted(), id: \.self) { path in
                    HStack(spacing: 9) {
                        Image(nsImage: Icons.icon(path)).resizable().frame(width: 18, height: 18)
                        Text((path as NSString).lastPathComponent).font(Theme.regular(12)).foregroundStyle(.white)
                        Spacer()
                        Button { prefs.awakeApps.remove(path) } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.dim)
                        }
                        .buttonStyle(.plain).pointer().help("Remove")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 37)
                }
                Button { addApp() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 18)
                        Text("Add app…").font(Theme.regular(12))
                        Spacer()
                    }
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .rowHover(radius: 8)
                }
                .buttonStyle(.plain).pointer()
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.2)))
            Text("Your Mac also stays awake while any of these apps is open. The screen can still turn off.")
                .font(Theme.light(9.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { prefs.awakeApps.insert($0.path) }
    }
}
