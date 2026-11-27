import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = Monitor()
    private let prefs = Prefs.shared
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var subscriptions: Set<AnyCancellable> = []
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Vitals at a time (a login item and a manual open can race).
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0.processIdentifier != me.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        LoginItem.registerOnFirstLaunch()
        // New items land at the far left, which on a full menu bar is under the notch.
        // Start next to the system icons instead; macOS remembers wherever you Cmd-drag it after.
        let positionKey = "NSStatusItem Preferred Position vitals"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(480, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "vitals"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.imagePosition = .imageOnly

        // launchd stops the app with SIGTERM: save the history first.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.monitor.store.save()
            self?.monitor.saveRecent()
            exit(0)
        }
        term.resume()
        termSource = term

        if prefs.heatAlerts { BatteryGuard.requestPermission() }
        monitor.onUpdate = { [weak self] in self?.redraw() }
        monitor.start(interval: prefs.interval)

        prefs.$interval.dropFirst().removeDuplicates().sink { [weak self] value in
            self?.monitor.start(interval: value)
        }.store(in: &subscriptions)
        prefs.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.redraw() }
        }.store(in: &subscriptions)
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.store.save()
        monitor.saveRecent()
    }

    private func redraw() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = BarRenderer.render(monitor, prefs: prefs, dark: dark)
    }

    /// Opening Vitals from Applications or Spotlight while it runs shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if popover?.isShown != true { toggle() }
        return false
    }

    @objc private func toggle() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        // The panel is built each time it opens and thrown away when it closes,
        // so nothing renders in the background.
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let controller = NSHostingController(rootView: PanelView(monitor: monitor, prefs: prefs, quit: { NSApp.terminate(nil) }))
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        self.popover = popover
        monitor.panelOpen = true
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.panelOpen = false
        popover?.contentViewController = nil
        popover = nil
    }
}

import ServiceManagement

/// Starting at login. Downloaded copies use a regular login item (System Settings > General >
/// Login Items); a build installed with ./build.sh install uses its LaunchAgent instead.
enum LoginItem {
    static let label = "app.diferent.Vitals"
    static var hasLaunchAgent: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist")
    }

    /// With the LaunchAgent (./build.sh install) it opens at login unless launchd has it disabled.
    static var isOn: Bool {
        if hasLaunchAgent { return !launchctl(["print-disabled", "gui/\(getuid())"]).contains("\"\(label)\" => disabled") }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        if hasLaunchAgent {
            // enable/disable only changes whether it starts at login; the running app keeps running.
            _ = launchctl([on ? "enable" : "disable", "gui/\(getuid())/\(label)"])
        } else if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }

    static func registerOnFirstLaunch() {
        let key = "askedLoginItem"
        guard !hasLaunchAgent, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }

    private static func launchctl(_ args: [String]) -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
