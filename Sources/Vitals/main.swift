import AppKit
import SwiftUI

let args = CommandLine.arguments

if args.contains("--timing") {
    // How long each reader takes, averaged over 20 runs.
    func time(_ name: String, _ body: () -> Void) {
        let t = Date(); for _ in 0..<20 { body() }
        print(String(format: "%-10@ %.2f ms", name as NSString, Date().timeIntervalSince(t) * 1000 / 20))
    }
    let cpu = CPUReader(), thermal = ThermalReader(), scanner = ProcessScanner()
    time("cpu") { _ = cpu.read() }
    time("memory") { _ = MemoryReader.read() }
    time("gpu") { _ = GPUReader.read(perProcess: false) }
    time("gpu+pids") { _ = GPUReader.read(perProcess: true) }
    time("thermal") { _ = thermal.read() }
    time("power") { _ = PowerReader.read() }
    time("net") { _ = NetworkReader.totals() }
    time("disk") { _ = DiskReader.totals() }
    time("sessions") { _ = ClaudeSessions.read() }
    let sessions = ClaudeSessions.read()
    time("scan") { _ = scanner.scan(gpuTimes: [:], sessions: sessions) }
    exit(0)
}

if args.contains("--dump") {
    // Prints two samples' worth of everything, to check the readers from a terminal.
    let thermal = ThermalReader()
    for s in thermal.readEverything() { print(String(format: "  %-28@ %.1f°C", s.name as NSString, s.celsius)) }
    let cpu = CPUReader(); _ = cpu.read()
    let scanner = ProcessScanner()
    var sessions = ClaudeSessions.read()
    _ = scanner.scan(gpuTimes: GPUReader.read(perProcess: true).timeByPid, sessions: sessions)
    Thread.sleep(forTimeInterval: 2)
    let c = cpu.read()
    let g = GPUReader.read(perProcess: true)
    let m = MemoryReader.read()
    let p = PowerReader.read()
    print("CPU", Fmt.percent(c.total), c.cores.map { Fmt.percent($0) }, "E cores", cpu.efficiencyCores)
    print("GPU", Fmt.percent(g.utilization), Fmt.bytes(g.memory), "clients", g.timeByPid.count)
    print("RAM", Fmt.bytes(m.used), "/", Fmt.bytes(m.total), "swap", Fmt.bytes(m.swap), "pressure", m.pressure)
    print("Temp", thermal.read())
    print("Power", p)
    print("Net", NetworkReader.totals(), "Disk", DiskReader.totals())
    let t0 = Date()
    sessions = ClaudeSessions.read()
    let result = scanner.scan(gpuTimes: g.timeByPid, sessions: sessions)
    print("scan took", Int(Date().timeIntervalSince(t0) * 1000), "ms")
    for a in result.apps.sorted(by: { $0.cpu > $1.cpu }).prefix(15) {
        print(String(format: "  %-26@ cpu %6.1f  gpu %5.1f  %9@  %5.2fW  x%d", a.name as NSString, a.cpu, a.gpu, Fmt.bytes(a.memory) as NSString, a.watts, a.processes))
    }
    for s in result.sessions {
        print("Claude:", s.name, s.status, String(format: "cpu %.1f", s.cpu), Fmt.bytes(s.memory), "tasks", s.tasks.count)
        for t in s.tasks.prefix(5) { print("    ", t.command.prefix(90), String(format: "%.1f", t.cpu), Fmt.age(t.age)) }
    }
    exit(0)
}

if let i = args.firstIndex(of: "--export"), i + 1 < args.count {
    // Writes the full history as CSV without opening the app: Vitals --export history.csv
    try? HistoryStore().exportCSV().write(toFile: args[i + 1], atomically: true, encoding: .utf8)
    print("Saved", args[i + 1])
    exit(0)
}

if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    // Renders the panel (each tab) and the menu bar (dark and light) to PNGs, with live data.
    let dir = URL(fileURLWithPath: args[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let monitor = Monitor()
    let prefs = Prefs.shared
    if args.contains("--demo") {
        monitor.loadDemo()
    } else {
        for n in 0..<6 {
            monitor.sampleNow(scan: true)
            RunLoop.main.run(until: Date().addingTimeInterval(n == 5 ? 0.2 : 1))
        }
    }
    func save(_ view: some View, _ name: String) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }
    for tab in PanelTab.allCases {
        save(PanelView(monitor: monitor, prefs: prefs, tab: tab), "panel-\(tab.rawValue)")
    }
        save(PanelView(monitor: monitor, prefs: prefs, boosting: true), "panel-boost")
    for metric in [Metric.cpu, .temp, .net, .claude, .battery] {
        save(PanelView(monitor: monitor, prefs: prefs, detail: metric), "detail-\(metric.rawValue)")
    }
    let saved = prefs.bar
    prefs.bar = [.cpu, .gpu, .ram, .temp, .power, .net, .battery, .claude]
    for dark in [true, false] {
        let image = BarRenderer.render(monitor, prefs: prefs, dark: dark)
        let view = Image(nsImage: image).padding(8).background(dark ? Color(white: 0.12) : Color(white: 0.92))
        save(view, "bar-\(dark ? "dark" : "light")")
    }
    prefs.bar = saved
    print("Saved to", dir.path)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
