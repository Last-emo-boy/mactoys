import Foundation
import Testing
@testable import PowerDisplay

@Suite struct PowerDisplayTests {
    // MARK: Packets

    @Test func getVCPRequestMatchesDdcutil() {
        // ddcutil traces brightness reads as `6e 51 82 01 10 ac`.
        #expect(DDCPacket.getVCP(0x10) == [0x82, 0x01, 0x10, 0xAC])
        #expect(DDCPacket.getVCP(0x10, seed: DDCPacket.legacyReadSeed) == [0x82, 0x01, 0x10, 0x6E ^ 0x82 ^ 0x01 ^ 0x10])
    }

    @Test func setVCPPacket() {
        #expect(DDCPacket.setVCP(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        let p = DDCPacket.setVCP(0x60, value: 0x1234)
        #expect(Array(p[0...4]) == [0x84, 0x03, 0x60, 0x12, 0x34])
        #expect(p[5] == DDCPacket.checksum(p[0...4], seed: 0x6E ^ 0x51))
    }

    @Test func capabilitiesRequestPacket() {
        let p = DDCPacket.capabilitiesRequest(offset: 0x0120)
        #expect(Array(p[0...3]) == [0x83, 0xF3, 0x01, 0x20])
        #expect(p[4] == 0x6E ^ 0x51 ^ 0x83 ^ 0xF3 ^ 0x01 ^ 0x20)
    }

    @Test func parsesVCPReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        let r = DDCPacket.parseVCPReply(reply, code: 0x10)
        #expect(r == VCPReply(code: 0x10, supported: true, isMomentary: false, maximum: 100, current: 50))
    }

    @Test func rejectsBadVCPReplies() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        reply[10] ^= 0x01
        #expect(DDCPacket.parseVCPReply(reply, code: 0x10) == nil, "bad checksum")
        #expect(DDCPacket.parseVCPReply([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2], code: 0x12) == nil,
                "wrong code")
        #expect(DDCPacket.parseVCPReply([0, 0, 0], code: 0x10) == nil, "short")
        #expect(DDCPacket.parseVCPReply([UInt8](repeating: 0, count: 11), code: 0x10) == nil, "all zero")
    }

    @Test func parsesUnsupportedReply() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x01, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00]
        reply.append(DDCPacket.checksum(reply, seed: 0x50))
        let r = DDCPacket.parseVCPReply(reply, code: 0x62)
        #expect(r?.supported == false)
    }

    @Test func parsesCapabilitiesFragments() {
        let text = Array("(prot(monitor)".utf8)
        var frag: [UInt8] = [0x6E, 0x80 | UInt8(3 + text.count), 0xE3, 0x00, 0x20] + text
        frag.append(DDCPacket.checksum(frag, seed: 0x50))
        #expect(DDCPacket.parseCapabilitiesReply(frag + [0, 0], offset: 0x20) == text)
        #expect(DDCPacket.parseCapabilitiesReply(frag, offset: 0x00) == nil, "offset mismatch")
        var end: [UInt8] = [0x6E, 0x83, 0xE3, 0x00, 0x40]
        end.append(DDCPacket.checksum(end, seed: 0x50))
        #expect(DDCPacket.parseCapabilitiesReply(end, offset: 0x40) == [])
    }

    // MARK: Capability strings

    @Test func parsesDellCapabilities() {
        let raw = "(prot(monitor)type(LCD)model(U2720Q)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(01 04 05 06 08 09 0B 0C) 16 18 1A 52 60(1B 0F 11 12) AA(01 02 04) AC AE B2 B6 C6 C8 C9 D6(01 04 05) DC(00 03 05) DF E0 E1 E2(00 1D 01 02 04 0E 12 14 23 24 27) F0(0C) F1 F2 FD)mswhql(1)asset_eep(40)mccs_ver(2.1))"
        let c = DDCCapabilities.parse(raw)
        #expect(c.type == "LCD")
        #expect(c.model == "U2720Q")
        #expect(c.mccsVersion == "2.1")
        #expect(c.commands == [0x01, 0x02, 0x03, 0x07, 0x0C, 0xE3, 0xF3])
        #expect(c.supports(0x10) && c.supports(0x12) && c.supports(0xFD))
        #expect(!c.supports(0x62))
        #expect(c.vcp[0x14] == [0x01, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0B, 0x0C])
        #expect(c.vcp[0x60] == [0x1B, 0x0F, 0x11, 0x12])
        #expect(c.vcp[0xD6] == [0x01, 0x04, 0x05])
        #expect(c.vcp[0x10] == [])
        #expect(c.codes.first == 0x02 && c.codes.last == 0xFD)
    }

    @Test func parsesSloppyCapabilities() {
        let c = DDCCapabilities.parse("prot(monitor)type(lcd)model(xyz)vcp(10 12 60(0f 11)62)mccs_ver(2.2)")
        #expect(c.model == "xyz")
        #expect(c.vcp[0x60] == [0x0F, 0x11])
        #expect(c.supports(0x62))
        #expect(c.mccsVersion == "2.2")

        let packed = DDCCapabilities.parse("(vcp(1012 14(0508)60(0F11)62))")
        #expect(packed.codes == [0x10, 0x12, 0x14, 0x60, 0x62])
        #expect(packed.vcp[0x14] == [0x05, 0x08])
        #expect(packed.vcp[0x60] == [0x0F, 0x11])

        let nested = DDCCapabilities.parse("(vcp(10 14(05 08 (0B)) 62))")
        #expect(nested.vcp[0x14] == [0x05, 0x08, 0x0B])
        #expect(nested.supports(0x62))

        let noisy = DDCCapabilities.parse("(prot(monitor)\u{0}vcp(10\n12)")   // NUL, newline, unbalanced
        #expect(noisy.supports(0x10) && noisy.supports(0x12))

        #expect(DDCCapabilities.parse("").codes.isEmpty)
        #expect(DDCCapabilities.parse("garbage").codes.isEmpty)
    }

    @Test func capabilitiesRoundTripThroughJSON() throws {
        let c = DDCCapabilities.parse("(vcp(10 14(05 08) 60(0F)))")
        let back = try JSONDecoder().decode(DDCCapabilities.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    // MARK: Scaling

    @Test func rescalesNonStandardRanges() {
        #expect(VCPScale.percent(raw: 50, maximum: 100) == 50)
        #expect(VCPScale.percent(raw: 32, maximum: 64) == 50)
        #expect(VCPScale.raw(percent: 50, maximum: 64) == 32)
        #expect(VCPScale.raw(percent: 100, maximum: 255) == 255)
        #expect(VCPScale.raw(percent: 140, maximum: 255) == 255)
        #expect(VCPScale.raw(percent: -5, maximum: 100) == 0)
        #expect(VCPScale.percent(raw: 40, maximum: 0) == 40, "a zero maximum is treated as 100")
        #expect(VCPScale.percent(raw: 300, maximum: 100) == 100)
    }

    // MARK: Profiles and names

    static func monitor(_ id: String, brightnessMax: UInt16 = 100, color: Bool = false) -> MonitorSnapshot {
        var readings: [DisplayFeature: FeatureReading] = [.brightness: FeatureReading(current: brightnessMax / 2, maximum: brightnessMax)]
        if color { readings[.colorTemperature] = FeatureReading(current: 5, maximum: 13) }
        return MonitorSnapshot(id: id, number: 1, name: id, displayID: 1, kind: .ddc, transport: "DDC/CI",
                               capabilities: nil, readings: readings, options: [:], rotation: 0)
    }

    @Test func profileWritesOnlySupportedValues() {
        let profile = DisplayProfileRecord(id: 3, name: "Movie", monitors: [
            "a": ProfileValues(brightness: 50, contrast: 70, volume: nil, colorPreset: 6),
            "gone": ProfileValues(brightness: 10),
        ])
        let writes = ProfilePlan.writes(profile, monitors: [Self.monitor("a", brightnessMax: 64, color: true), Self.monitor("b")])
        #expect(writes.count == 2)
        #expect(writes[0].0 == "a" && writes[0].1 == .brightness && writes[0].2 == 32)
        #expect(writes[1].0 == "a" && writes[1].1 == .colorTemperature && writes[1].2 == 6)
    }

    @Test func profileCaptureUsesPercent() {
        let captured = ProfilePlan.capture([Self.monitor("a", brightnessMax: 64, color: true)])
        #expect(captured["a"] == ProfileValues(brightness: 50, contrast: nil, volume: nil, colorPreset: 5))
    }

    @Test func profileIDsStayStable() {
        var s = PowerDisplaySettings()
        let a = s.addProfile(named: "A", monitors: [:])
        let b = s.addProfile(named: "B", monitors: [:])
        let c = s.addProfile(named: "C", monitors: [:])
        #expect(a == 1 && b == 2 && c == 3)
        s.moveProfile(id: c, by: -1)
        #expect(s.profiles.map(\.id) == [1, 3, 2])
        s.profiles.removeAll { $0.id == 2 }
        #expect(s.addProfile(named: "D", monitors: [:]) == 4, "deleted ids are never reused")
        s.moveProfile(id: 1, by: -1)
        #expect(s.profiles.first?.id == 1, "moving past the top is a no-op")
        #expect(s.suggestedProfileName() == "Profile 4")
    }

    @Test func customVCPNamesPreferMonitorScope() {
        var s = PowerDisplaySettings()
        #expect(s.valueName(.inputSource, 0x11, monitor: "m") == "HDMI 1")
        #expect(s.valueName(.inputSource, 0x7F, monitor: "m") == "0x7F")
        s.vcpNames = [VCPNameMapping(code: 0x60, value: 0x11, name: "Console", monitorID: nil),
                      VCPNameMapping(code: 0x60, value: 0x11, name: "PlayStation", monitorID: "m")]
        #expect(s.valueName(.inputSource, 0x11, monitor: "m") == "PlayStation")
        #expect(s.valueName(.inputSource, 0x11, monitor: "other") == "Console")
        #expect(s.valueName(.colorTemperature, 0x05, monitor: "m") == "6500 K")
    }

    @Test func prefsDefaultsHideRiskyControls() {
        let p = MonitorPrefs()
        #expect(p.shows(.brightness) && p.shows(.contrast) && p.shows(.volume))
        #expect(!p.shows(.inputSource) && !p.shows(.colorTemperature) && !p.shows(.powerState))
    }

    // MARK: Matching

    @Test func matchesServicesByEDID() {
        let lg = DisplayEngine.OnlineDisplay(id: 2, name: "LG UltraFine", isBuiltIn: false, vendor: 0x1E6D, model: 0x5B71,
                                             serial: 777, bounds: .zero)
        let dell = DisplayEngine.OnlineDisplay(id: 3, name: "DELL U2720Q", isBuiltIn: false, vendor: 0x10AC, model: 0xA0C4,
                                               serial: 0, bounds: .zero)
        let s1 = DisplayEngine.AVServiceInfo(service: "dell" as CFString, edidUUID: "10ACC4A0-0000-0000-1E1E-0104B53C2278",
                                             productName: "DELL U2720Q")
        let s2 = DisplayEngine.AVServiceInfo(service: "lg" as CFString, edidUUID: "1E6D715B-0000-0000-0B1F-0104B53C2278",
                                             serial: 777)
        #expect(DisplayEngine.matchScore(dell, s1) == 3)
        #expect(DisplayEngine.matchScore(lg, s2) == 4)
        #expect(DisplayEngine.matchScore(lg, s1) == 0)
        let m = DisplayEngine.match(displays: [lg, dell], services: [s1, s2])
        #expect((m[2]?.service as? String) == "lg")
        #expect((m[3]?.service as? String) == "dell")
    }

    @Test func lonePairMatchesWithoutEvidence() {
        let d = DisplayEngine.OnlineDisplay(id: 5, name: "", isBuiltIn: false, vendor: 0, model: 0, serial: 0, bounds: .zero)
        let s = DisplayEngine.AVServiceInfo(service: "x" as CFString)
        #expect(DisplayEngine.match(displays: [d], services: [s])[5] != nil)
        #expect(DisplayEngine.match(displays: [d, d], services: [s]).isEmpty)
    }

    // MARK: CLI

    @Test func cliOptions() throws {
        let set = try PowerDisplayCLI.Options.parse(["set", "-n", "1,2", "--brightness", "70"])
        #expect(set.command == "set")
        #expect(set.numbers == [1, 2])
        #expect(set.values.count == 1 && set.values[0].0 == .brightness && set.values[0].1 == "70")

        let up = try PowerDisplayCLI.Options.parse(["up", "--monitor-number=1", "--volume", "--step", "10", "--json"])
        #expect(up.values.first?.0 == .volume && up.values.first?.1 == "")
        #expect(up.step == 10 && up.json)

        let get = try PowerDisplayCLI.Options.parse(["get", "-i", "7789-23376-1234", "--setting", "input-source"])
        #expect(get.id == "7789-23376-1234" && get.setting == "input-source")

        let apply = try PowerDisplayCLI.Options.parse(["apply-profile", "3"])
        #expect(apply.positional == ["3"])

        #expect(throws: PowerDisplayCLI.Failure.self) { try PowerDisplayCLI.Options.parse(["set", "-n", "0"]) }
        #expect(throws: PowerDisplayCLI.Failure.self) { try PowerDisplayCLI.Options.parse(["set", "--bogus"]) }
        #expect(PowerDisplayCLI.parseValue("0x1B") == 0x1B)
        #expect(PowerDisplayCLI.parseValue("27") == 27)
    }

    @Test func featureCLINames() {
        for f in DisplayFeature.allCases { #expect(DisplayFeature(cliName: f.cliName) == f) }
    }
}
