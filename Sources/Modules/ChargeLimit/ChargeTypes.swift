import Foundation

/// Limits and fixed thresholds shared by the app, the helper and the protocol validation.
public enum ChargePolicy {
    /// The charge limit the user can choose.
    public static let upperRange = 50...100
    /// How far below the limit the battery may drift before charging starts again.
    public static let sailingRange = 0...20
    /// Heat protection threshold, in °C.
    public static let temperatureRange = 30...45
    /// Below this the helper always restores normal charging, whatever else is going on. Nothing the
    /// helper does on purpose goes this low (calibration stops discharging at `calibrationTarget`).
    public static let floor = 10
    /// The calibration routine discharges down to this level.
    public static let calibrationTarget = 15
    /// Heat protection: a pause lasts at least this long, and once charging resumes it runs at least
    /// this long before pausing again (unless the battery gets much hotter).
    public static let heatMinimumInterval: TimeInterval = 5 * 60
    /// Charging resumes when the battery is this much cooler than the threshold.
    public static let heatResumeMargin = 1.5
    /// Above threshold + this, heat protection pauses at once, even right after resuming.
    public static let heatEmergencyMargin = 3.0

    /// The lowest allowed lower bound for a given limit.
    public static func lowestLower(for upper: Int) -> Int { upper - sailingRange.upperBound }
}

/// What the MagSafe LED shows while Charge Limit runs.
public enum LEDMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Leave it to macOS.
    case system
    /// Green when held at the limit, orange while charging or discharging toward it.
    case limitState
    /// Always off.
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: String(localized: "Follow macOS", comment: "MagSafe LED mode")
        case .limitState: String(localized: "Show the charge limit", comment: "MagSafe LED mode: green at the limit, orange on the way")
        case .off: String(localized: "Off", comment: "MagSafe LED mode: the light stays off")
        }
    }
}

/// The guided calibration routine: charge to full, discharge to 15 %, charge back to the limit.
public enum CalibrationPhase: String, Codable, CaseIterable, Sendable {
    case chargeToFull
    case dischargeToTarget
    case chargeToLimit

    public var step: Int {
        switch self {
        case .chargeToFull: 1
        case .dischargeToTarget: 2
        case .chargeToLimit: 3
        }
    }
}

/// Everything the helper acts on. The app owns the first block (pushed with `setLimit`, `setDischarge`,
/// `setHeat`, `setLED`); the second block is runtime state changed by quick actions.
public struct ChargeConfig: Codable, Equatable, Sendable {
    public var upper = 80
    public var lower = 75
    public var dischargeToLimit = false
    public var heatProtection = false
    public var maxTemperature = 35
    public var led: LEDMode = .system

    /// Normal charging until resumed (also set while the module is turned off).
    public var paused = false
    /// Charge to 100 % once; ends when the Mac is unplugged.
    public var topUp = false
    public var calibration: CalibrationPhase?
    public var lastCalibrated: Date?

    public init() {}

    /// The limiter is doing its normal job (not paused, topping up or calibrating).
    public var isLimiting: Bool { !paused && !topUp && calibration == nil }

    /// Clamps every field into its allowed range (used on values loaded from disk).
    public func sanitized() -> ChargeConfig {
        var c = self
        c.upper = min(max(c.upper, ChargePolicy.upperRange.lowerBound), ChargePolicy.upperRange.upperBound)
        c.lower = min(max(c.lower, ChargePolicy.lowestLower(for: c.upper)), c.upper)
        c.maxTemperature = min(max(c.maxTemperature, ChargePolicy.temperatureRange.lowerBound),
                               ChargePolicy.temperatureRange.upperBound)
        return c
    }
}

/// What the charging switch should do.
public enum ChargingCommand: String, Codable, Sendable {
    case allow, inhibit
}

/// What the adapter switch should do ("disabled" runs the Mac from its battery while plugged in).
public enum AdapterCommand: String, Codable, Sendable {
    case enabled, disabled
}

/// MagSafe LED colors the helper can set.
public enum LEDColor: String, Codable, Sendable {
    case system, off, green, orange
}

/// What the limiter is doing right now.
public enum ChargeState: String, Codable, Sendable {
    case paused
    case chargingToLimit
    case holding
    case discharging
    case toppingUp
    case full
    case heatPaused
    case onBattery
    case belowFloor
    case asleep
    case calibrating
}

/// The hardware switches the controller may use.
public struct ControlCapabilities: Equatable, Sendable {
    /// A switch that stops and resumes charging at any level.
    public var chargingSwitch: Bool
    /// A firmware-kept limit instead of a switch (older Intel Macs).
    public var firmwareLimit: Bool
    /// A switch that runs the Mac from its battery while plugged in.
    public var adapterSwitch: Bool
    public var led: Bool

    public init(chargingSwitch: Bool, firmwareLimit: Bool = false, adapterSwitch: Bool, led: Bool) {
        self.chargingSwitch = chargingSwitch
        self.firmwareLimit = firmwareLimit
        self.adapterSwitch = adapterSwitch
        self.led = led
    }

    public static let none = ControlCapabilities(chargingSwitch: false, adapterSwitch: false, led: false)
}
