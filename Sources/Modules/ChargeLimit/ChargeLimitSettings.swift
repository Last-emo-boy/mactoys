import Foundation
import MacToysCore

/// Charge Limit's settings in MacToys (the helper keeps its own copy of what it acts on).
public struct ChargeLimitSettings: Codable, Equatable, Sendable {
    /// Who limits charging when macOS offers its own limit too.
    public enum Engine: String, Codable, CaseIterable, Sendable {
        case macToys
        case system
    }

    public var engine: Engine = .macToys
    public var upperLimit = 80
    /// How far below the limit the battery may drift before charging again.
    public var sailingRange = 5
    public var dischargeToLimit = false
    public var heatProtection = false
    public var maxTemperature = 35
    public var ledMode: LEDMode = .system
    /// The user paused the limit (kept across launches; the helper is also paused while the module is off).
    public var limitPaused = false
    public var showMenuBarItem = false
    public var showPercentInMenuBar = true
    public var toggleShortcut: Shortcut?
    public var topUpShortcut: Shortcut?

    public init() {}

    public var lowerLimit: Int {
        let upper = min(max(upperLimit, ChargePolicy.upperRange.lowerBound), ChargePolicy.upperRange.upperBound)
        return max(upper - min(max(sailingRange, 0), ChargePolicy.sailingRange.upperBound), ChargePolicy.lowestLower(for: upper))
    }

    /// The helper requests that make its configuration match these settings.
    public func requests(toMatch current: ChargeConfig, capabilities caps: ControlCapabilities) -> [HelperRequest] {
        var out: [HelperRequest] = []
        let upper = min(max(upperLimit, ChargePolicy.upperRange.lowerBound), ChargePolicy.upperRange.upperBound)
        let lower = caps.chargingSwitch ? lowerLimit : upper
        if current.upper != upper || current.lower != lower { out.append(.setLimit(lower: lower, upper: upper)) }
        let discharge = dischargeToLimit && caps.adapterSwitch
        if current.dischargeToLimit != discharge { out.append(.setDischarge(discharge)) }
        let heat = heatProtection && caps.chargingSwitch
        let maxT = min(max(maxTemperature, ChargePolicy.temperatureRange.lowerBound), ChargePolicy.temperatureRange.upperBound)
        if current.heatProtection != heat || (heat && current.maxTemperature != maxT) {
            out.append(.setHeat(enabled: heat, maxCelsius: maxT))
        }
        let led = caps.led ? ledMode : .system
        if current.led != led { out.append(.setLED(led)) }
        return out
    }
}
