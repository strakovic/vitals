import Darwin
import Foundation
import IOKit

/// System-wide readers. Each one is cheap: a few syscalls or IOKit property reads,
/// no subprocesses, so sampling every couple of seconds costs next to nothing.

// MARK: - CPU

final class CPUReader {
    private var previous: [[UInt32]] = []
    let efficiencyCores: Int = sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    /// Total busy share (0...1) and one value per core, since the last call.
    func read() -> (total: Double, cores: [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for core in 0..<Int(count) {
            current.append((0..<states).map { UInt32(bitPattern: info[core * states + $0]) })
        }
        defer { previous = current }
        guard previous.count == current.count else { return (0, Array(repeating: 0, count: current.count)) }
        var busyAll = 0.0, totalAll = 0.0
        var cores: [Double] = []
        for (now, before) in zip(current, previous) {
            let d = (0..<states).map { Double(now[$0] &- before[$0]) }
            let idle = d[Int(CPU_STATE_IDLE)]
            let total = d.reduce(0, +)
            let busy = total - idle
            busyAll += busy
            totalAll += total
            cores.append(total > 0 ? busy / total : 0)
        }
        return (totalAll > 0 ? busyAll / totalAll : 0, cores)
    }
}

// MARK: - Memory

struct MemoryInfo {
    var used: UInt64 = 0
    var total: UInt64 = 0
    var compressed: UInt64 = 0
    var swap: UInt64 = 0
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var pressure: Int = 1
    var share: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum MemoryReader {
    static func read() -> MemoryInfo {
        var info = MemoryInfo()
        info.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // Same sum Activity Monitor calls Memory Used: app memory + wired + compressed.
            let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
            info.used = (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
            info.compressed = UInt64(stats.compressor_page_count) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { info.swap = swap.xsu_used }
        info.pressure = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return info
    }
}

// MARK: - GPU

struct GPUInfo {
    var utilization: Double = 0
    var memory: UInt64 = 0
    /// Accumulated GPU nanoseconds per process since it opened the GPU.
    var timeByPid: [pid_t: UInt64] = [:]
}

enum GPUReader {
    /// Reads the Apple GPU's utilization and, when asked, each client's GPU time.
    static func read(perProcess: Bool) -> GPUInfo {
        var info = GPUInfo()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return info }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = property(service, "PerformanceStatistics") as? [String: Any] {
                if let u = stats["Device Utilization %"] as? NSNumber { info.utilization = max(info.utilization, u.doubleValue / 100) }
                if let m = stats["In use system memory"] as? NSNumber { info.memory += m.uint64Value }
            }
            if perProcess {
                var children: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
                    var child = IOIteratorNext(children)
                    while child != 0 {
                        if let creator = property(child, "IOUserClientCreator") as? String,
                           let pid = parsePid(creator),
                           let usage = property(child, "AppUsage") as? [[String: Any]] {
                            let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                            info.timeByPid[pid, default: 0] += ns
                        }
                        IOObjectRelease(child)
                        child = IOIteratorNext(children)
                    }
                    IOObjectRelease(children)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return info
    }

    /// "pid 422, WindowServer" -> 422
    private static func parsePid(_ creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }
}

// MARK: - Temperature (Apple Silicon HID sensors, no root needed)

final class ThermalReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private var client: CFTypeRef?
    private var sensors: [(name: String, service: CFTypeRef)] = []
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"),
              let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let p = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue") else { return }
        copyEvent = unsafeBitCast(e, to: CopyEvent.self)
        getFloat = unsafeBitCast(f, to: GetFloat.self)
        guard let client = unsafeBitCast(c, to: CreateClient.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Vendor page 0xff00, usage 5: temperature sensors.
        _ = unsafeBitCast(m, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = unsafeBitCast(s, to: CopyServices.self)(client)?.takeRetainedValue() else { return }
        let copyProperty = unsafeBitCast(p, to: CopyProperty.self)
        for i in 0..<CFArrayGetCount(services) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: CFTypeRef.self)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "sensor"
            allSensors.append((name, service))
        }
        // Reading a sensor takes about 1.5 ms, so day to day only the CPU dies and one battery sensor are read.
        sensors = allSensors.filter { $0.name.hasPrefix("PMU tdie") }
        if sensors.isEmpty { sensors = allSensors.filter { $0.name.contains("tdie") } }
        if let battery = allSensors.first(where: { $0.name.lowercased().contains("battery") }) { sensors.append(battery) }
        if sensors.isEmpty { sensors = allSensors }
    }

    private var allSensors: [(name: String, service: CFTypeRef)] = []

    /// Every sensor on the machine (slow; for --dump).
    func readEverything() -> [(name: String, celsius: Double)] {
        let saved = sensors
        sensors = allSensors
        defer { sensors = saved }
        return readAll()
    }


    /// Every sensor's reading in degrees Celsius, skipping obviously bogus ones.
    func readAll() -> [(name: String, celsius: Double)] {
        guard let copyEvent, let getFloat else { return [] }
        let type: Int64 = 15 // kIOHIDEventTypeTemperature
        var result: [(String, Double)] = []
        for sensor in sensors {
            guard let event = copyEvent(sensor.service, type, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, Int32(type << 16))
            if value > 1, value < 130 { result.append((sensor.name, value)) }
        }
        return result
    }

    /// CPU die temperature (hottest "tdie" sensor), battery temperature, and the hottest of all.
    func read() -> (cpu: Double, battery: Double, hottest: Double) {
        let all = readAll()
        let die = all.filter { $0.name.lowercased().contains("tdie") }.map(\.celsius)
        let cpu = die.max() ?? all.filter { $0.name.hasPrefix("PMU") }.map(\.celsius).max() ?? 0
        let battery = all.first { $0.name.lowercased().contains("battery") }?.celsius ?? 0
        return (cpu, battery, all.map(\.celsius).max() ?? 0)
    }
}

// MARK: - Power and battery

struct PowerInfo {
    /// Whole-system power draw in watts (from the battery's telemetry), 0 if unknown.
    var systemWatts: Double = 0
    var batteryPercent: Double = 0
    var charging = false
    var pluggedIn = false
    var hasBattery = false
    /// Minutes, when macOS has an estimate.
    var timeRemaining: Int?
    var cycleCount = 0
    /// Full charge today as a share of the battery's design capacity (0...1), 0 if unknown.
    var health: Double = 0
    /// Battery pack temperature in °C from the gas gauge, 0 if unknown.
    var batteryTemp: Double = 0
    /// Full charge today and when new, in mAh.
    var capacityNow = 0
    var capacityDesign = 0
    /// On the adapter, not full, and macOS chose not to charge (a charge limit or optimized charging).
    var held = false
}

enum PowerReader {
    static func read() -> PowerInfo {
        var info = PowerInfo()
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return info }
        defer { IOObjectRelease(battery) }
        info.hasBattery = true
        info.batteryPercent = (property(battery, "CurrentCapacity") as? NSNumber)?.doubleValue ?? 0
        info.charging = (property(battery, "IsCharging") as? Bool) ?? false
        info.pluggedIn = (property(battery, "ExternalConnected") as? Bool) ?? false
        if let minutes = (property(battery, "TimeRemaining") as? NSNumber)?.intValue, minutes > 0, minutes < 6000 {
            info.timeRemaining = minutes
        }
        info.cycleCount = (property(battery, "CycleCount") as? NSNumber)?.intValue ?? 0
        if let data = property(battery, "BatteryData") as? [String: Any] {
            let design = (data["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
            // NominalChargeCapacity is what System Settings uses for "Maximum Capacity".
            let raw = (data["NominalChargeCapacity"] as? NSNumber)?.doubleValue
                ?? (data["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue ?? 0
            if design > 0, raw > 0 { info.health = min(1, raw / design) }
            info.capacityNow = Int(raw)
            info.capacityDesign = Int(design)
            if let t = (data["Temperature"] as? NSNumber)?.doubleValue, t > 0 { info.batteryTemp = t / 100 }
        }
        if info.batteryTemp == 0, let t = (property(battery, "Temperature") as? NSNumber)?.doubleValue, t > 0 {
            info.batteryTemp = t / 100
        }
        if info.pluggedIn, !info.charging, info.batteryPercent < 99,
           let charger = property(battery, "ChargerData") as? [String: Any],
           ((charger["NotChargingReason"] as? NSNumber)?.intValue ?? 0) != 0 {
            info.held = true
        }
        if let telemetry = property(battery, "PowerTelemetryData") as? [String: Any],
           let mw = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue, mw > 0 {
            info.systemWatts = mw / 1000
        }
        if info.systemWatts == 0 || !info.pluggedIn {
            // On battery: volts x amps. Amperage is a signed 64-bit value stored unsigned.
            let mv = (property(battery, "Voltage") as? NSNumber)?.doubleValue ?? 0
            let raw = (property(battery, "InstantAmperage") as? NSNumber) ?? (property(battery, "Amperage") as? NSNumber)
            let ma = Double(Int64(bitPattern: raw?.uint64Value ?? 0))
            let watts = abs(mv * ma) / 1_000_000
            if !info.pluggedIn, watts > 0 { info.systemWatts = watts }
        }
        return info
    }
}

// MARK: - Network and disk throughput (cumulative bytes; Monitor turns them into rates)

enum NetworkReader {
    static func totals() -> (received: UInt64, sent: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var received: UInt64 = 0, sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if message.ifm_flags & IFF_LOOPBACK == 0 {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }
}

enum DiskReader {
    static func totals() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = property(service, "Statistics") as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, written)
    }
}

// MARK: - Helpers

func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

/// Mach absolute time units to nanoseconds (they differ on Apple Silicon: 125/3).
let machToNanos: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom)
}()


/// The charge limit macOS itself enforces (System Settings > Battery > Charging), nil when off.
enum ChargeLimit {
    static func current() -> Int? {
        guard let limit = ChargeControl.limit(), limit < 100 else { return nil }
        return limit
    }
}
