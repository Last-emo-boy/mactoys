import Foundation

/// The charging hardware of this Mac, found by reading (never writing) the SMC.
public struct ChargeHardware: Equatable, Sendable, Codable {
    public enum ChargingSwitch: String, Codable, Sendable {
        /// `CHTE` (newer Apple silicon firmware).
        case chte
        /// `CH0B` alone, or with `CH0C` (older Apple silicon firmware).
        case ch0b, ch0bc
        /// `BCLM`, a firmware-kept limit (Intel).
        case bclm
    }

    public enum AdapterSwitch: String, Codable, Sendable {
        case chie, ch0i
    }

    /// Why charging can't be controlled here.
    public enum Unsupported: Equatable, Sendable, Codable {
        case noBattery
        case noSMC
        /// None of the known charging switches exists on this firmware.
        case noKnownKeys
        /// A known key exists but in a format Charge Limit doesn't know; it won't touch it.
        case unexpectedFormat([String])
    }

    public var chargingSwitch: ChargingSwitch?
    public var adapterSwitch: AdapterSwitch?
    public var led: Bool
    public var batteryPresent: Bool
    public var smcAvailable: Bool
    /// Known keys present in an unknown format, e.g. "CHTE (ui16, 2 bytes)". Never written.
    public var unexpected: [String]

    public init(chargingSwitch: ChargingSwitch?, adapterSwitch: AdapterSwitch?, led: Bool, batteryPresent: Bool = true,
                smcAvailable: Bool = true, unexpected: [String] = []) {
        self.chargingSwitch = chargingSwitch
        self.adapterSwitch = adapterSwitch
        self.led = led
        self.batteryPresent = batteryPresent
        self.smcAvailable = smcAvailable
        self.unexpected = unexpected
    }

    /// Reads key types through `info` (nil = key absent) and picks the switches it knows.
    public static func detect(smcAvailable: Bool, batteryPresent: Bool, info: (ChargeKey) -> SMCKeyInfo?) -> ChargeHardware {
        var unexpected: [String] = []
        func usable(_ key: ChargeKey) -> Bool {
            guard let found = info(key) else { return false }
            if key.accepts(found) { return true }
            unexpected.append("\(key.rawValue) (\(found.type.trimmingCharacters(in: .whitespaces)), \(found.size) bytes)")
            return false
        }
        guard smcAvailable else {
            return ChargeHardware(chargingSwitch: nil, adapterSwitch: nil, led: false, batteryPresent: batteryPresent, smcAvailable: false)
        }
        let charging: ChargingSwitch?
        if usable(.chte) { charging = .chte }
        else if usable(.ch0b) { charging = usable(.ch0c) ? .ch0bc : .ch0b }
        else if usable(.bclm) { charging = .bclm }
        else { charging = nil }
        let adapter: AdapterSwitch? = usable(.chie) ? .chie : usable(.ch0i) ? .ch0i : nil
        let led = usable(.aclc)
        return ChargeHardware(chargingSwitch: charging, adapterSwitch: adapter, led: led, batteryPresent: batteryPresent,
                              smcAvailable: true, unexpected: unexpected)
    }

    /// Reads this Mac.
    public static func probe(batteryPresent: Bool) -> ChargeHardware {
        guard let smc = SMCConnection() else { return detect(smcAvailable: false, batteryPresent: batteryPresent) { _ in nil } }
        return detect(smcAvailable: true, batteryPresent: batteryPresent) { smc.keyInfo($0.rawValue) }
    }

    /// Nil when Charge Limit can work here.
    public var unsupported: Unsupported? {
        if !batteryPresent { return .noBattery }
        if !smcAvailable { return .noSMC }
        if chargingSwitch != nil { return nil }
        return unexpected.isEmpty ? .noKnownKeys : .unexpectedFormat(unexpected)
    }

    public var isSupported: Bool { unsupported == nil }

    public var capabilities: ControlCapabilities {
        guard isSupported else { return .none }
        return ControlCapabilities(chargingSwitch: chargingSwitch != .bclm && chargingSwitch != nil,
                                   firmwareLimit: chargingSwitch == .bclm,
                                   adapterSwitch: adapterSwitch != nil, led: led)
    }

    /// The keys used, for the settings page ("CHTE · CHIE · ACLC").
    public var keyNames: [String] {
        var keys: [ChargeKey] = []
        switch chargingSwitch {
        case .chte: keys.append(.chte)
        case .ch0b: keys.append(.ch0b)
        case .ch0bc: keys += [.ch0b, .ch0c]
        case .bclm: keys.append(.bclm)
        case nil: break
        }
        switch adapterSwitch {
        case .chie: keys.append(.chie)
        case .ch0i: keys.append(.ch0i)
        case nil: break
        }
        if led { keys.append(.aclc) }
        return keys.map(\.rawValue)
    }

    // MARK: - Writes

    private var chargingKeys: [ChargeKey] {
        switch chargingSwitch {
        case .chte: [.chte]
        case .ch0b: [.ch0b]
        case .ch0bc: [.ch0b, .ch0c]
        case .bclm, nil: []
        }
    }

    private var adapterKey: ChargeKey? {
        switch adapterSwitch {
        case .chie: .chie
        case .ch0i: .ch0i
        case nil: nil
        }
    }

    /// The writes that move the switches from `previous` (nil: unknown, write everything) to `decision`.
    /// The LED is left alone until Charge Limit has a color to show.
    public func writes(for decision: ChargeDecision, since previous: ChargeDecision?) -> [WhitelistedWrite] {
        guard isSupported else { return [] }
        var out: [WhitelistedWrite] = []
        // Adapter first when turning it back on, so the Mac is never left without either.
        if decision.adapter == .enabled, previous?.adapter != .enabled, let key = adapterKey {
            out += [WhitelistedWrite.adapter(.enabled, key: key)].compactMap { $0 }
        }
        if chargingSwitch == .bclm {
            if previous?.firmwareLimit != decision.firmwareLimit {
                out += [WhitelistedWrite.firmwareLimit(decision.firmwareLimit)].compactMap { $0 }
            }
        } else if previous?.charging != decision.charging {
            out += chargingKeys.compactMap { WhitelistedWrite.charging(decision.charging, key: $0) }
        }
        if decision.adapter == .disabled, previous?.adapter != .disabled, let key = adapterKey {
            out += [WhitelistedWrite.adapter(.disabled, key: key)].compactMap { $0 }
        }
        if led, decision.led != (previous?.led ?? .system) {
            out.append(WhitelistedWrite.led(decision.led))
        }
        return out
    }

    /// Normal charging: adapter on, charging allowed (or the firmware limit at 100 %). The LED is reset
    /// only when Charge Limit changed it.
    public func restoreWrites(resetLED: Bool) -> [WhitelistedWrite] {
        guard isSupported else { return [] }
        var out: [WhitelistedWrite] = []
        if let key = adapterKey { out += [WhitelistedWrite.adapter(.enabled, key: key)].compactMap { $0 } }
        if chargingSwitch == .bclm {
            out += [WhitelistedWrite.firmwareLimit(100)].compactMap { $0 }
        } else {
            out += chargingKeys.compactMap { WhitelistedWrite.charging(.allow, key: $0) }
        }
        if led && resetLED { out.append(WhitelistedWrite.led(.system)) }
        return out
    }
}
