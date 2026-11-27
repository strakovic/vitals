import SwiftUI

/// What one agent session is made of: the agent's own process, each task it is running and each
/// helper (MCP servers, dev servers) it keeps around, with two split bars for CPU and memory.
struct UsageBreakdown: View {
    var session: ClaudeSession
    var tasks: [ClaudeTask]
    var refresh: () -> Void = {}
    @State private var focus: pid_t?

    struct Part: Identifiable {
        var id: pid_t
        var name: String
        var detail: String
        var kind: String
        var cpu: Double
        var memory: UInt64
        var color: Color
        var task: ClaudeTask?
    }

    private static let palette: [Color] = [
        Color(red: 0.42, green: 0.74, blue: 1),      // blue
        Theme.orange,
        Color(red: 0.76, green: 0.56, blue: 1),      // violet
        Color(red: 0.34, green: 0.88, blue: 0.74),   // teal
        Color(red: 1, green: 0.5, blue: 0.68),       // pink
    ]

    private var parts: [Part] { Self.parts(session: session, tasks: tasks) }

    /// The agent first, then its tasks in their colours, then helpers in greys. Shared with the closed card.
    static func parts(session: ClaudeSession, tasks: [ClaudeTask]) -> [Part] {
        var list = [Part(id: session.pid, name: session.tool.title, detail: "the agent itself", kind: "AGENT",
                         cpu: session.ownCpu, memory: session.ownMemory, color: Theme.lime)]
        var working = 0, helping = 0
        for task in tasks {
            let color: Color
            if task.isBackground {
                color = Color.white.opacity([0.42, 0.3, 0.2][helping % 3]); helping += 1
            } else {
                color = palette[working % palette.count]; working += 1
            }
            list.append(Part(id: task.pid, name: Self.shortName(task.command), detail: task.command,
                             kind: task.isBackground ? "HELPER" : "TASK", cpu: task.cpu, memory: task.memory,
                             color: color, task: task))
        }
        return list
    }

    var body: some View {
        let parts = parts
        VStack(alignment: .leading, spacing: 7) {
            VStack(spacing: 5) {
                SplitBar(label: "CPU", total: String(format: "%.0f%%", parts.reduce(0) { $0 + $1.cpu }),
                         parts: parts.map { ($0.id, $0.cpu, $0.color) }, focus: focus)
                SplitBar(label: "MEM", total: Fmt.bytes(parts.reduce(0) { $0 + $1.memory }),
                         parts: parts.map { ($0.id, Double($0.memory), $0.color) }, focus: focus)
            }
            .padding(.horizontal, 2)

            VStack(spacing: 1) {
                ForEach(parts) { part in
                    PartRow(part: part, share: share(part, in: parts), focus: $focus, refresh: refresh)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: focus)
        .contentShape(Rectangle())
        .onTapGesture {}   // clicks inside the breakdown don't fold the card
    }

    /// Share of the session's memory, the steadier of the two numbers.
    private func share(_ part: Part, in parts: [Part]) -> Double {
        let total = parts.reduce(0) { $0 + Double($1.memory) }
        return total > 0 ? Double(part.memory) / total : 0
    }

    /// "npx -y @playwright/mcp" reads as "playwright/mcp", "node ~/mcp/github-server/index.js" as "github-server".
    static func shortName(_ command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        guard let first = words.first else { return command }
        let runners: Set<String> = ["node", "npx", "bunx", "bun", "uv", "uvx", "python", "python3", "deno", "pnpm", "yarn", "sh", "bash", "zsh", "env", "ruby"]
        var name = (first as NSString).lastPathComponent
        if runners.contains(name) || name.hasPrefix("python"),
           let target = words.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "run" && $0 != "exec" && !$0.contains("=") }) {
            var path = target
            let file = (path as NSString).lastPathComponent
            // An entry file like index.js says less than the folder it lives in.
            if ["index.js", "index.mjs", "main.py", "server.js", "dist", "build"].contains(file) || file.hasPrefix("index.") {
                path = (path as NSString).deletingLastPathComponent
            }
            name = target.hasPrefix("@") ? String(target.dropFirst()) : (path as NSString).lastPathComponent
            name = (name as NSString).deletingPathExtension.isEmpty ? name : (name as NSString).deletingPathExtension
            if name.contains("/"), !target.hasPrefix("@") { name = (name as NSString).lastPathComponent }
        } else if words.count > 1, !words[1].hasPrefix("-") {
            name += " " + words[1]   // "swift build", "cargo test", "npm run dev"
            if words[1] == "run", words.count > 2, !words[2].hasPrefix("-") { name += " " + words[2] }
        }
        return name.isEmpty ? command : name
    }
}

/// A thin bar split by part, with the total at the end. The focused part stays bright.
struct SplitBar: View {
    var label: String
    var total: String
    var parts: [(id: pid_t, value: Double, color: Color)]
    var focus: pid_t?
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.caps(7)).kerning(0.6).foregroundStyle(Theme.faint)
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                let sum = parts.reduce(0) { $0 + $1.value }
                let shown = parts.filter { $0.value > 0 }
                let gaps = CGFloat(max(0, shown.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(shown, id: \.id) { part in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(part.color.opacity(focus == nil || focus == part.id ? 1 : 0.22))
                            .frame(width: max(2, (geo.size.width - gaps) * part.value / max(sum, 0.0001)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .clipShape(Capsule())
            }
            .frame(height: compact ? 4 : 6)
            Text(total).font(Theme.regular(compact ? 9 : 10)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                .frame(width: compact ? 0 : 48, alignment: .trailing)
                .opacity(compact ? 0 : 1)
        }
    }
}

private struct PartRow: View {
    var part: UsageBreakdown.Part
    var share: Double
    @Binding var focus: pid_t?
    var refresh: () -> Void
    @State private var stopping: StopState = .none
    private var hovering: Bool { focus == part.id }

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(part.color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(part.name).font(Theme.regular(10.5)).foregroundStyle(.white.opacity(part.kind == "HELPER" ? 0.6 : 0.92))
                        .lineLimit(1).truncationMode(.middle)
                    Text(part.kind).font(Theme.caps(6)).kerning(0.5).foregroundStyle(Theme.faint)
                }
                if hovering, part.task != nil {
                    Text(part.detail).font(Theme.mono(8.5)).foregroundStyle(Theme.faint)
                        .lineLimit(1).truncationMode(.middle)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 6)
            Text(String(format: part.cpu < 10 ? "%.1f%%" : "%.0f%%", part.cpu))
                .font(Theme.regular(10)).monospacedDigit()
                .foregroundStyle(part.cpu > 12 ? Theme.orange : part.cpu < 0.05 ? Theme.faint : .white.opacity(0.75))
                .frame(width: 38, alignment: .trailing)
            Text(Fmt.bytes(part.memory))
                .font(Theme.regular(10)).monospacedDigit().foregroundStyle(.white.opacity(0.75))
                .frame(width: 48, alignment: .trailing)
            Text(String(format: "%.0f%%", share * 100))
                .font(Theme.light(9)).monospacedDigit().foregroundStyle(Theme.faint)
                .frame(width: 26, alignment: .trailing)
            if let task = part.task {
                StopButton(state: stopping, visible: hovering, help: "Stop this \(part.kind == "HELPER" ? "helper" : "task")") {
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
                .frame(width: 20, height: 15)
            } else {
                Color.clear.frame(width: 20, height: 15)
            }
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hovering ? 0.06 : 0)))
        .opacity(stopping == .stopping ? 0.45 : 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { focus = part.id } else if focus == part.id { focus = nil }
        }
    }
}
