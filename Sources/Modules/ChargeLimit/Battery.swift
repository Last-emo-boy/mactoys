import Foundation
import IOKit
import IOKit.ps

/// The battery as IOKit reports it (no privileges needed).
public struct BatterySnapshot: Equatable, Sendable, Codable {
    public var percent: Int
    public var isCharging: Bool
    public var adapterConnected: Bool
    public var fullyCharged: Bool
    public var cycleCount: Int?
    /// Cycles the battery is designed for (shown as "47 of 1,000").
    public var designCycleCount: Int?
    /// mAh.
    public var designCapacity: Int?
    /// What a full charge holds now, mAh.
    public var fullChargeCapacity: Int?
    /// °C.
    public var temperature: Double?
    /// V.
    public var voltage: Double?
    /// A; negative while discharging.
    public var amperage: Double?
    public var adapterName: String?
    public var adapterWatts: Int?
    /// Minutes, when macOS has an estimate.
    public var minutesToFull: Int?
    public var minutesToEmpty: Int?

    public init(percent: Int, isCharging: Bool, adapterConnected: Bool, fullyCharged: Bool = false, cycleCount: Int? = nil,
                designCycleCount: Int? = nil, designCapacity: Int? = nil, fullChargeCapacity: Int? = nil,
                temperature: Double? = nil, voltage: Double? = nil, amperage: Double? = nil, adapterName: String? = nil,
                adapterWatts: Int? = nil, minutesToFull: Int? = nil, minutesToEmpty: Int? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.adapterConnected = adapterConnected
        self.fullyCharged = fullyCharged
        self.cycleCount = cycleCount
        self.designCycleCount = designCycleCount
        self.designCapacity = designCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.temperature = temperature
        self.voltage = voltage
        self.amperage = amperage
        self.adapterName = adapterName
        self.adapterWatts = adapterWatts
        self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty
    }

    /// Maximum capacity relative to design, as System Settings shows it.
    public var healthPercent: Int? {
        guard let full = fullChargeCapacity, let design = designCapacity, design > 0 else { return nil }
        return min(100, Int((Double(full) / Double(design) * 100).rounded()))
    }

    /// Power into (+) or out of (−) the battery, W.
    public var batteryWatts: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    /// Parses the `AppleSmartBattery` registry properties, preferring the power-source percentage
    /// (`IOPSCopyPowerSourcesInfo`) that the menu bar shows.
    public init?(registry r: [String: Any], powerSourcePercent: Int? = nil) {
        func int(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber else { return nil }
            // Negative values (amperage) arrive as 64-bit two's complement.
            return Int(truncatingIfNeeded: n.int64Value)
        }
        func bool(_ value: Any?) -> Bool? { (value as? NSNumber)?.boolValue }
        let data = r["BatteryData"] as? [String: Any] ?? [:]
        let current = int(r["CurrentCapacity"])
        let max = int(r["MaxCapacity"])
        let percent: Int
        if let p = powerSourcePercent {
            percent = p
        } else if let current, let max, max > 0 {
            // Apple silicon reports percent (max 100); Intel reports mAh.
            percent = max <= 100 ? current : Int((Double(current) / Double(max) * 100).rounded())
        } else {
            return nil
        }
        self.percent = Swift.min(100, Swift.max(0, percent))
        isCharging = bool(r["IsCharging"]) ?? false
        adapterConnected = bool(r["ExternalConnected"]) ?? false
        fullyCharged = bool(r["FullyCharged"]) ?? false
        cycleCount = int(r["CycleCount"]) ?? int(data["CycleCount"])
        designCycleCount = int(r["DesignCycleCount9C"]) ?? int(r["DesignCycleCount"])
        designCapacity = int(r["DesignCapacity"]) ?? int(data["DesignCapacity"])
        fullChargeCapacity = int(r["NominalChargeCapacity"]) ?? int(data["NominalChargeCapacity"])
            ?? int(r["AppleRawMaxCapacity"]) ?? max.flatMap { $0 > 100 ? $0 : nil }
        temperature = (int(r["Temperature"]) ?? int(r["VirtualTemperature"])).map { Double($0) / 100 }
        voltage = int(r["Voltage"]).map { Double($0) / 1000 }
        amperage = (int(r["InstantAmperage"]).flatMap { $0 == 0 ? nil : $0 } ?? int(r["Amperage"])).map { Double($0) / 1000 }
        let adapter = r["AdapterDetails"] as? [String: Any]
        adapterName = (adapter?["Name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        adapterWatts = int(adapter?["Watts"]).flatMap { $0 > 0 ? $0 : nil }
        // 65535 means "still estimating".
        minutesToFull = int(r["AvgTimeToFull"]).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        minutesToEmpty = int(r["AvgTimeToEmpty"]).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
    }
}

/// Reads the battery from IOKit.
public enum BatteryReader {
    /// Nil on Macs without a battery.
    public static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return BatterySnapshot(registry: dict, powerSourcePercent: powerSourcePercent())
    }

    /// The internal battery's percentage as macOS shows it.
    static func powerSourcePercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }

    /// Whether this Mac has an internal battery.
    public static var hasBattery: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { if service != 0 { IOObjectRelease(service) } }
        return service != 0
    }
}

/// Calls back on the main run loop whenever a power source changes (plugged, unplugged, percent).
@MainActor
final class PowerSourceWatcher {
    private var source: CFRunLoopSource?
    var onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void = {}) {
        self.onChange = onChange
    }

    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        source = s
    }

    func stop() {
        guard let s = source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes)
        CFRunLoopSourceInvalidate(s)
        source = nil
    }
}
