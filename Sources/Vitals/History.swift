import Foundation

/// One moment in the history: every system value, plus (for minute points) who was using the most.
struct HistoryPoint: Codable {
    var t: Double                       // seconds since 1970
    var v: [String: Double]
    var top: [String: [TopUser]]? = nil // keyed by TopKind
}

struct TopUser: Codable, Hashable {
    var n: String   // app or session name
    var v: Double   // its value at the time (CPU %, GPU %, bytes, watts)
}

/// Which list of top users a chart shows.
enum TopKind: String { case cpu, gpu, memory, energy, claude }

/// Keeps a fine history (every sample, last 15 minutes), a minute-by-minute history for the last
/// 24 hours, and one point per hour kept for good (weeks, months, all time). Saved to disk so it
/// survives restarts. Small: about 1,440 minute points plus 24 hour points a day (~5 MB a year).
final class HistoryStore {
    private(set) var fine: [HistoryPoint] = []
    private(set) var minutes: [HistoryPoint] = []
    private(set) var hours: [HistoryPoint] = []
    private var hourBucket: [HistoryPoint] = []
    private var bucket: [String: (sum: Double, count: Int)] = [:]
    private var bucketMinute: Int = 0
    private var latestTop: [String: [TopUser]] = [:]
    private var lastSave: Double = 0

    static let fineSpan: Double = 15 * 60
    static let keep: Double = 24 * 3600
    private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vitals")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()
    private lazy var hoursFile = file.deletingLastPathComponent().appendingPathComponent("history-hours.json")

    init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            let cutoff = Date().timeIntervalSince1970 - Self.keep
            minutes = saved.filter { $0.t >= cutoff }
        }
        if let data = try? Data(contentsOf: hoursFile), let saved = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            hours = saved
        }
        // Minutes newer than the last hour point: finished hours become hour points now,
        // the current hour waits in the bucket.
        let lastHour = hours.last.map { Int($0.t / 3600) } ?? Int.min
        let pending = minutes.filter { Int($0.t / 3600) > lastHour }
        let grouped = Dictionary(grouping: pending) { Int($0.t / 3600) }
        let current = Int(Date().timeIntervalSince1970 / 3600)
        for hour in grouped.keys.sorted() {
            if hour < current { hours.append(Self.merge(grouped[hour]!, hour: hour)) } else { hourBucket = grouped[hour]! }
        }
        if grouped.keys.contains(where: { $0 < current }) { saveHours() }
    }

    /// One hour point from its minute points: averaged values, and the names that used the most.
    private static func merge(_ points: [HistoryPoint], hour: Int) -> HistoryPoint {
        var sums: [String: Double] = [:]
        for p in points { for (k, v) in p.v { sums[k, default: 0] += v } }
        let avg = sums.mapValues { ($0 / Double(points.count) * 100).rounded() / 100 }
        var top: [String: [TopUser]] = [:]
        for kind in [TopKind.cpu, .gpu, .memory, .energy, .claude] {
            var totals: [String: Double] = [:]
            var samples = 0
            for p in points { if let list = p.top?[kind.rawValue] { samples += 1; for u in list { totals[u.n, default: 0] += u.v } } }
            if samples > 0 {
                top[kind.rawValue] = totals.map { TopUser(n: $0.key, v: ($0.value / Double(samples) * 10).rounded() / 10) }
                    .sorted { $0.v > $1.v }.prefix(3).map { $0 }
            }
        }
        return HistoryPoint(t: Double(hour) * 3600 + 1800, v: avg, top: top.isEmpty ? nil : top)
    }

    private func saveHours() {
        guard let data = try? JSONEncoder().encode(hours) else { return }
        try? data.write(to: hoursFile, options: .atomic)
    }

    func add(_ values: [String: Double], at time: Double) {
        fine.append(HistoryPoint(t: time, v: values))
        if let first = fine.first, time - first.t > Self.fineSpan + 60 {
            fine.removeAll { time - $0.t > Self.fineSpan }
        }

        let minute = Int(time / 60)
        if minute != bucketMinute, !bucket.isEmpty {
            let averaged = bucket.mapValues { $0.sum / Double(max(1, $0.count)) }
            let point = HistoryPoint(t: Double(bucketMinute) * 60 + 30, v: averaged, top: latestTop.isEmpty ? nil : latestTop)
            minutes.append(point)
            let hour = Int(point.t / 3600)
            if let first = hourBucket.first, Int(first.t / 3600) != hour {
                hours.append(Self.merge(hourBucket, hour: Int(first.t / 3600)))
                hourBucket.removeAll()
                saveHours()
            }
            hourBucket.append(point)
            bucket.removeAll()
            let cutoff = time - Self.keep
            if let first = minutes.first, first.t < cutoff { minutes.removeAll { $0.t < cutoff } }
        }
        bucketMinute = minute
        for (key, value) in values {
            let current = bucket[key] ?? (0, 0)
            bucket[key] = (current.sum + value, current.count + 1)
        }
        if time - lastSave > 120, !minutes.isEmpty { save(); lastSave = time }
    }

    /// The top users from the latest app scan, stored with the next minute point.
    func setTop(apps: [AppUsage], sessions: [ClaudeSession]) {
        func top(_ value: (AppUsage) -> Double) -> [TopUser] {
            apps.map { TopUser(n: $0.name, v: value($0)) }.filter { $0.v > 0 }.sorted { $0.v > $1.v }.prefix(4).map {
                TopUser(n: $0.n, v: ($0.v * 10).rounded() / 10)
            }
        }
        latestTop = [
            TopKind.cpu.rawValue: top(\.cpu),
            TopKind.gpu.rawValue: top(\.gpu),
            TopKind.memory.rawValue: top { Double($0.memory) },
            TopKind.energy.rawValue: top(\.watts),
            TopKind.claude.rawValue: sessions.filter(\.isBusy).map { TopUser(n: $0.name, v: ($0.cpu * 10).rounded() / 10) }.sorted { $0.v > $1.v },
        ]
    }

    var currentTop: [String: [TopUser]] { latestTop }

    /// A believable day of history for demo screenshots.
    func loadDemo(now: Double) {
        func value(_ i: Double, _ base: Double, _ swing: Double, _ seed: Double) -> Double {
            max(0, base + swing * (sin(i / 40 + seed) * 0.55 + sin(i / 9 + seed * 2) * 0.3 + sin(i / 2.7 + seed * 3) * 0.15))
        }
        let top: [String: [TopUser]] = [
            TopKind.cpu.rawValue: [TopUser(n: "Xcode", v: 11.4), TopUser(n: "Claude Code", v: 8.2), TopUser(n: "Figma", v: 4.1)],
            TopKind.gpu.rawValue: [TopUser(n: "Figma", v: 12), TopUser(n: "Safari", v: 4), TopUser(n: "Xcode", v: 3)],
            TopKind.memory.rawValue: [TopUser(n: "Xcode", v: 3.3e9), TopUser(n: "Docker", v: 2.4e9), TopUser(n: "Safari", v: 2e9)],
            TopKind.energy.rawValue: [TopUser(n: "Xcode", v: 1.4), TopUser(n: "Claude Code", v: 1), TopUser(n: "Figma", v: 0.5)],
            TopKind.claude.rawValue: [TopUser(n: "Ship the onboarding flow", v: 6.1), TopUser(n: "Fix flaky checkout tests", v: 2.1)],
        ]
        func point(_ t: Double, _ i: Double) -> HistoryPoint {
            HistoryPoint(t: t, v: [
                "cpu": value(i, 30, 16, 1), "gpu": value(i, 22, 12, 2), "ram": value(i, 68, 4, 3), "temp": value(i, 56, 5, 4),
                "power": value(i, 12, 5, 5), "netIn": value(i, 1.6e6, 1.2e6, 6), "netOut": value(i, 2e5, 1.5e5, 7),
                "diskRead": value(i, 1e7, 8e6, 8), "diskWrite": value(i, 5e6, 4e6, 9), "battery": 80, "claude": value(i, 2, 1, 10).rounded(),
            ], top: top)
        }
        minutes = (0..<1440).map { point(now - Double(1440 - $0) * 60, Double($0)) }
        hours = (0..<(24 * 30)).map { point(now - Double(24 * 30 - $0) * 3600, Double($0) * 3) }
        fine = (0..<300).map { point(now - Double(300 - $0) * 2, Double($0) / 4) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(minutes) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// Points covering the last `span` seconds: fine samples for short ranges, minutes beyond that.
    func points(span: Double, now: Double) -> [HistoryPoint] {
        if span <= Self.fineSpan {
            return fine.filter { now - $0.t <= span }
        }
        if span > Self.keep {
            // Weeks and months: hour points, then this hour's minutes up to now.
            var result = hours.filter { now - $0.t <= span }
            let last = result.last?.t ?? 0
            result += minutes.filter { $0.t > last + 1800 }
            return downsample(result, to: 360)
        }
        var result = minutes.filter { now - $0.t <= span }
        // Bring the chart up to the present with the newest samples.
        if let last = result.last?.t { result += fine.filter { $0.t > last + 30 } } else { result = fine }
        if span > 6 * 3600 { return downsample(result, to: 360) }
        return result
    }

    private func downsample(_ points: [HistoryPoint], to count: Int) -> [HistoryPoint] {
        guard points.count > count else { return points }
        let size = Int(ceil(Double(points.count) / Double(count)))
        return stride(from: 0, to: points.count, by: size).map { start in
            let slice = points[start..<min(points.count, start + size)]
            var sums: [String: Double] = [:]
            for p in slice { for (k, v) in p.v { sums[k, default: 0] += v } }
            let avg = sums.mapValues { $0 / Double(slice.count) }
            return HistoryPoint(t: slice.map(\.t).reduce(0, +) / Double(slice.count), v: avg, top: slice.last?.top)
        }
    }

    /// Who used the most over a range: average of each name's share across the minutes it appears in.
    func topOver(span: Double, now: Double, kind: TopKind) -> [TopUser] {
        let relevant = (span > Self.keep ? hours : minutes).filter { now - $0.t <= span }
        var totals: [String: Double] = [:]
        var samples = 0
        for point in relevant {
            guard let list = point.top?[kind.rawValue] else { continue }
            samples += 1
            for user in list { totals[user.n, default: 0] += user.v }
        }
        if samples == 0 { return latestTop[kind.rawValue] ?? [] }
        return totals.map { TopUser(n: $0.key, v: $0.value / Double(samples)) }.sorted { $0.v > $1.v }.prefix(6).map { $0 }
    }
}
