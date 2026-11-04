import Foundation
import MacToysCore
import SwiftUI

/// What the hero, the flyout and the menu bar item show.
enum ChargeDisplay: Equatable {
    case unsupported(ChargeHardware.Unsupported)
    /// The user chose the limit built into macOS.
    case systemEngine
    /// Supported, but the helper isn't installed yet.
    case needsHelper
    /// Installed but not answering, or out of date.
    case helperProblem
    case live(HelperStatus)

    @MainActor
    static func of(_ model: ChargeLimitModel, settings: ChargeLimitSettings) -> ChargeDisplay {
        if let reason = model.hardware.unsupported { return .unsupported(reason) }
        if settings.engine == .system && model.systemLimit.available { return .systemEngine }
        switch model.helper {
        case .notInstalled: return .needsHelper
        case .notResponding, .outdated: return .helperProblem
        case .running(let status): return .live(status)
        }
    }
}

/// Localized text and styling for the limiter's states.
enum ChargeText {
    static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func temperature(_ celsius: Double, digits: Int = 1) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(digits))))
    }

    // MARK: State

    static func title(_ state: ChargeState, percent: Int?, config: ChargeConfig) -> String {
        switch state {
        case .chargingToLimit: String(localized: "Charging", comment: "Charge Limit state")
        case .holding:
            (percent ?? 0) >= config.upper
                ? String(localized: "Limit reached", comment: "Charge Limit state: the battery is at the limit")
                : String(localized: "Sailing", comment: "Charge Limit state: the battery drifts between the lower bound and the limit without charging")
        case .discharging: String(localized: "Discharging", comment: "Charge Limit state: running from the battery while plugged in")
        case .toppingUp: String(localized: "Topping up", comment: "Charge Limit state: charging to 100 % once")
        case .full: String(localized: "Full", comment: "Charge Limit state: topped up to 100 %")
        case .heatPaused: String(localized: "Too warm", comment: "Charge Limit state: charging paused because the battery is hot")
        case .paused: String(localized: "Paused", comment: "Charge Limit state: the limit is paused")
        case .onBattery: String(localized: "On battery", comment: "Charge Limit state: not plugged in")
        case .belowFloor: String(localized: "Low battery", comment: "Charge Limit state")
        case .asleep: String(localized: "Asleep", comment: "Charge Limit state: the Mac is asleep")
        case .calibrating: String(localized: "Calibrating", comment: "Charge Limit state: the calibration routine runs")
        }
    }

    static func symbol(_ state: ChargeState, percent: Int?, config: ChargeConfig) -> String {
        switch state {
        case .chargingToLimit: "bolt.fill"
        case .holding: (percent ?? 0) >= config.upper ? "checkmark.circle.fill" : "sailboat.fill"
        case .discharging: "arrow.down.circle.fill"
        case .toppingUp: "arrow.up.circle.fill"
        case .full: "checkmark.seal.fill"
        case .heatPaused: "thermometer.high"
        case .paused: "pause.circle.fill"
        case .onBattery: "battery.75percent"
        case .belowFloor: "exclamationmark.triangle.fill"
        case .asleep: "moon.fill"
        case .calibrating: "gauge.with.dots.needle.67percent"
        }
    }

    static func tint(_ state: ChargeState) -> Color {
        switch state {
        case .chargingToLimit, .holding: Tint.green.color
        case .discharging: Tint.orange.color
        case .toppingUp, .full: Tint.blue.color
        case .heatPaused, .belowFloor: Tint.red.color
        case .calibrating: Tint.purple.color
        case .paused, .onBattery, .asleep: Tint.graphite.color
        }
    }

    static func headline(_ state: ChargeState, config: ChargeConfig) -> String {
        let upper = percent(config.upper)
        switch state {
        case .chargingToLimit:
            return String(localized: "Charging to \(upper)", comment: "Charge Limit headline; the placeholder is the limit, e.g. 80%")
        case .holding:
            return config.lower < config.upper
                ? String(localized: "Held between \(percent(config.lower)) and \(upper)",
                         comment: "Charge Limit headline; placeholders are the lower bound and the limit")
                : String(localized: "Held at \(upper)", comment: "Charge Limit headline; the placeholder is the limit")
        case .discharging:
            return String(localized: "Running on battery down to \(upper)", comment: "Charge Limit headline while discharging to the limit")
        case .toppingUp:
            return String(localized: "Charging to \(percent(100)) once", comment: "Charge Limit headline during a top-up")
        case .full:
            return String(localized: "Topped up to \(percent(100))", comment: "Charge Limit headline after a top-up")
        case .heatPaused:
            return String(localized: "Charging paused while the battery is warm")
        case .paused:
            return String(localized: "Charging normally", comment: "Charge Limit headline while paused")
        case .onBattery:
            return String(localized: "Limit \(upper) when plugged in", comment: "Charge Limit headline on battery; the placeholder is the limit")
        case .belowFloor:
            return String(localized: "Charging normally below \(percent(ChargePolicy.floor))")
        case .asleep:
            return String(localized: "Charging normally while asleep")
        case .calibrating:
            switch config.calibration {
            case .chargeToFull, nil:
                return String(localized: "Step 1 of 3 · Charging to \(percent(100))", comment: "Calibration step headline")
            case .dischargeToTarget:
                return String(localized: "Step 2 of 3 · Running down to \(percent(ChargePolicy.calibrationTarget))", comment: "Calibration step headline")
            case .chargeToLimit:
                return String(localized: "Step 3 of 3 · Charging back to \(upper)", comment: "Calibration step headline")
            }
        }
    }

    static func detail(_ state: ChargeState, config: ChargeConfig, battery: BatterySnapshot?, hardware: ChargeHardware) -> String {
        switch state {
        case .chargingToLimit:
            if let b = battery, b.adapterConnected, !b.isCharging, b.percent < config.upper {
                return String(localized: "macOS isn't charging right now: its own charge limit or Optimized Battery Charging may be holding it.")
            }
            return adapterLine(battery) ?? String(localized: "Charging stops at the limit.")
        case .holding:
            return String(localized: "The adapter powers your Mac while the battery rests.")
        case .discharging:
            return String(localized: "The adapter is switched off until then.")
        case .toppingUp, .full:
            return String(localized: "The limit returns when you unplug.")
        case .heatPaused:
            let resume = temperature(Double(config.maxTemperature) - ChargePolicy.heatResumeMargin)
            if let t = battery?.temperature {
                return String(localized: "The battery is \(temperature(t)). Charging resumes below \(resume).",
                              comment: "Placeholders are temperatures")
            }
            return String(localized: "Charging resumes below \(resume).", comment: "The placeholder is a temperature")
        case .paused:
            return String(localized: "The limit is paused. Resume it any time.")
        case .onBattery:
            return String(localized: "Using the battery.")
        case .belowFloor:
            return String(localized: "Charge Limit never holds back a nearly empty battery.")
        case .asleep:
            return String(localized: "The limit applies again when your Mac wakes.")
        case .calibrating:
            if config.calibration == .dischargeToTarget, hardware.adapterSwitch == nil {
                return String(localized: "Unplug your Mac now and use it until it reaches \(percent(ChargePolicy.calibrationTarget)).")
            }
            return String(localized: "Takes a few hours. Keep your Mac plugged in.")
        }
    }

    /// "140W USB-C Power Adapter" (or the wattage alone).
    static func adapterLine(_ battery: BatterySnapshot?) -> String? {
        guard let b = battery, b.adapterConnected else { return nil }
        if let name = b.adapterName { return name }
        if let w = b.adapterWatts { return String(localized: "\(w) W power adapter", comment: "The placeholder is the adapter's wattage") }
        return String(localized: "Power adapter connected")
    }

    /// The menu bar flyout switch's second line: "Sailing · 78 % · limit 80 %".
    @MainActor
    static func statusLine(model: ChargeLimitModel, settings: ChargeLimitSettings) -> String {
        switch ChargeDisplay.of(model, settings: settings) {
        case .unsupported:
            return String(localized: "Not supported on this Mac")
        case .systemEngine:
            return String(localized: "Using the macOS charge limit")
        case .needsHelper:
            return String(localized: "Helper not installed")
        case .helperProblem:
            return String(localized: "Helper not responding")
        case .live(let status):
            let p = model.battery?.percent ?? status.percent
            let title = Self.title(status.state, percent: p, config: status.config)
            let limit = percent(status.config.upper)
            guard let p else { return title }
            return String(localized: "\(title) · \(percent(p)) · limit \(limit)",
                          comment: "Menu bar status: state, battery level, charge limit")
        }
    }

    static func unsupportedReason(_ reason: ChargeHardware.Unsupported) -> String {
        switch reason {
        case .noBattery:
            return String(localized: "This Mac has no battery.")
        case .noSMC:
            return String(localized: "MacToys can't read this Mac's power controller.")
        case .noKnownKeys:
            return String(localized: "Its firmware has none of the charging switches MacToys knows, so MacToys leaves charging alone.")
        case .unexpectedFormat(let keys):
            let list = keys.formatted(.list(type: .and, width: .narrow))
            return String(localized: "Its firmware reports \(list) in a format MacToys doesn't know, so MacToys leaves charging alone.",
                          comment: "The placeholder lists SMC keys with their formats")
        }
    }
}
