import Foundation

/// What the menu bar shows and the app's saved settings.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let defaults = UserDefaults.standard

    /// Metrics shown in the menu bar, in order.
    @Published var bar: [Metric] { didSet { save() } }
    @Published var interval: Double { didSet { save() } }
    @Published var colorAlerts: Bool { didSet { save() } }
    /// Boost: the apps (bundle paths) to quit, and whether to shut down iOS Simulators.
    @Published var boostApps: Set<String> { didSet { save() } }
    @Published var boostSimulators: Bool { didSet { save() } }
    /// Shut iOS Simulators down by themselves once Claude has been idle for 10 minutes.
    @Published var autoSimulators: Bool { didSet { save() } }
    /// Notify when the battery runs hot, naming the app that's working hardest.
    @Published var heatAlerts: Bool { didSet { save() } }

    private init() {
        bar = (defaults.stringArray(forKey: "bar") ?? ["cpu", "gpu", "ram", "temp"]).compactMap(Metric.init(rawValue:))
        interval = defaults.object(forKey: "interval") as? Double ?? 2
        colorAlerts = defaults.object(forKey: "colorAlerts") as? Bool ?? true
        boostApps = Set(defaults.stringArray(forKey: "boostApps") ?? [])
        boostSimulators = defaults.object(forKey: "boostSimulators") as? Bool ?? true
        autoSimulators = defaults.object(forKey: "autoSimulators") as? Bool ?? true
        heatAlerts = defaults.object(forKey: "heatAlerts") as? Bool ?? true
    }

    private func save() {
        defaults.set(bar.map(\.rawValue), forKey: "bar")
        defaults.set(interval, forKey: "interval")
        defaults.set(colorAlerts, forKey: "colorAlerts")
        defaults.set(Array(boostApps), forKey: "boostApps")
        defaults.set(boostSimulators, forKey: "boostSimulators")
        defaults.set(autoSimulators, forKey: "autoSimulators")
        defaults.set(heatAlerts, forKey: "heatAlerts")
    }

    func toggle(_ metric: Metric) {
        if let i = bar.firstIndex(of: metric) {
            bar.remove(at: i)
        } else {
            bar.append(metric)
        }
    }

    func move(_ metric: Metric, by offset: Int) {
        guard let i = bar.firstIndex(of: metric) else { return }
        let j = min(max(0, i + offset), bar.count - 1)
        guard i != j else { return }
        bar.swapAt(i, j)
    }
}
