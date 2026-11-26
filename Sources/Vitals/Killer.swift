import AppKit
import Darwin

/// Stops apps and Claude tasks from the panel. Apps get a normal Quit first (so they can save),
/// plain processes get SIGTERM; `force` sends SIGKILL to whatever is still alive.
enum Killer {
    /// Groups that would take down the Mac's own UI or this app. Everything else, Claude included, can go.
    private static let protectedNames: Set<String> = [
        "loginwindow", "Dock", "SystemUIServer", "ControlCenter", "WindowManager", "WindowServer",
        "launchd", "kernel_task", "Vitals", "NotificationCenter",
    ]

    static func canQuit(_ app: AppUsage) -> Bool {
        if app.ownPids.isEmpty { return false }
        if protectedNames.contains(app.name) { return false }
        if app.id.hasSuffix("/Vitals.app") { return false }
        if app.ownPids.contains(getpid()) { return false }
        return true
    }

    static func quit(_ app: AppUsage) {
        // A real app: ask it to quit the normal way, which also closes its helpers.
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.id }
        if !running.isEmpty {
            running.forEach { $0.terminate() }
            return
        }
        signal(app.ownPids, SIGTERM)
    }

    static func force(_ app: AppUsage) {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.id }.forEach { $0.forceTerminate() }
        signal(app.ownPids, SIGKILL)
    }

    static func stop(_ task: ClaudeTask) {
        // Children first, so a shell doesn't respawn or report its child before it goes.
        signal(Array(task.pids.reversed()), SIGTERM)
        signal([task.pid], SIGTERM)
    }

    static func forceStop(_ task: ClaudeTask) { signal(task.pids + [task.pid], SIGKILL) }

    /// Ends a whole agent session: its tasks first, then the agent itself.
    static func stop(_ session: ClaudeSession) {
        signal(session.tasks.flatMap { $0.pids.reversed() + [$0.pid] }, SIGTERM)
        signal([session.pid], SIGTERM)
    }

    static func forceStop(_ session: ClaudeSession) {
        signal(session.tasks.flatMap { $0.pids + [$0.pid] } + [session.pid], SIGKILL)
    }

    static func isAlive(_ pids: [pid_t]) -> Bool {
        pids.contains { Darwin.kill($0, 0) == 0 }
    }

    private static func signal(_ pids: [pid_t], _ sig: Int32) {
        for pid in Set(pids) where pid > 1 && pid != getpid() { Darwin.kill(pid, sig) }
    }
}

/// Keeps a list's order still while the pointer is on it, and otherwise lets it change only
/// every few seconds, so rows don't jump out from under the mouse.
struct StableOrder<ID: Hashable> {
    private(set) var ids: [ID] = []
    private var last: Date = .distantPast

    /// `ranked` is the fresh order. Returns true when the order actually changed.
    @discardableResult
    mutating func update(_ ranked: [ID], frozen: Bool, every seconds: TimeInterval, force: Bool = false) -> Bool {
        let present = Set(ranked)
        let old = ids
        if force || ids.isEmpty || (!frozen && Date().timeIntervalSince(last) >= seconds) {
            ids = ranked
            last = Date()
        } else {
            // Hold everyone where they are; drop what's gone, add newcomers at the end.
            let kept = ids.filter(present.contains)
            let keptSet = Set(kept)
            ids = kept + ranked.filter { !keptSet.contains($0) }
        }
        return ids != old
    }
}

/// Shuts iOS Simulators down once Claude has been idle for a while. Sessions boot simulators to
/// build and test, then move on and leave them running at 6 to 7 GB each.
final class SimulatorJanitor: ObservableObject {
    static let shared = SimulatorJanitor()
    static let idleMinutes: Double = 10

    @Published private(set) var lastShutdown: Date?
    private var lastBusy = Date()
    private var working = false

    /// Called after every sample on the main thread.
    func check(sessions: [ClaudeSession], apps: [AppUsage]) {
        if sessions.contains(where: \.isBusy) { lastBusy = Date(); return }
        guard Prefs.shared.autoSimulators, !working,
              let sims = apps.first(where: { $0.id == ProcessScanner.simulatorsKey }), sims.memory > 0,
              Date().timeIntervalSince(lastBusy) >= Self.idleMinutes * 60 else { return }
        // You are using the Simulator yourself: leave it alone.
        if NSWorkspace.shared.frontmostApplication?.bundleURL?.path == ProcessScanner.simulatorApp {
            lastBusy = Date()
            return
        }
        shutdownAll()
    }

    func shutdownAll(then done: (() -> Void)? = nil) {
        working = true
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["simctl", "shutdown", "all"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            DispatchQueue.main.async {
                NSWorkspace.shared.runningApplications
                    .filter { $0.bundleURL?.path == ProcessScanner.simulatorApp }.forEach { $0.terminate() }
                self.lastShutdown = Date()
                self.lastBusy = Date()
                self.working = false
                done?()
            }
        }
    }
}
