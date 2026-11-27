import AppKit
import Combine
import Foundation

/// Everything the menu bar can show.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case cpu, gpu, ram, temp, power, net, disk, battery, claude
    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .temp: "TEMP"
        case .power: "PWR"
        case .net: "NET"
        case .disk: "DISK"
        case .battery: "BAT"
        case .claude: "AI"
        }
    }

    var title: String {
        switch self {
        case .cpu: "Processor"
        case .gpu: "Graphics"
        case .ram: "Memory"
        case .temp: "Temperature"
        case .power: "Power draw"
        case .net: "Network"
        case .disk: "Disk"
        case .battery: "Battery"
        case .claude: "AI agents"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .ram: "memorychip"
        case .temp: "thermometer.medium"
        case .power: "bolt"
        case .net: "arrow.up.arrow.down"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .claude: "sparkle"
        }
    }
}

struct SystemSnapshot {
    var cpu = 0.0
    var cores: [Double] = []
    var efficiencyCores = 0
    var gpu = 0.0
    var gpuMemory: UInt64 = 0
    var memory = MemoryInfo()
    var cpuTemp = 0.0
    var batteryTemp = 0.0
    var hottest = 0.0
    var power = PowerInfo()
    var netIn = 0.0, netOut = 0.0       // bytes per second
    var diskRead = 0.0, diskWrite = 0.0 // bytes per second
    var thermalState: ProcessInfo.ThermalState = .nominal
}

/// Samples the machine on a background queue and publishes the results on the main thread.
/// The per-process scan (the only part that touches every process) runs every tick while the
/// panel is open and every few ticks otherwise, so there is always a fresh baseline.
final class Monitor: ObservableObject {
    @Published private(set) var system = SystemSnapshot()
    @Published private(set) var apps: [AppUsage] = []
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var history: [Metric: [Double]] = [:]

    var onUpdate: (() -> Void)?
    let store = HistoryStore()
    var panelOpen = false {
        didSet {
            openFlag = panelOpen
            if panelOpen && !oldValue { tick(forceScan: true) }
        }
    }
    private var openFlag = false

    private let queue = DispatchQueue(label: "vitals.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let cpuReader = CPUReader()
    private let thermal = ThermalReader()
    private let scanner = ProcessScanner()
    private var lastNet: (UInt64, UInt64, TimeInterval)?
    private var lastDisk: (UInt64, UInt64, TimeInterval)?
    private var tickCount = 0
    private var currentInterval: TimeInterval = 2
    private var lastTempRead: TimeInterval = 0
    private var lastTemps: (cpu: Double, battery: Double, hottest: Double) = (0, 0, 0)
    static let historyLength = 90

    init() { restoreRecent() }

    // MARK: Demo data (for screenshots and the website, `--snapshot <dir> --demo`)

    func loadDemo() {
        func wave(_ base: Double, _ swing: Double, _ seed: Double, count: Int = Self.historyLength) -> [Double] {
            (0..<count).map { i in
                let x = Double(i)
                return max(0, base + swing * (sin(x / 7 + seed) * 0.6 + sin(x / 2.3 + seed * 2) * 0.25 + sin(x / 1.1 + seed * 3) * 0.15))
            }
        }
        var s = SystemSnapshot()
        s.cores = [0.42, 0.38, 0.47, 0.35, 0.71, 0.64, 0.22, 0.12]
        s.efficiencyCores = 4
        s.cpu = 0.34
        s.gpu = 0.27
        s.gpuMemory = 1_420_000_000
        s.memory = MemoryInfo(used: 11_600_000_000, total: 17_179_869_184, compressed: 1_200_000_000, swap: 0, pressure: 1)
        s.cpuTemp = 58
        s.batteryTemp = 32
        s.power = PowerInfo(systemWatts: 14.2, batteryPercent: 80, charging: false, pluggedIn: true, hasBattery: true,
                            timeRemaining: nil, cycleCount: 212, health: 0.93, batteryTemp: 32,
                            capacityNow: 5360, capacityDesign: 5760, held: true)
        if ProcessInfo.processInfo.environment["VITALS_DESKTOP"] != nil { s.power = PowerInfo() }   // preview a Mac without a battery
        s.netIn = 2_400_000
        s.netOut = 310_000
        s.diskRead = 18_000_000
        s.diskWrite = 6_500_000
        system = s
        history = [
            .cpu: wave(0.32, 0.16, 1).map { min(1, $0) }, .gpu: wave(0.24, 0.12, 2).map { min(1, $0) },
            .ram: wave(0.68, 0.025, 3).map { min(1, $0) }, .temp: wave(57, 3, 4), .power: wave(13, 4, 5),
            .net: wave(1_800_000, 1_200_000, 6), .disk: wave(12_000_000, 9_000_000, 7), .battery: Array(repeating: 80, count: Self.historyLength),
            .claude: wave(2, 1, 8),
        ]
        func app(_ path: String, _ name: String, cpu: Double, gpu: Double, gb: Double, procs: Int, claude: Bool = false) -> AppUsage {
            AppUsage(id: path, name: name, iconPath: claude ? "/Applications/Claude.app" : path, cpu: cpu, gpu: gpu, memory: UInt64(gb * 1_073_741_824), watts: cpu / 8,
                     processes: procs, isClaude: claude, pids: [], ownPids: [1])
        }
        apps = [
            app("/Applications/Xcode.app", "Xcode", cpu: 11.4, gpu: 3, gb: 3.1, procs: 14),
            app("claude-code", "Claude Code", cpu: 8.2, gpu: 0, gb: 1.6, procs: 22, claude: true),
            app("/Applications/Figma.app", "Figma", cpu: 4.1, gpu: 12, gb: 1.4, procs: 9),
            app("/Applications/Safari.app", "Safari", cpu: 3.2, gpu: 4, gb: 1.9, procs: 18),
            app("/Applications/Cursor.app", "Cursor", cpu: 2.6, gpu: 1, gb: 1.2, procs: 16),
            app("/Applications/ChatGPT.app", "ChatGPT", cpu: 1.1, gpu: 2, gb: 0.6, procs: 6),
            app("/Applications/Docker.app", "Docker", cpu: 1.8, gpu: 0, gb: 2.2, procs: 7),
            app("/Applications/Spotify.app", "Spotify", cpu: 0.9, gpu: 1, gb: 0.4, procs: 5),
            app("/System/Applications/Mail.app", "Mail", cpu: 0.2, gpu: 0, gb: 0.3, procs: 3),
        ]
        let now = Date()
        func task(_ pid: pid_t, _ command: String, cpu: Double, age: TimeInterval) -> ClaudeTask {
            ClaudeTask(pid: pid, command: command, cpu: cpu, memory: 200_000_000, age: age)
        }
        sessions = [
            ClaudeSession(pid: 90001, name: "Ship the onboarding flow", status: "busy", folder: "~/code/atlas", entrypoint: "cli",
                          startedAt: now.addingTimeInterval(-5400), cpu: 6.1, gpu: 0, memory: 690_000_000,
                          tasks: [task(90011, "swift build -c release", cpu: 5.2, age: 41), task(90012, "npm run dev", cpu: 0.6, age: 1900)]),
            ClaudeSession(pid: 90002, name: "Fix flaky checkout tests", status: "busy", folder: "~/code/shop", entrypoint: "cli",
                          startedAt: now.addingTimeInterval(-2700), cpu: 2.1, gpu: 0, memory: 410_000_000,
                          tasks: [task(90021, "pytest tests/checkout -x", cpu: 1.9, age: 12)]),
            ClaudeSession(pid: 90003, name: "Write the release notes", status: "idle", folder: "~/code/atlas", entrypoint: "cli",
                          startedAt: now.addingTimeInterval(-9800), cpu: 0, gpu: 0, memory: 300_000_000),
            ClaudeSession(pid: 90004, name: "api-server", status: "busy", folder: "~/code/api-server", entrypoint: "",
                          startedAt: now.addingTimeInterval(-1300), cpu: 3.4, gpu: 0, memory: 240_000_000,
                          tasks: [task(90041, "cargo test", cpu: 3.1, age: 25)], tool: .codex),
        ]
        store.loadDemo(now: now.timeIntervalSince1970)
        if Prefs.shared.awakeMode == "working" { KeepAwake.shared.check(sessions: sessions); KeepAwake.shared.backdate(72 * 60) }   // show the awake state in demo shots
    }

    // MARK: Recent history across restarts

    private struct Recent: Codable { var t: Double; var interval: Double; var values: [String: [Double]] }
    private static let recentFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vitals")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recent.json")
    }()

    /// Saves the last few minutes the live charts show (a few KB), so a restart doesn't blank them.
    func saveRecent() {
        let values = Dictionary(uniqueKeysWithValues: history.map { ($0.key.rawValue, $0.value) })
        let recent = Recent(t: Date().timeIntervalSince1970, interval: currentInterval, values: values)
        try? JSONEncoder().encode(recent).write(to: Self.recentFile, options: .atomic)
    }

    /// Loads what was saved, dropping whatever has slid out of the window while the app was off.
    private func restoreRecent() {
        guard let data = try? Data(contentsOf: Self.recentFile),
              let recent = try? JSONDecoder().decode(Recent.self, from: data) else { return }
        let missed = Int((Date().timeIntervalSince1970 - recent.t) / max(0.5, recent.interval))
        let keep = Self.historyLength - max(0, missed)
        guard keep > 0 else { return }
        var restored: [Metric: [Double]] = [:]
        for (key, list) in recent.values {
            if let metric = Metric(rawValue: key) { restored[metric] = Array(list.suffix(keep)) }
        }
        history = restored
    }

    func start(interval: TimeInterval) {
        timer?.cancel()
        queue.async { self.currentInterval = interval }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 150)))
        t.setEventHandler { [weak self] in self?.sample(forceScan: false) }
        t.resume()
        timer = t
    }

    func tick(forceScan: Bool) {
        queue.async { [weak self] in self?.sample(forceScan: forceScan) }
    }

    /// Runs one sample on the calling thread (used by --dump).
    func sampleNow(scan: Bool) { sample(forceScan: scan) }

    private func sample(forceScan: Bool) {
        tickCount += 1
        let open = openFlag
        let scanEvery = max(1, Int((30 / currentInterval).rounded()))
        // Open panel: apps every 4 s (calm enough to read and click); closed: every 30 s.
        let openEvery = max(1, Int((4 / currentInterval).rounded()))
        let scan = forceScan || (open && tickCount % openEvery == 0) || tickCount % scanEvery == 1
        let now = ProcessInfo.processInfo.systemUptime

        var s = SystemSnapshot()
        let cpu = cpuReader.read()
        s.cpu = cpu.total
        s.cores = cpu.cores
        s.efficiencyCores = cpuReader.efficiencyCores
        let gpu = GPUReader.read(perProcess: scan)
        s.gpu = gpu.utilization
        s.gpuMemory = gpu.memory
        s.memory = MemoryReader.read()
        // Temperature moves slowly and its sensors are the priciest read: every 4 s with the panel open, 8 s closed.
        if lastTempRead == 0 || now - lastTempRead >= (open ? 3.9 : 7.9) || forceScan {
            lastTemps = thermal.read()
            lastTempRead = now
        }
        s.cpuTemp = lastTemps.cpu
        s.batteryTemp = lastTemps.battery
        s.hottest = lastTemps.hottest
        s.power = PowerReader.read()
        s.thermalState = ProcessInfo.processInfo.thermalState

        let net = NetworkReader.totals()
        if let last = lastNet, now > last.2 {
            s.netIn = Double(net.received &- last.0) / (now - last.2)
            s.netOut = Double(net.sent &- last.1) / (now - last.2)
            if s.netIn > 1e11 { s.netIn = 0 }
            if s.netOut > 1e11 { s.netOut = 0 }
        }
        lastNet = (net.received, net.sent, now)
        let disk = DiskReader.totals()
        if let last = lastDisk, now > last.2 {
            s.diskRead = Double(disk.read &- last.0) / (now - last.2)
            s.diskWrite = Double(disk.written &- last.1) / (now - last.2)
            if s.diskRead > 1e11 { s.diskRead = 0 }
            if s.diskWrite > 1e11 { s.diskWrite = 0 }
        }
        lastDisk = (disk.read, disk.written, now)

        var sessions = ClaudeSessions.read()
        var apps: [AppUsage]?
        if scan {
            let result = scanner.scan(gpuTimes: gpu.timeByPid, sessions: sessions)
            apps = result.apps
            sessions = result.sessions
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.system = s
            if let apps {
                self.apps = apps
                self.sessions = sessions
                self.store.setTop(apps: apps, sessions: sessions)
            } else {
                // Keep the last measured numbers, but take names and busy/idle from the fresh read.
                let previous = Dictionary(uniqueKeysWithValues: self.sessions.map { ($0.pid, $0) })
                self.sessions = sessions.map { fresh in
                    guard var old = previous[fresh.pid] else { return fresh }
                    old.name = fresh.name
                    old.status = fresh.status
                    return old
                } + self.sessions.filter { $0.tool != .claudeCode && Darwin.kill($0.pid, 0) == 0 }
            }
            self.record(s)
            SimulatorJanitor.shared.check(sessions: self.sessions, apps: self.apps)
            BatteryGuard.shared.check(system: s, apps: self.apps)
            KeepAwake.shared.check(sessions: self.sessions)
            self.onUpdate?()
        }
    }

    private func record(_ s: SystemSnapshot) {
        let values: [Metric: Double] = [
            .cpu: s.cpu, .gpu: s.gpu, .ram: s.memory.share, .temp: s.cpuTemp,
            .power: s.power.systemWatts, .net: s.netIn + s.netOut, .disk: s.diskRead + s.diskWrite,
            .battery: s.power.batteryPercent, .claude: Double(sessions.filter(\.isBusy).count),
        ]
        var stored: [String: Double] = [
            "cpu": s.cpu * 100, "gpu": s.gpu * 100, "ram": s.memory.share * 100,
            "ramUsed": Double(s.memory.used), "swap": Double(s.memory.swap),
            "netIn": s.netIn, "netOut": s.netOut, "diskRead": s.diskRead, "diskWrite": s.diskWrite,
            "claude": Double(sessions.filter(\.isBusy).count),
        ]
        if s.cpuTemp > 0 { stored["temp"] = s.cpuTemp }
        if s.power.systemWatts > 0 { stored["power"] = s.power.systemWatts }
        if s.power.hasBattery { stored["battery"] = s.power.batteryPercent }
        // The first sample has no previous reading to compare with, so rates read as zero.
        if s.cores.contains(where: { $0 > 0 }) { store.add(stored, at: Date().timeIntervalSince1970) }
        for (metric, value) in values {
            var list = history[metric] ?? []
            list.append(value)
            if list.count > Self.historyLength { list.removeFirst(list.count - Self.historyLength) }
            history[metric] = list
        }
    }

    // MARK: Values for display

    /// Short text for the menu bar: "23%", "48°", "6.2W".
    func barValue(_ metric: Metric) -> String {
        let s = system
        switch metric {
        case .cpu: return Fmt.percent(s.cpu)
        case .gpu: return Fmt.percent(s.gpu)
        case .ram: return Fmt.percent(s.memory.share)
        case .temp: return s.cpuTemp > 0 ? "\(Int(s.cpuTemp.rounded()))°" : "--"
        case .power: return s.power.systemWatts > 0 ? Fmt.watts(s.power.systemWatts) : "--"
        case .net: return Fmt.rate(s.netIn + s.netOut)
        case .disk: return Fmt.rate(s.diskRead + s.diskWrite)
        case .battery: return s.power.hasBattery ? "\(Int(s.power.batteryPercent))%" : "--"
        case .claude:
            let busy = sessions.filter(\.isBusy).count
            return "\(busy)/\(sessions.count)"
        }
    }

    /// 0...1 for gauges and bars in the menu bar.
    func level(_ metric: Metric) -> Double {
        let s = system
        switch metric {
        case .cpu: return s.cpu
        case .gpu: return s.gpu
        case .ram: return s.memory.share
        case .temp: return min(1, max(0, (s.cpuTemp - 30) / 70))
        case .power: return min(1, s.power.systemWatts / 40)
        case .net: return min(1, log10(max(1, s.netIn + s.netOut)) / 8)
        case .disk: return min(1, log10(max(1, s.diskRead + s.diskWrite)) / 9)
        case .battery: return s.power.batteryPercent / 100
        case .claude: return sessions.isEmpty ? 0 : Double(sessions.filter(\.isBusy).count) / Double(sessions.count)
        }
    }

    /// Two short lines for metrics that have two directions (net, disk): up/down, read/write.
    func pair(_ metric: Metric) -> (String, String)? {
        switch metric {
        case .net: return ("↑" + Fmt.rate(system.netOut), "↓" + Fmt.rate(system.netIn))
        case .disk: return ("R " + Fmt.rate(system.diskRead), "W " + Fmt.rate(system.diskWrite))
        default: return nil
        }
    }

    /// History normalized to 0...1 for sparklines.
    func normalizedHistory(_ metric: Metric) -> [Double] {
        let values = history[metric] ?? []
        switch metric {
        case .cpu, .gpu, .ram: return values
        case .battery: return values.map { $0 / 100 }
        case .temp: return values.map { min(1, max(0, ($0 - 30) / 70)) }
        default:
            let top = max(values.max() ?? 1, metric == .power ? 10 : 1)
            return values.map { top > 0 ? $0 / top : 0 }
        }
    }
}

enum Fmt {
    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    static func watts(_ w: Double) -> String { w < 10 ? String(format: "%.1fW", w) : "\(Int(w.rounded()))W" }

    /// Compact bytes per second: 0, 812K, 1.2M, 34M.
    static func rate(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        if b < 1024 { return "0K" }
        if b < 1024 * 1024 { return "\(Int(b / 1024))K" }
        let m = b / 1024 / 1024
        if m < 10 { return String(format: "%.1fM", m) }
        if m < 1024 { return "\(Int(m))M" }
        return String(format: "%.1fG", m / 1024)
    }

    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        if v < 1024 * 1024 { return "\(Int(v / 1024)) KB" }
        if v < 1024 * 1024 * 1024 { return "\(Int(v / 1024 / 1024)) MB" }
        return String(format: "%.1f GB", v / 1024 / 1024 / 1024)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d"
    }
}
