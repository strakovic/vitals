import AppKit
import Darwin
import Foundation

/// One app's share of the machine: every process it is responsible for, added up.
struct AppUsage: Identifiable {
    var id: String
    var name: String
    var iconPath: String?
    var cpu: Double = 0          // percent of the whole chip (all cores together)
    var gpu: Double = 0          // percent of the GPU
    var memory: UInt64 = 0       // physical footprint, bytes
    var watts: Double = 0        // energy the kernel attributes to it
    var processes = 0
    var isClaude = false
    var pids: [pid_t] = []       // every process in the group
    var ownPids: [pid_t] = []    // the ones running as this user, which we are allowed to stop
}

/// The coding agents Vitals recognises. Claude Code reports its own sessions; the others are found
/// by their process while they run.
enum AITool: String, CaseIterable {
    case claudeCode, codex, gemini, aider, opencode, amp, goose, cursorAgent, copilot, qwen, crush

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .aider: "Aider"
        case .opencode: "OpenCode"
        case .amp: "Amp"
        case .goose: "Goose"
        case .cursorAgent: "Cursor Agent"
        case .copilot: "Copilot CLI"
        case .qwen: "Qwen Code"
        case .crush: "Crush"
        }
    }

    /// Executable names (or script names under node, bun or python) that mean this tool.
    static let executables: [String: AITool] = [
        "codex": .codex, "gemini": .gemini, "gemini-cli": .gemini, "aider": .aider, "opencode": .opencode,
        "amp": .amp, "goose": .goose, "cursor-agent": .cursorAgent, "copilot": .copilot, "qwen": .qwen, "crush": .crush,
    ]

    /// Desktop apps that are AI tools, shown under the agents.
    static let apps: Set<String> = ["Claude", "ChatGPT", "Codex", "Cursor", "Windsurf", "Ollama", "LM Studio", "Perplexity", "Gemini", "Copilot", "Zed"]
}

/// A running agent session (Claude Code, Codex, Gemini CLI...) and the work it is doing right now.
struct ClaudeSession: Identifiable {
    var id: pid_t { pid }
    var pid: pid_t
    var name: String
    var status: String           // busy, idle, ...
    var folder: String
    var entrypoint: String
    var startedAt: Date?
    var cpu: Double = 0
    var gpu: Double = 0
    var memory: UInt64 = 0
    var watts: Double = 0
    var tasks: [ClaudeTask] = []
    var tool: AITool = .claudeCode
    /// The agent's own process, without the tasks and helpers it started.
    var ownCpu: Double = 0
    var ownMemory: UInt64 = 0
    var isBusy: Bool { status == "busy" }
}

/// A process a Claude session started: a shell command, a build, a server.
struct ClaudeTask: Identifiable {
    var id: pid_t { pid }
    var pid: pid_t
    var command: String
    var cpu: Double
    var memory: UInt64
    var age: TimeInterval
    var pids: [pid_t] = []       // the task and everything it started
    /// Long-lived and quiet, like an MCP server, rather than work in progress.
    var isBackground: Bool { age > 300 && cpu < 0.5 }
}

/// Walks every process, works out which app (or Claude session) owns it, and turns
/// cumulative counters into rates between calls.
final class ProcessScanner {
    private struct Sample { var start: UInt64; var cpuNanos: UInt64; var energy: UInt64; var gpuNanos: UInt64 }
    private struct Identity { var start: UInt64; var path: String; var name: String }

    private var samples: [pid_t: Sample] = [:]
    private var identities: [pid_t: Identity] = [:]
    private var commandLines: [pid_t: (UInt64, String)] = [:]
    private var groupOf: [pid_t: (start: UInt64, group: (key: String, name: String, icon: String?))] = [:]
    private var lastScan: TimeInterval = 0
    private let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private let responsible: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    func scan(gpuTimes: [pid_t: UInt64], sessions: [ClaudeSession]) -> (apps: [AppUsage], sessions: [ClaudeSession]) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastScan > 0 ? now - lastScan : 0
        lastScan = now

        // 1. Every pid with its parent, start time and counters.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return ([], sessions) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        pids = Array(pids.prefix(Int(max(0, filled))))

        struct Live { var pid: pid_t; var ppid: pid_t; var uid: uid_t; var start: UInt64; var cpu: Double; var memory: UInt64; var watts: Double; var gpu: Double }
        var live: [pid_t: Live] = [:]
        var nextSamples: [pid_t: Sample] = [:]
        let wallNanos = elapsed * 1e9

        for pid in pids where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            let start = UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            var cpuNanos: UInt64 = 0, energy: UInt64 = 0, memory: UInt64 = 0
            var usage = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            if ok == 0 {
                cpuNanos = UInt64(Double(usage.ri_user_time + usage.ri_system_time) * machToNanos)
                energy = usage.ri_energy_nj
                memory = usage.ri_phys_footprint
            } else {
                // Other users' processes: the task info call still works for most of them.
                var task = proc_taskinfo()
                if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) {
                    cpuNanos = UInt64(Double(task.pti_total_user + task.pti_total_system) * machToNanos)
                    memory = task.pti_resident_size
                }
            }
            let gpuNanos = gpuTimes[pid] ?? 0
            let sample = Sample(start: start, cpuNanos: cpuNanos, energy: energy, gpuNanos: gpuNanos)
            nextSamples[pid] = sample

            var cpu = 0.0, watts = 0.0, gpu = 0.0
            if wallNanos > 0, let before = samples[pid], before.start == start {
                // Share of the whole chip, so apps add up to the CPU gauge.
                cpu = Double(cpuNanos &- before.cpuNanos) / wallNanos * 100 / cores
                if energy >= before.energy { watts = Double(energy - before.energy) / wallNanos }
                if gpuNanos >= before.gpuNanos { gpu = Double(gpuNanos - before.gpuNanos) / wallNanos * 100 }
                if cpu < 0 || cpu > 100 { cpu = 0 }
            }
            live[pid] = Live(pid: pid, ppid: pid_t(bsd.pbi_ppid), uid: bsd.pbi_uid, start: start, cpu: cpu, memory: memory, watts: watts, gpu: min(gpu, 100))

            if identities[pid]?.start != start {
                identities[pid] = Identity(start: start, path: Self.path(of: pid), name: Self.name(from: bsd))
            }
        }
        samples = nextSamples
        identities = identities.filter { live[$0.key] != nil }
        commandLines = commandLines.filter { live[$0.key]?.start == $0.value.0 }
        groupOf = groupOf.filter { live[$0.key]?.start == $0.value.start }

        // 2. Other coding agents running in a terminal (Codex, Gemini CLI, Aider...): each outermost
        // process of one becomes a session, with its tasks found the same way as Claude's.
        let myUid = getuid()
        var sessions = sessions
        let claudePids = Set(sessions.map(\.pid))
        agentKinds = agentKinds.filter { live[$0.key]?.start == $0.value.start }
        func kind(_ pid: pid_t) -> AITool? {
            guard let process = live[pid] else { return nil }
            if let cached = agentKinds[pid], cached.start == process.start { return cached.tool }
            let tool = detectAgent(pid)
            agentKinds[pid] = (process.start, tool)
            return tool
        }
        for (pid, process) in live where process.uid == myUid && !claudePids.contains(pid) {
            guard let tool = kind(pid) else { continue }
            if kind(process.ppid) == tool { continue }                 // a child of the same agent
            var up = process.ppid, hops = 0, insideClaude = false
            while up > 1, hops < 64, let parent = live[up] {             // started by Claude: it's a Claude task
                if claudePids.contains(up) { insideClaude = true; break }
                up = parent.ppid; hops += 1
            }
            if insideClaude { continue }
            let folder = Self.workingDirectory(pid)
            sessions.append(ClaudeSession(pid: pid, name: (folder as NSString).lastPathComponent, status: "idle", folder: folder,
                                          entrypoint: "", startedAt: Date(timeIntervalSince1970: Double(process.start) / 1_000_000),
                                          tool: tool))
        }

        // 3. Which session (if any) each process belongs to: the session pid or any descendant.
        let sessionPids = Set(sessions.map(\.pid))
        var sessionOf: [pid_t: pid_t] = [:]
        func owner(_ pid: pid_t) -> pid_t? {
            var current = pid
            var hops = 0
            while current > 1, hops < 64 {
                if let known = sessionOf[current] { return known }
                if sessionPids.contains(current) { return current }
                guard let parent = live[current]?.ppid, parent != current else { return nil }
                current = parent
                hops += 1
            }
            return nil
        }
        for pid in live.keys { if let s = owner(pid) { sessionOf[pid] = s } }

        // 4. Group by app.
        var groups: [String: AppUsage] = [:]
        var sessionTotals = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
        for (pid, process) in live {
            let key: String
            var app: AppUsage
            if let session = sessionOf[pid] {
                let tool = sessionTotals[session]?.tool ?? .claudeCode
                key = tool == .claudeCode ? "claude-code" : "agent:" + tool.rawValue
                app = groups[key] ?? AppUsage(id: key, name: tool.title, iconPath: tool == .claudeCode ? "/Applications/Claude.app" : nil,
                                              isClaude: tool == .claudeCode)
                if var s = sessionTotals[session] {
                    s.cpu += process.cpu
                    s.gpu += process.gpu
                    s.memory += process.memory
                    s.watts += process.watts
                    if pid == session {
                        s.ownCpu += process.cpu
                        s.ownMemory += process.memory
                    } else {
                        // Fold each process into the tool call it came from (the session's direct child),
                        // so a shell running a Python script reads as one task.
                        var top = pid
                        var hops = 0
                        while let parent = live[top]?.ppid, parent != session, parent > 1, hops < 64 { top = parent; hops += 1 }
                        if let i = s.tasks.firstIndex(where: { $0.pid == top }) {
                            s.tasks[i].cpu += process.cpu
                            s.tasks[i].memory += process.memory
                            s.tasks[i].pids.append(pid)
                        } else if let root = live[top] {
                            let age = Date().timeIntervalSince1970 - Double(root.start) / 1_000_000
                            s.tasks.append(ClaudeTask(pid: top, command: commandLine(top, start: root.start),
                                                      cpu: process.cpu, memory: process.memory, age: age, pids: [pid]))
                        }
                    }
                    sessionTotals[session] = s
                }
            } else {
                // Which app a process belongs to never changes while it lives, so work it out once.
                let group: (key: String, name: String, icon: String?)
                if let cached = groupOf[pid], cached.start == process.start {
                    group = cached.group
                } else {
                    let owner = responsible?(pid) ?? pid
                    let ownerIdentity = identities[owner] ?? identities[pid]
                    let ownPath = identities[pid]?.path ?? ""
                    if ownPath.contains(".simruntime/") || ownPath.contains("/CoreSimulator/") {
                        // Everything an iOS Simulator runs counts as one thing, not dozens of fake iPhone apps.
                        group = (Self.simulatorsKey, "iOS Simulators", Self.simulatorApp)
                    } else if let bundle = ownerIdentity.flatMap({ Self.appBundle(in: $0.path) }) ?? identities[pid].flatMap({ Self.appBundle(in: $0.path) }) {
                        group = (bundle, Self.displayName(bundle), bundle == "claude-code" ? "/Applications/Claude.app" : bundle)
                    } else {
                        let name = identities[pid]?.name ?? "pid \(pid)"
                        group = ("proc:" + name, name, nil)
                    }
                    groupOf[pid] = (process.start, group)
                }
                key = group.key
                app = groups[key] ?? AppUsage(id: key, name: group.name, iconPath: group.icon, isClaude: key == "claude-code")
            }
            app.cpu += process.cpu
            app.gpu += process.gpu
            app.memory += process.memory
            app.watts += process.watts
            app.processes += 1
            app.pids.append(pid)
            if process.uid == myUid { app.ownPids.append(pid) }
            groups[key] = app
        }

        let updatedSessions = sessions.map { session -> ClaudeSession in
            var s = sessionTotals[session.pid] ?? session
            // Agents other than Claude Code don't report a status: working means using the CPU.
            if s.tool != .claudeCode { s.status = s.cpu >= 2 ? "busy" : "idle" }
            s.tasks.sort { ($0.isBackground ? 1 : 0, -$0.cpu) < ($1.isBackground ? 1 : 0, -$1.cpu) }
            return s
        }
        return (Array(groups.values), updatedSessions)
    }

    static let simulatorsKey = "ios-simulators"
    static let simulatorApp = "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"

    // MARK: Identity helpers

    private var agentKinds: [pid_t: (start: UInt64, tool: AITool?)] = [:]
    private static let runtimes: Set<String> = ["node", "bun", "deno", "python", "python3", "Python"]

    /// Which agent a process is, from its name, or for node/bun/python from the script it runs.
    private func detectAgent(_ pid: pid_t) -> AITool? {
        let name = identities[pid]?.name ?? ""
        if let tool = AITool.executables[name] { return tool }
        guard Self.runtimes.contains(name) || name.hasPrefix("python3") else { return nil }
        for arg in Self.arguments(pid).dropFirst().prefix(3) {
            if let tool = AITool.executables[(arg as NSString).lastPathComponent] { return tool }
            if arg.contains("@google/gemini-cli") { return .gemini }
            if arg.contains("@openai/codex") { return .codex }
            if arg.contains("opencode-ai") { return .opencode }
            if arg.contains("@sourcegraph/amp") { return .amp }
        }
        return nil
    }

    /// A process's current folder.
    static func workingDirectory(_ pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    private static func name(from bsd: proc_bsdinfo) -> String {
        var info = bsd
        let long = withUnsafeBytes(of: &info.pbi_name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let trimmed = long.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}").union(.whitespaces))
        if !trimmed.isEmpty { return trimmed }
        return withUnsafeBytes(of: &info.pbi_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// The outermost .app bundle in a path, so helpers count toward their app.
    static func appBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<range.lowerBound]) + ".app"
        // Claude Code's own runtime ships as claude.app inside Application Support.
        if bundle.contains("/Claude/claude-code/") { return "claude-code" }
        return bundle
    }

    private static var names: [String: String] = [:]
    static func displayName(_ bundle: String) -> String {
        if bundle == "claude-code" { return "Claude Code" }
        if let cached = names[bundle] { return cached }
        let info = Bundle(path: bundle)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}").union(.whitespaces))
        names[bundle] = clean
        return clean
    }

    /// The command a process was started with, shortened for display: "swift build -c release".
    private func commandLine(_ pid: pid_t, start: UInt64) -> String {
        if let cached = commandLines[pid], cached.0 == start { return cached.1 }
        let text = Self.arguments(pid).map(Self.tidy).joined(separator: " ")
        let result = text.isEmpty ? (identities[pid]?.name ?? "process") : String(text.prefix(140))
        commandLines[pid] = (start, result)
        return result
    }

    private static func tidy(_ arg: String) -> String {
        // Paths read better as their last part: /opt/homebrew/bin/node -> node.
        if arg.hasPrefix("/"), !arg.contains(" ") { return (arg as NSString).lastPathComponent }
        return arg
    }

    static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }      // executable path
        while index < size, buffer[index] == 0 { index += 1 }      // padding
        var args: [String] = []
        var current: [UInt8] = []
        while index < size, args.count < min(Int(argc), 8) {
            if buffer[index] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll()
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        // Shells running a one-liner: show the one-liner, not "zsh -c".
        if args.count >= 3, ["zsh", "bash", "sh", "/bin/zsh", "/bin/bash", "/bin/sh"].contains(args[0]),
           let c = args.firstIndex(of: "-c") ?? args.firstIndex(of: "-lc"), c + 1 < args.count {
            return [cleanShell(args[c + 1])]
        }
        return args
    }

    /// Claude's Bash tool wraps commands in a snapshot-sourcing preamble; keep the actual command.
    private static func cleanShell(_ script: String) -> String {
        var s = script
        if let eval = s.range(of: "eval '") {
            s = String(s[eval.upperBound...])
            if let end = s.range(of: "' < /dev/null") ?? s.range(of: "'\n") { s = String(s[..<end.lowerBound]) }
            s = s.replacingOccurrences(of: "'\\''", with: "'")
        }
        // Skip setup steps (VAR=..., cd ...) and show the first real command, with … if more follow.
        let parts = s.components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .flatMap { $0.components(separatedBy: "&&") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let isSetup: (String) -> Bool = { part in
            if part.hasPrefix("cd ") || part.hasPrefix("export ") || part.hasPrefix("set ") || part.hasPrefix("source ") { return true }
            if let eq = part.firstIndex(of: "="), !part[..<eq].contains(" "), !part.contains(" ") || part.firstIndex(of: " ")! > eq {
                return part.split(separator: " ").allSatisfy { $0.contains("=") }
            }
            return false
        }
        guard let first = parts.firstIndex(where: { !isSetup($0) }) else { return parts.first ?? s }
        return parts[first] + (first < parts.count - 1 ? " …" : "")
    }
}

/// Running Claude Code sessions, from the files Claude Code keeps in ~/.claude/sessions.
enum ClaudeSessions {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    static func read() -> [ClaudeSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var sessions: [ClaudeSession] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 || errno == EPERM else { continue }
            let cwd = json["cwd"] as? String ?? ""
            var name = (json["name"] as? String) ?? ""
            if name.isEmpty || name == "New session" { name = (cwd as NSString).lastPathComponent }
            let started = (json["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            sessions.append(ClaudeSession(
                pid: pid,
                name: name,
                status: json["status"] as? String ?? "idle",
                folder: cwd,
                entrypoint: json["entrypoint"] as? String ?? "",
                startedAt: started
            ))
        }
        return sessions.sorted { ($0.isBusy ? 0 : 1, $0.startedAt ?? .distantPast) < ($1.isBusy ? 0 : 1, $1.startedAt ?? .distantPast) }
    }
}
