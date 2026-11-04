import Foundation
import Testing
@testable import ChargeLimit
@testable import MacToysCore

// Pure tests only: nothing here opens the SMC for writing or talks to an installed helper.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let full = ControlCapabilities(chargingSwitch: true, adapterSwitch: true, led: true)
private let noAdapter = ControlCapabilities(chargingSwitch: true, adapterSwitch: false, led: false)
private let firmware = ControlCapabilities(chargingSwitch: false, firmwareLimit: true, adapterSwitch: true, led: false)

/// Runs the controller over a sequence of readings, keeping config and memory between them.
private struct Sim {
    var config = ChargeConfig()
    var memory = ChargeMemory()
    var caps = full

    mutating func step(_ percent: Int, plugged: Bool = true, charging: Bool = false, full: Bool = false,
                       temp: Double? = nil, asleep: Bool = false, at seconds: TimeInterval = 0) -> ChargeDecision {
        ChargeController.step(config: &config, memory: &memory,
                              inputs: ChargeInputs(percent: percent, adapterConnected: plugged, isCharging: charging,
                                                   fullyCharged: full, temperature: temp, asleep: asleep,
                                                   now: t0.addingTimeInterval(seconds)),
                              capabilities: caps)
    }
}

@Suite struct ChargeControllerTests {
    @Test func chargesBelowTheLimitAndHoldsAtIt() {
        var sim = Sim()
        let low = sim.step(60, charging: true)
        #expect(low.charging == .allow)
        #expect(low.adapter == .enabled)
        #expect(low.state == .chargingToLimit)
        let at = sim.step(80)
        #expect(at.charging == .inhibit)
        #expect(at.state == .holding)
        #expect(sim.memory.holding)
    }

    @Test func sailsDownToTheLowerBoundBeforeChargingAgain() {
        var sim = Sim()
        sim.config.upper = 80
        sim.config.lower = 75
        _ = sim.step(80)
        for p in [79, 78, 77, 76] { #expect(sim.step(p).charging == .inhibit, "holding at \(p)") }
        let resumed = sim.step(75)
        #expect(resumed.charging == .allow)
        #expect(!sim.memory.holding)
        // Charging continues back up through the range until the limit.
        #expect(sim.step(76, charging: true).charging == .allow)
        #expect(sim.step(79, charging: true).charging == .allow)
        #expect(sim.step(80).charging == .inhibit)
    }

    @Test func zeroSailingRangeHoldsAtTheLimit() {
        var sim = Sim()
        sim.config.upper = 70
        sim.config.lower = 70
        #expect(sim.step(70).charging == .inhibit)
        #expect(sim.step(69).charging == .allow)
        #expect(sim.step(70).charging == .inhibit)
    }

    @Test func startingAboveTheLimitHoldsWithoutDischarge() {
        var sim = Sim()
        let d = sim.step(95)
        #expect(d.charging == .inhibit)
        #expect(d.adapter == .enabled)
        #expect(d.state == .holding)
    }

    @Test func dischargesToTheLimitWhenAskedAndPossible() {
        var sim = Sim()
        sim.config.dischargeToLimit = true
        let above = sim.step(90)
        #expect(above.adapter == .disabled)
        #expect(above.charging == .inhibit)
        #expect(above.state == .discharging)
        #expect(above.nextCheck == ChargeController.near)
        let reached = sim.step(80)
        #expect(reached.adapter == .enabled)
        #expect(reached.state == .holding)
        // Without an adapter switch it only holds.
        var plain = Sim(caps: noAdapter)
        plain.config.dischargeToLimit = true
        let held = plain.step(90)
        #expect(held.adapter == .enabled)
        #expect(held.state == .holding)
    }

    @Test func topUpChargesToFullOnceAndEndsOnUnplug() {
        var sim = Sim()
        sim.config.topUp = true
        let d = sim.step(85, charging: true)
        #expect(d.charging == .allow)
        #expect(d.state == .toppingUp)
        #expect(sim.step(100, full: true).state == .full)
        #expect(sim.step(100, full: true).charging == .allow)
        let unplugged = sim.step(99, plugged: false)
        #expect(!sim.config.topUp)
        #expect(unplugged.state == .onBattery)
        // Plugged back in above the limit: holds again.
        let back = sim.step(97)
        #expect(back.charging == .inhibit)
        #expect(back.state == .holding)
    }

    @Test func heatProtectionPausesWithHysteresis() {
        var sim = Sim()
        sim.config.heatProtection = true
        sim.config.maxTemperature = 35
        #expect(sim.step(60, charging: true, temp: 34).charging == .allow)
        let hot = sim.step(60, charging: true, temp: 35.2, at: 0)
        #expect(hot.charging == .inhibit)
        #expect(hot.state == .heatPaused)
        // Cooled, but the pause lasts at least five minutes.
        #expect(sim.step(60, temp: 33, at: 60).state == .heatPaused)
        // Not cool enough yet (needs 1.5 °C below the limit).
        #expect(sim.step(60, temp: 34, at: 400).state == .heatPaused)
        let resumed = sim.step(60, temp: 33, at: 420)
        #expect(resumed.charging == .allow)
        #expect(resumed.state == .chargingToLimit)
        // Warm again within five minutes: keeps charging…
        #expect(sim.step(61, charging: true, temp: 35.5, at: 480).charging == .allow)
        // …unless it gets much hotter.
        #expect(sim.step(61, charging: true, temp: 38.2, at: 500).state == .heatPaused)
    }

    @Test func heatProtectionNeverStartsDischargeOrOverridesHolding() {
        var sim = Sim()
        sim.config.heatProtection = true
        sim.config.maxTemperature = 35
        let d = sim.step(80, temp: 40)
        #expect(d.state == .holding)
        #expect(d.adapter == .enabled)
        // Not available with a firmware-kept limit.
        var fw = Sim(caps: firmware)
        fw.config.heatProtection = true
        #expect(fw.step(60, temp: 40).state == .chargingToLimit)
    }

    @Test func floorAlwaysRestoresNormalCharging() {
        var sim = Sim()
        sim.config.dischargeToLimit = true
        sim.config.calibration = .chargeToLimit
        let d = sim.step(ChargePolicy.floor - 1)
        #expect(d.isNormal)
        #expect(d.state == .belowFloor)
    }

    @Test func pausedSleepingAndUnpluggedChargeNormally() {
        var paused = Sim()
        paused.config.paused = true
        #expect(paused.step(90).isNormal)
        #expect(paused.step(90).state == .paused)

        var sleeping = Sim()
        sleeping.config.dischargeToLimit = true
        let asleep = sleeping.step(90, asleep: true)
        #expect(asleep.isNormal)
        #expect(asleep.state == .asleep)

        var unplugged = Sim()
        let battery = unplugged.step(85, plugged: false)
        #expect(battery.isNormal)
        #expect(battery.state == .onBattery)
        #expect(battery.nextCheck == ChargeController.unplugged)
    }

    @Test func wakingUpAboveTheLimitHoldsAgain() {
        var sim = Sim()
        _ = sim.step(80)
        #expect(sim.step(80, asleep: true).isNormal)
        // Charged while asleep; on wake the limit applies again.
        #expect(sim.step(93).charging == .inhibit)
    }

    @Test func calibrationRunsItsThreePhases() {
        var sim = Sim()
        sim.config.calibration = .chargeToFull
        let charging = sim.step(70, charging: true)
        #expect(charging.charging == .allow)
        #expect(charging.state == .calibrating)
        // Full: starts discharging while plugged in.
        let discharge = sim.step(100, full: true)
        #expect(sim.config.calibration == .dischargeToTarget)
        #expect(discharge.adapter == .disabled)
        #expect(discharge.charging == .inhibit)
        #expect(sim.step(40).adapter == .disabled)
        let back = sim.step(ChargePolicy.calibrationTarget)
        #expect(sim.config.calibration == .chargeToLimit)
        #expect(back.charging == .allow)
        #expect(back.adapter == .enabled)
        let done = sim.step(80, at: 3600)
        #expect(sim.config.calibration == nil)
        #expect(sim.config.lastCalibrated == t0.addingTimeInterval(3600))
        #expect(done.state == .holding)
    }

    @Test func calibrationWithoutAdapterSwitchWaitsForUnplug() {
        var sim = Sim(caps: noAdapter)
        sim.config.calibration = .dischargeToTarget
        let plugged = sim.step(60)
        #expect(plugged.adapter == .enabled)
        #expect(plugged.charging == .inhibit)
        // Unplugged, the countdown continues.
        let unplugged = sim.step(30, plugged: false)
        #expect(unplugged.state == .calibrating)
        _ = sim.step(15, plugged: false)
        #expect(sim.config.calibration == .chargeToLimit)
    }

    @Test func firmwareLimitSetsTheLimitInsteadOfSwitching() {
        var sim = Sim(caps: firmware)
        let d = sim.step(60)
        #expect(d.charging == .allow)
        #expect(d.firmwareLimit == 80)
        #expect(sim.step(80).state == .holding)
        sim.config.paused = true
        #expect(sim.step(80).firmwareLimit == 100)
        sim.config.paused = false
        sim.config.topUp = true
        #expect(sim.step(85).firmwareLimit == 100)
        // A firmware limit is safe while asleep, so it stays.
        var asleep = Sim(caps: firmware)
        #expect(asleep.step(70, asleep: true).firmwareLimit == 80)
    }

    @Test func ledFollowsTheChosenMode() {
        var sim = Sim()
        sim.config.led = .limitState
        #expect(sim.step(60, charging: true).led == .orange)
        #expect(sim.step(80).led == .green)
        sim.config.led = .off
        #expect(sim.step(80).led == .off)
        sim.config.led = .system
        #expect(sim.step(80).led == .system)
        var noLED = Sim(caps: noAdapter)
        noLED.config.led = .limitState
        #expect(noLED.step(80).led == .system)
    }

    @Test func pollsFasterNearThresholds() {
        var sim = Sim()
        #expect(sim.step(50, charging: true).nextCheck == ChargeController.relaxed)
        #expect(sim.step(79, charging: true).nextCheck == ChargeController.near)
        sim.config.heatProtection = true
        #expect(sim.step(50, charging: true, temp: 34.2).nextCheck == ChargeController.near)
    }

    @Test func configSanitizingClampsEverything() {
        var c = ChargeConfig()
        c.upper = 30
        c.lower = 10
        c.maxTemperature = 99
        let s = c.sanitized()
        #expect(s.upper == 50)
        #expect(s.lower == 30)
        #expect(s.maxTemperature == 45)
        c.upper = 120
        c.lower = 120
        #expect(c.sanitized().upper == 100)
        #expect(c.sanitized().lower == 100)
    }
}

// MARK: - SMC whitelist and formats

@Suite struct ChargeKeyTests {
    @Test func onlyWhitelistedKeysCanBeNamed() {
        for key in ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "ACLC", "BCLM"] { #expect(ChargeKey(key: key) != nil) }
        for key in ["TB0T", "CHLT", "BUIC", "CHWA", "XXXX", "chte", "", "CHTE ", "F0Md"] { #expect(ChargeKey(key: key) == nil) }
    }

    @Test func encodesEveryKnownValue() {
        #expect(WhitelistedWrite.charging(.inhibit, key: .chte)?.bytes == [0x01, 0x00, 0x00, 0x00])
        #expect(WhitelistedWrite.charging(.allow, key: .chte)?.bytes == [0x00, 0x00, 0x00, 0x00])
        for key in [ChargeKey.ch0b, .ch0c] {
            #expect(WhitelistedWrite.charging(.inhibit, key: key)?.bytes == [0x02])
            #expect(WhitelistedWrite.charging(.allow, key: key)?.bytes == [0x00])
        }
        #expect(WhitelistedWrite.adapter(.disabled, key: .chie)?.bytes == [0x08])
        #expect(WhitelistedWrite.adapter(.enabled, key: .chie)?.bytes == [0x00])
        #expect(WhitelistedWrite.adapter(.disabled, key: .ch0i)?.bytes == [0x01])
        #expect(WhitelistedWrite.adapter(.enabled, key: .ch0i)?.bytes == [0x00])
        #expect(WhitelistedWrite.led(.system).bytes == [0x00])
        #expect(WhitelistedWrite.led(.off).bytes == [0x01])
        #expect(WhitelistedWrite.led(.green).bytes == [0x03])
        #expect(WhitelistedWrite.led(.orange).bytes == [0x04])
        #expect(WhitelistedWrite.firmwareLimit(80)?.bytes == [0x50])
        #expect(WhitelistedWrite.firmwareLimit(100)?.bytes == [0x64])
        #expect(WhitelistedWrite.led(.green).key == .aclc)
    }

    @Test func refusesValuesOutsideTheTable() {
        #expect(WhitelistedWrite.firmwareLimit(49) == nil)
        #expect(WhitelistedWrite.firmwareLimit(101) == nil)
        #expect(WhitelistedWrite.firmwareLimit(0) == nil)
        // A charging value can't go to an adapter key and vice versa.
        for key in [ChargeKey.chie, .ch0i, .aclc, .bclm] { #expect(WhitelistedWrite.charging(.inhibit, key: key) == nil) }
        for key in [ChargeKey.chte, .ch0b, .ch0c, .aclc, .bclm] { #expect(WhitelistedWrite.adapter(.disabled, key: key) == nil) }
    }

    @Test func decodesWhatItWrites() {
        for key in [ChargeKey.chte, .ch0b, .ch0c] {
            for c in [ChargingCommand.allow, .inhibit] {
                #expect(ChargeKeyValue.charging(WhitelistedWrite.charging(c, key: key)!.bytes, key: key) == c)
            }
        }
        for key in [ChargeKey.chie, .ch0i] {
            for c in [AdapterCommand.enabled, .disabled] {
                #expect(ChargeKeyValue.adapter(WhitelistedWrite.adapter(c, key: key)!.bytes, key: key) == c)
            }
        }
        for color in [LEDColor.system, .off, .green, .orange] { #expect(ChargeKeyValue.led(WhitelistedWrite.led(color).bytes) == color) }
        #expect(ChargeKeyValue.firmwareLimit([0x50]) == 80)
        // Unknown values read back as unknown.
        #expect(ChargeKeyValue.charging([0x01], key: .ch0b) == nil)
        #expect(ChargeKeyValue.charging([0x02, 0x00, 0x00, 0x00], key: .chte) == nil)
        #expect(ChargeKeyValue.adapter([0x02], key: .chie) == nil)
        #expect(ChargeKeyValue.led([0x07]) == nil)
        #expect(ChargeKeyValue.firmwareLimit([0x05]) == nil)
    }

    @Test func acceptsOnlyTheKnownFormat() {
        #expect(ChargeKey.chte.accepts(SMCKeyInfo(size: 4, type: "ui32")))
        #expect(!ChargeKey.chte.accepts(SMCKeyInfo(size: 1, type: "ui8 ")))
        #expect(!ChargeKey.chte.accepts(SMCKeyInfo(size: 4, type: "flt ")))
        #expect(ChargeKey.chie.accepts(SMCKeyInfo(size: 1, type: "hex_")))
        #expect(ChargeKey.aclc.accepts(SMCKeyInfo(size: 1, type: "ui8 ")))
        #expect(!ChargeKey.ch0b.accepts(SMCKeyInfo(size: 2, type: "hex_")))
        #expect(!ChargeKey.bclm.accepts(SMCKeyInfo(size: 1, type: "hex_")))
    }

    @Test func packsTheParameterBlockAtFixedOffsets() {
        let key = FourCC("CHTE")!
        #expect(key.rawValue == 0x4348_5445)
        #expect(key.description == "CHTE")
        #expect(FourCC("CHT") == nil)
        #expect(FourCC("CHTÉ") == nil)
        let raw = SMCParam(key: key.rawValue, command: SMCParam.readKey, dataSize: 4).encoded()
        #expect(raw.count == 80)
        #expect(Array(raw[0..<4]) == [0x45, 0x54, 0x48, 0x43])
        #expect(Array(raw[28..<32]) == [4, 0, 0, 0])
        #expect(raw[42] == 5)
        var reply = raw
        reply[32...35] = [0x32, 0x33, 0x69, 0x75] // "ui32", host order
        reply[40] = 0
        reply[48...51] = [1, 2, 3, 4]
        let decoded = SMCParam(decoding: reply)
        #expect(decoded.info == SMCKeyInfo(size: 4, type: "ui32"))
        #expect(Array(decoded.bytes.prefix(4)) == [1, 2, 3, 4])
    }

    @Test func decodesTemperatures() throws {
        // TB0T as read on a MacBook Pro (M5 Max): flt, little-endian.
        let flt = try #require(SMCTemperature.decode([0x60, 0x66, 0xFE, 0x41], type: "flt "))
        #expect(abs(flt - 31.8) < 0.01)
        #expect(SMCTemperature.decode([0x1F, 0x80], type: "sp78") == 31.5)
        #expect(SMCTemperature.decode([0x00, 0x00, 0xC8, 0x42], type: "flt ") == 100)
        #expect(SMCTemperature.decode([0x00, 0x00, 0x48, 0x43], type: "flt ") == nil) // 200 °C: implausible
        #expect(SMCTemperature.decode([1], type: "ui8 ") == nil)
    }
}

// MARK: - Hardware detection

@Suite struct ChargeHardwareTests {
    private func detect(_ keys: [ChargeKey: SMCKeyInfo], battery: Bool = true) -> ChargeHardware {
        ChargeHardware.detect(smcAvailable: true, batteryPresent: battery) { keys[$0] }
    }

    private let u8 = SMCKeyInfo(size: 1, type: "ui8 ")
    private let hex = SMCKeyInfo(size: 1, type: "hex_")
    private let u32 = SMCKeyInfo(size: 4, type: "ui32")

    @Test func newerFirmware() {
        let hw = detect([.chte: u32, .chie: hex, .aclc: u8])
        #expect(hw.chargingSwitch == .chte)
        #expect(hw.adapterSwitch == .chie)
        #expect(hw.led)
        #expect(hw.isSupported)
        #expect(hw.keyNames == ["CHTE", "CHIE", "ACLC"])
        #expect(hw.capabilities == ControlCapabilities(chargingSwitch: true, adapterSwitch: true, led: true))
    }

    @Test func olderFirmware() {
        #expect(detect([.ch0b: hex, .ch0c: hex, .ch0i: u8]).chargingSwitch == .ch0bc)
        #expect(detect([.ch0b: hex, .ch0c: hex, .ch0i: u8]).adapterSwitch == .ch0i)
        #expect(detect([.ch0b: hex]).chargingSwitch == .ch0b)
        // CHTE wins over CH0B when both exist.
        #expect(detect([.chte: u32, .ch0b: hex]).chargingSwitch == .chte)
    }

    @Test func intelFirmwareLimit() {
        let hw = detect([.bclm: u8, .ch0i: u8])
        #expect(hw.chargingSwitch == .bclm)
        #expect(hw.capabilities.firmwareLimit)
        #expect(!hw.capabilities.chargingSwitch)
        #expect(hw.capabilities.adapterSwitch)
    }

    /// What a MacBook Pro (Mac17,6, M5 Max, macOS 26) reports: an adapter switch and the LED, but none
    /// of the known charging switches.
    @Test func adapterSwitchAloneIsNotEnough() {
        let hw = detect([.chie: hex, .aclc: u8])
        #expect(hw.chargingSwitch == nil)
        #expect(hw.adapterSwitch == .chie)
        #expect(hw.unsupported == .noKnownKeys)
        #expect(hw.capabilities == .none)
        #expect(hw.writes(for: .normal(.paused), since: nil).isEmpty)
        #expect(hw.restoreWrites(resetLED: true).isEmpty)
    }

    @Test func unknownFormatsAreNeverUsed() {
        let hw = detect([.chte: SMCKeyInfo(size: 2, type: "ui16"), .chie: SMCKeyInfo(size: 4, type: "ui32")])
        #expect(hw.chargingSwitch == nil)
        #expect(hw.adapterSwitch == nil)
        #expect(hw.unsupported == .unexpectedFormat(["CHTE (ui16, 2 bytes)", "CHIE (ui32, 4 bytes)"]))
    }

    @Test func noBatteryOrSMC() {
        #expect(detect([.chte: u32], battery: false).unsupported == .noBattery)
        let noSMC = ChargeHardware.detect(smcAvailable: false, batteryPresent: true) { _ in u32 }
        #expect(noSMC.unsupported == .noSMC)
    }

    @Test func writesOnlyWhatChanged() {
        let hw = detect([.chte: u32, .chie: hex, .aclc: u8])
        let hold = ChargeDecision(charging: .inhibit, adapter: .enabled, led: .system, state: .holding, nextCheck: 30)
        // Unknown previous state: every switch, but the LED is left alone while it follows macOS.
        #expect(hw.writes(for: hold, since: nil).map(\.description) == ["CHIE = 00", "CHTE = 01000000"])
        #expect(hw.writes(for: hold, since: hold).isEmpty)
        let discharge = ChargeDecision(charging: .inhibit, adapter: .disabled, led: .orange, state: .discharging, nextCheck: 10)
        #expect(hw.writes(for: discharge, since: hold).map(\.description) == ["CHIE = 08", "ACLC = 04"])
        // Back on the adapter before charging is allowed again.
        let charge = ChargeDecision(charging: .allow, adapter: .enabled, led: .orange, state: .chargingToLimit, nextCheck: 30)
        #expect(hw.writes(for: charge, since: discharge).map(\.description) == ["CHIE = 00", "CHTE = 00000000"])
    }

    @Test func olderFirmwareWritesBothSwitches() {
        let hw = detect([.ch0b: hex, .ch0c: hex])
        let hold = ChargeDecision(charging: .inhibit, adapter: .enabled, led: .system, state: .holding, nextCheck: 30)
        #expect(hw.writes(for: hold, since: .normal(.paused)).map(\.description) == ["CH0B = 02", "CH0C = 02"])
        #expect(hw.restoreWrites(resetLED: false).map(\.description) == ["CH0B = 00", "CH0C = 00"])
    }

    @Test func restoresNormalCharging() {
        let hw = detect([.chte: u32, .chie: hex, .aclc: u8])
        #expect(hw.restoreWrites(resetLED: false).map(\.description) == ["CHIE = 00", "CHTE = 00000000"])
        #expect(hw.restoreWrites(resetLED: true).map(\.description) == ["CHIE = 00", "CHTE = 00000000", "ACLC = 00"])
        let intel = detect([.bclm: u8])
        #expect(intel.restoreWrites(resetLED: false).map(\.description) == ["BCLM = 64"])
        let limited = ChargeDecision(charging: .allow, adapter: .enabled, firmwareLimit: 80, led: .system, state: .holding, nextCheck: 30)
        #expect(intel.writes(for: limited, since: .normal(.paused)).map(\.description) == ["BCLM = 50"])
    }
}

// MARK: - Helper protocol

@Suite struct HelperProtocolTests {
    private func decode(_ json: String) throws -> HelperRequest { try HelperRequest.decode(Data(json.utf8)) }

    @Test func roundTripsEveryRequest() throws {
        let all: [HelperRequest] = [.status, .setLimit(lower: 75, upper: 80), .setDischarge(true), .setHeat(enabled: true, maxCelsius: 36),
                                    .setLED(.limitState), .pause, .resume, .topUp(true), .calibrate(false), .uninstall]
        for request in all {
            let line = request.encoded()
            #expect(line.last == UInt8(ascii: "\n"))
            #expect(try HelperRequest.decode(line) == request)
        }
        #expect(String(decoding: HelperRequest.setLimit(lower: 75, upper: 80).encoded(), as: UTF8.self)
                == "{\"cmd\":\"setLimit\",\"lower\":75,\"upper\":80}\n")
    }

    @Test func rejectsOutOfRangeValues() {
        #expect(throws: HelperProtocolError.outOfRange("upper")) { try decode(#"{"cmd":"setLimit","lower":45,"upper":49}"#) }
        #expect(throws: HelperProtocolError.outOfRange("upper")) { try decode(#"{"cmd":"setLimit","lower":90,"upper":101}"#) }
        #expect(throws: HelperProtocolError.outOfRange("lower")) { try decode(#"{"cmd":"setLimit","lower":81,"upper":80}"#) }
        #expect(throws: HelperProtocolError.outOfRange("lower")) { try decode(#"{"cmd":"setLimit","lower":59,"upper":80}"#) }
        #expect(throws: HelperProtocolError.outOfRange("max")) { try decode(#"{"cmd":"setHeat","on":true,"max":29}"#) }
        #expect(throws: HelperProtocolError.outOfRange("max")) { try decode(#"{"cmd":"setHeat","on":false,"max":46}"#) }
        #expect(throws: HelperProtocolError.outOfRange("mode")) { try decode(#"{"cmd":"setLED","mode":"rainbow"}"#) }
        #expect((try? decode(#"{"cmd":"setLimit","lower":60,"upper":80}"#)) == .setLimit(lower: 60, upper: 80))
        #expect((try? decode(#"{"cmd":"setLimit","lower":100,"upper":100}"#)) == .setLimit(lower: 100, upper: 100))
    }

    @Test func rejectsMalformedRequests() {
        #expect(throws: HelperProtocolError.missingField("upper")) { try decode(#"{"cmd":"setLimit","lower":75}"#) }
        #expect(throws: HelperProtocolError.missingField("on")) { try decode(#"{"cmd":"topUp"}"#) }
        #expect(throws: HelperProtocolError.missingField("mode")) { try decode(#"{"cmd":"setLED"}"#) }
        #expect(throws: HelperProtocolError.unknownCommand("writeKey")) { try decode(#"{"cmd":"writeKey","key":"CHTE"}"#) }
        #expect(throws: HelperProtocolError.malformed) { try decode(#"{"cmd":"setLimit","lower":75,"upper":80.5}"#) }
        #expect(throws: HelperProtocolError.malformed) { try decode(#"{"cmd":"setLimit","lower":"75","upper":80}"#) }
        #expect(throws: HelperProtocolError.malformed) { try decode("not json") }
        #expect(throws: HelperProtocolError.malformed) { try decode(#"{"upper":80}"#) }
        let long = "{\"cmd\":\"status\",\"pad\":\"" + String(repeating: "x", count: HelperProtocol.maxLineLength) + "\"}"
        #expect(throws: HelperProtocolError.tooLong) { try decode(long) }
    }

    @Test func roundTripsStatus() throws {
        var config = ChargeConfig()
        config.calibration = .dischargeToTarget
        config.lastCalibrated = Date(timeIntervalSince1970: 1_790_000_000)
        let status = HelperStatus(config: config, state: .calibrating, charging: .inhibit, adapter: .disabled, percent: 42,
                                  adapterConnected: true,
                                  hardware: ChargeHardware(chargingSwitch: .chte, adapterSwitch: .chie, led: true),
                                  lastError: "CHTE: SMC returned 0x84", updated: Date(timeIntervalSince1970: 1_800_000_000))
        let response = HelperResponse(ok: true, status: status)
        #expect(try HelperResponse.decode(response.encoded()) == response)
        #expect(try HelperResponse.decode(HelperResponse.failure("nope").encoded()) == HelperResponse(ok: false, error: "nope"))
    }

    @Test func versionHandshake() {
        func status(_ version: Int) -> HelperStatus {
            HelperStatus(version: version, config: ChargeConfig(), state: .holding, charging: .inhibit, adapter: .enabled,
                         percent: 80, adapterConnected: true, hardware: ChargeHardware(chargingSwitch: .chte, adapterSwitch: nil, led: false),
                         updated: t0)
        }
        #expect(HelperState.classify(status(HelperProtocol.version)) == .running(status(HelperProtocol.version)))
        #expect(HelperState.classify(status(HelperProtocol.version - 1)) == .outdated(status(HelperProtocol.version - 1)))
        #expect(HelperState.classify(status(HelperProtocol.version + 1)) == .outdated(status(HelperProtocol.version + 1)))
    }

    /// The real socket plumbing, in a temporary directory as the current user.
    @MainActor @Test func talksOverAUnixSocket() async throws {
        let path = "/tmp/mactoys-cl-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        var seen: [HelperRequest] = []
        let server = HelperSocketServer(path: path, ownerUID: getuid()) { line in
            guard let request = try? HelperRequest.decode(line) else { return HelperResponse.failure("bad").encoded() }
            seen.append(request)
            return HelperResponse(ok: request != .uninstall, error: request == .uninstall ? "no" : nil).encoded()
        }
        try server.start()
        defer { server.stop() }
        let info = try FileManager.default.attributesOfItem(atPath: path)
        #expect((info[.posixPermissions] as? Int) == 0o600)
        let ok = try await HelperClient.send(.setLimit(lower: 70, upper: 75), path: path)
        #expect(ok.ok)
        let refused = try await HelperClient.send(.uninstall, path: path)
        #expect(refused == HelperResponse(ok: false, error: "no"))
        #expect(seen == [.setLimit(lower: 70, upper: 75), .uninstall])
        server.stop()
        await #expect(throws: HelperClientError.notRunning) { try await HelperClient.send(.status, path: path) }
    }
}

// MARK: - Install

@Suite struct HelperInstallTests {
    let plan = HelperInstallPlan(source: "/Applications/MacToys.app/Contents/Helpers/mactoys", ownerUID: 501)

    @Test func launchDaemonContents() throws {
        let data = Data(plan.launchDaemonPlist.utf8)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "com.w33d.mactoys.chargelimit")
        #expect(plist["ProgramArguments"] as? [String] == ["/Library/PrivilegedHelperTools/com.w33d.mactoys.chargelimit",
                                                           "charge-helper", "--owner-uid", "501"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false])
        #expect(plist["AssociatedBundleIdentifiers"] as? [String] == ["com.w33d.mactoys"])
    }

    @Test func installScriptCopiesRootOwnedAndStartsTheDaemon() {
        let script = plan.installScript
        let lines = script.components(separatedBy: "\n")
        #expect(lines.first == "set -e")
        #expect(lines.contains("/bin/launchctl bootout system/com.w33d.mactoys.chargelimit >/dev/null 2>&1 || true"))
        #expect(lines.contains("/usr/bin/install -o root -g wheel -m 0755 '/Applications/MacToys.app/Contents/Helpers/mactoys' '/Library/PrivilegedHelperTools/com.w33d.mactoys.chargelimit'"))
        #expect(lines.contains("/usr/sbin/chown root:wheel '/Library/LaunchDaemons/com.w33d.mactoys.chargelimit.plist'"))
        #expect(lines.contains("/bin/chmod 0644 '/Library/LaunchDaemons/com.w33d.mactoys.chargelimit.plist'"))
        #expect(lines.contains("/usr/sbin/chown root:wheel '/Library/Application Support/MacToys/ChargeLimit'"))
        #expect(lines.last == "/bin/launchctl bootstrap system '/Library/LaunchDaemons/com.w33d.mactoys.chargelimit.plist'")
        // The plist is written between heredoc markers, ahead of its ownership change.
        let start = lines.firstIndex { $0.hasSuffix("<<'MACTOYS_PLIST'") }
        let end = lines.firstIndex(of: "MACTOYS_PLIST")
        #expect(start != nil && end != nil && start! < end!)
        #expect(script.contains("<string>--owner-uid</string>"))
    }

    @Test func quotesUnusualSourcePaths() {
        let odd = HelperInstallPlan(source: "/Users/o'neil/My Apps/MacToys.app/Contents/Helpers/mactoys", ownerUID: 502)
        #expect(odd.installScript.contains("/usr/bin/install -o root -g wheel -m 0755 '/Users/o'\\''neil/My Apps/MacToys.app/Contents/Helpers/mactoys' "))
    }

    @Test func uninstallRemovesEveryFileAndRestores() {
        let script = HelperInstallPlan.uninstallScript
        #expect(script.contains("/bin/launchctl bootout system/com.w33d.mactoys.chargelimit"))
        #expect(script.contains("'/Library/PrivilegedHelperTools/com.w33d.mactoys.chargelimit' charge-helper --restore"))
        #expect(script.contains("/bin/rm -f '/Library/LaunchDaemons/com.w33d.mactoys.chargelimit.plist' '/Library/PrivilegedHelperTools/com.w33d.mactoys.chargelimit'"))
        #expect(script.contains("/bin/rm -rf '/Library/Application Support/MacToys/ChargeLimit'"))
        // The socket lives in the state directory, so it goes with it.
        #expect(HelperPaths.socket.hasPrefix(HelperPaths.stateDirectory + "/"))
        #expect(HelperPaths.socket.utf8.count < 104)
    }

    @Test func parsesHelperArguments() {
        #expect(HelperArguments.parse(["--owner-uid", "501"]) == .run(ownerUID: 501))
        #expect(HelperArguments.parse(["--restore"]) == .restore)
        #expect(HelperArguments.parse([]) == nil)
        #expect(HelperArguments.parse(["--owner-uid", "0"]) == nil)
        #expect(HelperArguments.parse(["--owner-uid", "-1"]) == nil)
        #expect(HelperArguments.parse(["--owner-uid", "501", "--restore"]) == nil)
        #expect(HelperArguments.parse(["--owner-uid"]) == nil)
    }

    @Test func refusesUnsafeExecutables() {
        let safe: [String: HelperSelfCheck.FileInfo] = [
            HelperPaths.helper: .init(owner: 0, mode: 0o755, isDirectory: false),
            "/Library/PrivilegedHelperTools": .init(owner: 0, mode: 0o755, isDirectory: true),
            "/Library": .init(owner: 0, mode: 0o755, isDirectory: true),
            "/": .init(owner: 0, mode: 0o755, isDirectory: true),
        ]
        #expect(HelperSelfCheck.problem(executable: HelperPaths.helper) { safe[$0] } == nil)
        #expect(HelperSelfCheck.problem(executable: "/Users/me/.build/debug/mactoys-cli") { safe[$0] } != nil)
        var userOwned = safe
        userOwned[HelperPaths.helper] = .init(owner: 501, mode: 0o755, isDirectory: false)
        #expect(HelperSelfCheck.problem(executable: HelperPaths.helper) { userOwned[$0] } != nil)
        var groupWritable = safe
        groupWritable[HelperPaths.helper] = .init(owner: 0, mode: 0o775, isDirectory: false)
        #expect(HelperSelfCheck.problem(executable: HelperPaths.helper) { groupWritable[$0] } != nil)
        var openDir = safe
        openDir["/Library/PrivilegedHelperTools"] = .init(owner: 0, mode: 0o777, isDirectory: true)
        #expect(HelperSelfCheck.problem(executable: HelperPaths.helper) { openDir[$0] } != nil)
        var stickyDir = safe
        stickyDir["/Library/PrivilegedHelperTools"] = .init(owner: 0, mode: 0o1777, isDirectory: true)
        #expect(HelperSelfCheck.problem(executable: HelperPaths.helper) { stickyDir[$0] } == nil)
        var link = safe
        link[HelperPaths.helper] = .init(owner: 0, mode: 0o755, isDirectory: false, isSymlink: true)
        #expect(HelperSelfCheck.problem(executable: HelperPaths.helper) { link[$0] } != nil)
    }
}

// MARK: - App side

@Suite struct ChargeLimitAppTests {
    @Test func settingsProduceTheRequestsTheHelperNeeds() {
        var s = ChargeLimitSettings()
        s.upperLimit = 70
        s.sailingRange = 8
        s.dischargeToLimit = true
        s.heatProtection = true
        s.maxTemperature = 36
        s.ledMode = .limitState
        let caps = ControlCapabilities(chargingSwitch: true, adapterSwitch: true, led: true)
        #expect(s.lowerLimit == 62)
        #expect(s.requests(toMatch: ChargeConfig(), capabilities: caps) == [
            .setLimit(lower: 62, upper: 70), .setDischarge(true), .setHeat(enabled: true, maxCelsius: 36), .setLED(.limitState)])
        var matched = ChargeConfig()
        matched.upper = 70
        matched.lower = 62
        matched.dischargeToLimit = true
        matched.heatProtection = true
        matched.maxTemperature = 36
        matched.led = .limitState
        #expect(s.requests(toMatch: matched, capabilities: caps).isEmpty)
        // Features the hardware lacks are never requested.
        let bare = ControlCapabilities(chargingSwitch: false, firmwareLimit: true, adapterSwitch: false, led: false)
        #expect(s.requests(toMatch: ChargeConfig(), capabilities: bare) == [.setLimit(lower: 70, upper: 70)])
    }

    @Test func lowerLimitStaysInRange() {
        var s = ChargeLimitSettings()
        s.upperLimit = 50
        s.sailingRange = 40
        #expect(s.lowerLimit == 30)
        s.upperLimit = 10
        s.sailingRange = -5
        #expect(s.lowerLimit == 50)
    }

    @Test func systemLimitAvailability() {
        let v264 = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        let v263 = OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 1)
        let v27 = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        #expect(SystemChargeLimit.detect(os: v264, appleSilicon: true, hasBattery: true, policies: nil).available)
        #expect(SystemChargeLimit.detect(os: v27, appleSilicon: true, hasBattery: true, policies: nil).available)
        #expect(!SystemChargeLimit.detect(os: v263, appleSilicon: true, hasBattery: true, policies: nil).available)
        #expect(!SystemChargeLimit.detect(os: v264, appleSilicon: false, hasBattery: true, policies: nil).available)
        #expect(!SystemChargeLimit.detect(os: v264, appleSilicon: true, hasBattery: false, policies: nil).available)
    }

    @Test func readsTheManualLimitFromPowerdPreferences() throws {
        func archive(_ records: [ChargePolicyRecord]) throws -> Data {
            let archiver = NSKeyedArchiver(requiringSecureCoding: true)
            archiver.setClassName(ChargePolicyRecord.archivedClassName, for: ChargePolicyRecord.self)
            archiver.encode(NSMutableArray(array: records), forKey: NSKeyedArchiveRootObjectKey)
            archiver.finishEncoding()
            return archiver.encodedData
        }
        let manual = try archive([ChargePolicyRecord(reason: "manualChargeLimit", socLimit: 80)])
        #expect(SystemChargeLimit.manualLimit(fromArchive: manual) == 80)
        let other = try archive([ChargePolicyRecord(reason: "optimizedCharging", socLimit: 80)])
        #expect(SystemChargeLimit.manualLimit(fromArchive: other) == nil)
        #expect(SystemChargeLimit.manualLimit(fromArchive: Data("junk".utf8)) == nil)
        let prefs = try PropertyListSerialization.data(fromPropertyList: ["policies": manual, "bootSessionUUID": "X"],
                                                       format: .binary, options: 0)
        #expect(SystemChargeLimit.manualLimit(fromPreferences: prefs) == 80)
        #expect(SystemChargeLimit.detect(os: OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0),
                                         appleSilicon: true, hasBattery: true, policies: prefs).activeLimit == 80)
    }

    @Test func parsesAppleSiliconBatteryRegistry() throws {
        // Values as read from a MacBook Pro (Mac17,6).
        let registry: [String: Any] = [
            "CurrentCapacity": 80, "MaxCapacity": 100, "IsCharging": false, "ExternalConnected": true, "FullyCharged": false,
            "CycleCount": 47, "DesignCycleCount9C": 1000, "Voltage": 12351, "Amperage": 0, "InstantAmperage": 0,
            "AvgTimeToFull": 65535, "AvgTimeToEmpty": 65535,
            "BatteryData": ["DesignCapacity": 8579, "NominalChargeCapacity": 8428, "FullChargeCapacity": 8184],
            "AdapterDetails": ["Name": "140W USB-C Power Adapter", "Watts": 140],
        ]
        let b = try #require(BatterySnapshot(registry: registry))
        #expect(b.percent == 80)
        #expect(b.adapterConnected)
        #expect(!b.isCharging)
        #expect(b.cycleCount == 47)
        #expect(b.designCycleCount == 1000)
        #expect(b.healthPercent == 98)
        #expect(b.adapterName == "140W USB-C Power Adapter")
        #expect(b.adapterWatts == 140)
        #expect(b.temperature == nil)
        #expect(b.minutesToFull == nil)
        #expect(BatterySnapshot(registry: registry, powerSourcePercent: 79)?.percent == 79)
    }

    @Test func parsesIntelBatteryRegistry() throws {
        let registry: [String: Any] = [
            "CurrentCapacity": 3000, "MaxCapacity": 4000, "DesignCapacity": 5000, "IsCharging": false, "ExternalConnected": false,
            "Temperature": 3050, "Voltage": 11000, "Amperage": NSNumber(value: UInt64.max - 1233), "CycleCount": 410,
            "AvgTimeToEmpty": 185,
        ]
        let b = try #require(BatterySnapshot(registry: registry))
        #expect(b.percent == 75)
        #expect(b.temperature == 30.5)
        #expect(b.amperage == -1.234)
        #expect(b.fullChargeCapacity == 4000)
        #expect(b.healthPercent == 80)
        #expect(b.minutesToEmpty == 185)
        #expect((b.batteryWatts ?? 0) < 0)
        #expect(BatterySnapshot(registry: [:]) == nil)
    }

    @Test func formatsPercentagesForTheLocale() {
        #expect((0.8).formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))) == "80%")
        #expect((0.8).formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "fr_FR"))).hasPrefix("80"))
    }
}
