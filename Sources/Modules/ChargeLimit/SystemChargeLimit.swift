import Darwin
import Foundation

/// macOS's own charge limit (Battery settings › Charging), offered on Apple silicon MacBooks from
/// macOS 26.4. Charge Limit explains it and lets the user pick it instead.
public struct SystemChargeLimit: Equatable, Sendable {
    /// The Battery settings offer a charge limit on this Mac.
    public var available: Bool
    /// The limit macOS applies right now, when it is below 100 % and could be read.
    public var activeLimit: Int?

    public init(available: Bool, activeLimit: Int? = nil) {
        self.available = available
        self.activeLimit = activeLimit
    }

    public static let unavailable = SystemChargeLimit(available: false)

    /// Where powerd keeps its charging policies (world-readable).
    public static let policiesFile = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")
    /// System Settings › Battery.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!

    public static func detect(os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                              appleSilicon: Bool = isAppleSilicon, hasBattery: Bool = BatteryReader.hasBattery,
                              policies: Data? = try? Data(contentsOf: policiesFile)) -> SystemChargeLimit {
        let newEnough = os.majorVersion > 26 || (os.majorVersion == 26 && os.minorVersion >= 4)
        guard newEnough, appleSilicon, hasBattery else { return .unavailable }
        return SystemChargeLimit(available: true, activeLimit: policies.flatMap(manualLimit(fromPreferences:)))
    }

    /// The manual charge limit in powerd's preferences file: a property list whose `policies` entry is
    /// a keyed archive of charge-control policies. Nil when there is none (or the format changed).
    static func manualLimit(fromPreferences data: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = plist["policies"] as? Data else { return nil }
        return manualLimit(fromArchive: archive)
    }

    static func manualLimit(fromArchive data: Data) -> Int? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.setClass(ChargePolicyRecord.self, forClassName: ChargePolicyRecord.archivedClassName)
        defer { unarchiver.finishDecoding() }
        guard let records = unarchiver.decodeObject(of: [NSArray.self, ChargePolicyRecord.self],
                                                    forKey: NSKeyedArchiveRootObjectKey) as? [ChargePolicyRecord] else { return nil }
        return records.first { $0.reason == ChargePolicyRecord.manualReason }?.socLimit
            .flatMap { (1...99).contains($0) ? $0 : nil }
    }

    public static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }
}

/// Decodes the fields Charge Limit reads from one archived powerd charge-control policy.
@objc(MacToysChargePolicyRecord)
final class ChargePolicyRecord: NSObject, NSSecureCoding {
    static let archivedClassName = "ChargeCtrlPolicy"
    static let manualReason = "manualChargeLimit"
    static var supportsSecureCoding: Bool { true }

    let reason: String?
    let socLimit: Int?

    init(reason: String?, socLimit: Int?) {
        self.reason = reason
        self.socLimit = socLimit
    }

    required init?(coder: NSCoder) {
        reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
        socLimit = coder.containsValue(forKey: "soclimit") ? coder.decodeInteger(forKey: "soclimit") : nil
    }

    func encode(with coder: NSCoder) {
        coder.encode(reason as NSString?, forKey: "reason")
        if let socLimit { coder.encode(socLimit, forKey: "soclimit") }
    }
}
