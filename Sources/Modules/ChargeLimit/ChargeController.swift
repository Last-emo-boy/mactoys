import Foundation

/// One reading of the battery, as the controller sees it.
public struct ChargeInputs: Equatable, Sendable {
    public var percent: Int
    public var adapterConnected: Bool
    public var isCharging: Bool
    public var fullyCharged: Bool
    public var temperature: Double?
    public var asleep: Bool
    public var now: Date

    public init(percent: Int, adapterConnected: Bool, isCharging: Bool = false, fullyCharged: Bool = false,
                temperature: Double? = nil, asleep: Bool = false, now: Date = Date()) {
        self.percent = percent
        self.adapterConnected = adapterConnected
        self.isCharging = isCharging
        self.fullyCharged = fullyCharged
        self.temperature = temperature
        self.asleep = asleep
        self.now = now
    }
}

/// What the controller remembers between readings (hysteresis). Not persisted: after a restart the
/// helper restores normal charging and begins fresh.
public struct ChargeMemory: Equatable, Sendable {
    /// The limit was reached; charging stays off until the battery drifts down to the lower bound.
    public var holding = false
    /// Heat protection paused charging at this time.
    public var heatPausedSince: Date?
    /// Heat protection last let charging resume at this time.
    public var heatResumedAt: Date?

    public init() {}
}

/// The switch positions for one reading.
public struct ChargeDecision: Equatable, Sendable {
    public var charging: ChargingCommand
    public var adapter: AdapterCommand
    /// For Macs with a firmware-kept limit: the limit to set (100 = charge normally).
    public var firmwareLimit: Int
    public var led: LEDColor
    public var state: ChargeState
    /// Seconds until the next reading.
    public var nextCheck: TimeInterval

    public init(charging: ChargingCommand, adapter: AdapterCommand, firmwareLimit: Int = 100, led: LEDColor,
                state: ChargeState, nextCheck: TimeInterval) {
        self.charging = charging
        self.adapter = adapter
        self.firmwareLimit = firmwareLimit
        self.led = led
        self.state = state
        self.nextCheck = nextCheck
    }

    /// Charging as if Charge Limit didn't exist.
    public static func normal(_ state: ChargeState, nextCheck: TimeInterval = ChargeController.relaxed,
                              firmwareLimit: Int = 100) -> ChargeDecision {
        ChargeDecision(charging: .allow, adapter: .enabled, firmwareLimit: firmwareLimit, led: .system,
                       state: state, nextCheck: nextCheck)
    }

    /// Whether this decision changes nothing compared with normal charging.
    public var isNormal: Bool { charging == .allow && adapter == .enabled && firmwareLimit == 100 && led == .system }
}

/// The charge limiter: a pure function from settings, memory and a battery reading to switch positions.
///
/// Priorities, highest first: sleep and the hard floor restore normal charging; a pause restores normal
/// charging; on battery there's nothing to switch; calibration and top-up override the limit; then the
/// limit itself with its sailing range, discharge-to-limit and heat protection.
public enum ChargeController {
    /// Polling intervals.
    public static let relaxed: TimeInterval = 30
    public static let near: TimeInterval = 10
    public static let unplugged: TimeInterval = 60

    public static func step(config: inout ChargeConfig, memory: inout ChargeMemory, inputs: ChargeInputs,
                            capabilities caps: ControlCapabilities) -> ChargeDecision {
        let p = inputs.percent
        // Unplugging ends a top-up.
        if !inputs.adapterConnected { config.topUp = false }
        advanceCalibration(&config, memory: &memory, inputs: inputs)
        // A firmware-kept limit is safe to leave in place: it never stops charging below the limit.
        let keptFirmwareLimit = caps.firmwareLimit && config.isLimiting ? config.upper : 100

        if inputs.asleep {
            return .normal(.asleep, nextCheck: unplugged, firmwareLimit: keptFirmwareLimit)
        }
        if p < ChargePolicy.floor {
            memory.holding = false
            return .normal(.belowFloor, nextCheck: near)
        }
        if config.paused {
            memory.holding = false
            memory.heatPausedSince = nil
            return .normal(.paused)
        }
        if !inputs.adapterConnected {
            // Nothing to switch; calibration keeps counting down while the user discharges it.
            let state: ChargeState = config.calibration == nil ? .onBattery : .calibrating
            let check = config.calibration == .dischargeToTarget && p <= ChargePolicy.calibrationTarget + 2 ? near : unplugged
            return .normal(state, nextCheck: check, firmwareLimit: keptFirmwareLimit)
        }

        updateHeat(config: config, memory: &memory, inputs: inputs)
        var decision: ChargeDecision
        if let phase = config.calibration {
            decision = calibrating(phase, config: config, inputs: inputs, caps: caps)
        } else if config.topUp {
            decision = ChargeDecision(charging: .allow, adapter: .enabled, led: p >= 100 ? .green : .orange,
                                      state: p >= 100 ? .full : .toppingUp, nextCheck: relaxed)
            memory.holding = true
            applyHeat(&decision, memory: memory, caps: caps)
        } else {
            decision = limiting(config: config, memory: &memory, inputs: inputs, caps: caps)
            applyHeat(&decision, memory: memory, caps: caps)
        }
        if let t = inputs.temperature, config.heatProtection, abs(t - Double(config.maxTemperature)) <= 1.5 {
            decision.nextCheck = min(decision.nextCheck, near)
        }
        decision.led = led(for: decision, mode: config.led, caps: caps)
        return decision
    }

    // MARK: - Limit

    private static func limiting(config: ChargeConfig, memory: inout ChargeMemory, inputs: ChargeInputs,
                                 caps: ControlCapabilities) -> ChargeDecision {
        let p = inputs.percent
        let upper = config.upper
        let lower = min(config.lower, upper)
        let nearLimit = abs(p - upper) <= 2 || abs(p - lower) <= 1
        let check = nearLimit ? near : relaxed

        if !caps.chargingSwitch {
            // Firmware-kept limit: it stops at the limit by itself; only discharge needs a switch.
            if config.dischargeToLimit && caps.adapterSwitch && p > upper {
                return ChargeDecision(charging: .allow, adapter: .disabled, firmwareLimit: upper, led: .orange,
                                      state: .discharging, nextCheck: near)
            }
            let held = p >= upper
            return ChargeDecision(charging: .allow, adapter: .enabled, firmwareLimit: upper, led: held ? .green : .orange,
                                  state: held ? .holding : .chargingToLimit, nextCheck: check)
        }

        if config.dischargeToLimit && caps.adapterSwitch && p > upper {
            memory.holding = true
            return ChargeDecision(charging: .inhibit, adapter: .disabled, led: .orange, state: .discharging, nextCheck: near)
        }
        if p >= upper || (memory.holding && p > lower) {
            memory.holding = true
            return ChargeDecision(charging: .inhibit, adapter: .enabled, led: .green, state: .holding, nextCheck: check)
        }
        memory.holding = false
        return ChargeDecision(charging: .allow, adapter: .enabled, led: .orange, state: .chargingToLimit, nextCheck: check)
    }

    // MARK: - Calibration

    /// Moves to the next phase when the current one is done (also while unplugged, so a manual
    /// discharge counts).
    private static func advanceCalibration(_ config: inout ChargeConfig, memory: inout ChargeMemory, inputs: ChargeInputs) {
        let p = inputs.percent
        if config.calibration == .chargeToFull, inputs.adapterConnected, p >= 100, inputs.fullyCharged || !inputs.isCharging {
            config.calibration = .dischargeToTarget
        }
        if config.calibration == .dischargeToTarget, p <= ChargePolicy.calibrationTarget {
            config.calibration = .chargeToLimit
        }
        if config.calibration == .chargeToLimit, inputs.adapterConnected, p >= config.upper {
            config.calibration = nil
            config.lastCalibrated = inputs.now
            memory.holding = true
        }
    }

    private static func calibrating(_ phase: CalibrationPhase, config: ChargeConfig, inputs: ChargeInputs,
                                    caps: ControlCapabilities) -> ChargeDecision {
        switch phase {
        case .chargeToFull:
            return ChargeDecision(charging: .allow, adapter: .enabled, led: .orange, state: .calibrating,
                                  nextCheck: inputs.percent >= 98 ? near : relaxed)
        case .dischargeToTarget:
            let check = inputs.percent <= ChargePolicy.calibrationTarget + 3 ? near : relaxed
            if caps.adapterSwitch {
                return ChargeDecision(charging: caps.chargingSwitch ? .inhibit : .allow, adapter: .disabled,
                                      firmwareLimit: caps.chargingSwitch ? 100 : ChargePolicy.upperRange.lowerBound,
                                      led: .orange, state: .calibrating, nextCheck: check)
            }
            // No adapter switch: hold the charge and let the user unplug (the settings page says so).
            return ChargeDecision(charging: caps.chargingSwitch ? .inhibit : .allow, adapter: .enabled,
                                  firmwareLimit: caps.chargingSwitch ? 100 : ChargePolicy.upperRange.lowerBound,
                                  led: .orange, state: .calibrating, nextCheck: check)
        case .chargeToLimit:
            return ChargeDecision(charging: .allow, adapter: .enabled, led: .orange, state: .calibrating,
                                  nextCheck: abs(inputs.percent - config.upper) <= 2 ? near : relaxed)
        }
    }

    // MARK: - Heat protection

    private static func updateHeat(config: ChargeConfig, memory: inout ChargeMemory, inputs: ChargeInputs) {
        guard config.heatProtection, config.calibration == nil, let t = inputs.temperature else {
            memory.heatPausedSince = nil
            return
        }
        let limit = Double(config.maxTemperature)
        let now = inputs.now
        if let since = memory.heatPausedSince {
            if t <= limit - ChargePolicy.heatResumeMargin, now.timeIntervalSince(since) >= ChargePolicy.heatMinimumInterval {
                memory.heatPausedSince = nil
                memory.heatResumedAt = now
            }
        } else if t >= limit {
            let ranLongEnough = memory.heatResumedAt.map { now.timeIntervalSince($0) >= ChargePolicy.heatMinimumInterval } ?? true
            if ranLongEnough || t >= limit + ChargePolicy.heatEmergencyMargin {
                memory.heatPausedSince = now
            }
        }
    }

    /// A heat pause stops charging that would otherwise run; it never starts discharging. It needs a
    /// charging switch (a firmware-kept limit can't pause below the limit).
    private static func applyHeat(_ decision: inout ChargeDecision, memory: ChargeMemory, caps: ControlCapabilities) {
        guard caps.chargingSwitch, memory.heatPausedSince != nil, decision.charging == .allow, decision.adapter == .enabled,
              decision.state == .chargingToLimit || decision.state == .toppingUp else { return }
        decision.charging = .inhibit
        decision.state = .heatPaused
        decision.led = .orange
        decision.nextCheck = min(decision.nextCheck, near)
    }

    // MARK: - LED

    private static func led(for decision: ChargeDecision, mode: LEDMode, caps: ControlCapabilities) -> LEDColor {
        guard caps.led else { return .system }
        switch mode {
        case .system: return .system
        case .off: return .off
        case .limitState: return decision.led
        }
    }
}
