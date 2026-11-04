import CoreGraphics
import Foundation
import MacToysCore
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

@Suite struct PowerDisplayModesTests {
    static func mode(_ w: Int, _ h: Int, scale: Int = 1, _ rate: Double = 60, flags: UInt32 = 0x3, id: Int32 = 0) -> DisplayModeInfo {
        DisplayModeInfo(width: w, height: h, pixelWidth: w * scale, pixelHeight: h * scale, refreshRate: rate, ioFlags: flags, modeID: id)
    }

    /// A 4K monitor: HiDPI looks-like modes, native 3840 × 2160 at several rates, a 4:3 legacy mode.
    static var fourK: [DisplayModeInfo] {
        var id: Int32 = 0
        func next() -> Int32 { id += 1; return id }
        return [
            mode(1920, 1080, scale: 2, 60, id: next()), mode(1920, 1080, scale: 2, 50, id: next()),
            mode(2560, 1440, scale: 2, 60, id: next()),
            mode(1920, 1080, 60, id: next()),
            mode(3840, 2160, 60, flags: 0x3 | DisplayModeInfo.nativeFlag | DisplayModeInfo.defaultFlag, id: next()),
            mode(3840, 2160, 30, flags: 0x3 | DisplayModeInfo.nativeFlag, id: next()),
            mode(3840, 2160, 59.94, flags: 0x3 | DisplayModeInfo.nativeFlag, id: next()),
            mode(1024, 768, 60, id: next()),
            mode(1366, 768, 60, id: next()),
            DisplayModeInfo(width: 800, height: 600, pixelWidth: 800, pixelHeight: 600, refreshRate: 60, ioFlags: 0, modeID: next(), isUsable: false),
        ]
    }

    @Test func hiDPIAndNativeDetection() {
        let hidpi = Self.mode(1728, 1117, scale: 2, 120, flags: 0x2000007)
        #expect(hidpi.isHiDPI && hidpi.isNative && hidpi.isDefault)
        let plain = Self.mode(1920, 1200, 60, flags: 0x3)
        #expect(!plain.isHiDPI && !plain.isNative && !plain.isDefault)
        #expect(hidpi.resolution.string == "1728x1117/3456x2234")
    }

    @Test func resolutionKeyRoundTrips() {
        let k = ResolutionKey(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880)
        #expect(ResolutionKey(string: k.string) == k)
        #expect(ResolutionKey(string: "2560x1440") == nil)
        #expect(ResolutionKey(string: "axb/1x1") == nil)
        #expect(ResolutionKey(string: "0x10/10x10") == nil)
        #expect(k.title == "2560 × 1440")
        #expect(k.isHiDPI)
    }

    @Test func aspectRatiosSnapToCommonNames() {
        #expect(AspectRatio.of(width: 1920, height: 1080).name == "16:9")
        #expect(AspectRatio.of(width: 1366, height: 768).name == "16:9")
        #expect(AspectRatio.of(width: 1360, height: 768).name == "16:9")
        #expect(AspectRatio.of(width: 2560, height: 1600).name == "16:10")
        #expect(AspectRatio.of(width: 3440, height: 1440).name == "21:9")
        #expect(AspectRatio.of(width: 2560, height: 1080).name == "21:9")
        #expect(AspectRatio.of(width: 5120, height: 1440).name == "32:9")
        #expect(AspectRatio.of(width: 1024, height: 768).name == "4:3")
        #expect(AspectRatio.of(width: 1280, height: 1024).name == "5:4")
        #expect(AspectRatio.of(width: 4096, height: 2160).name == "17:9")
        #expect(AspectRatio.of(width: 1080, height: 1920).name == "9:16")
        let notch = AspectRatio.of(width: 1728, height: 1117)
        #expect(notch.name == nil)
        #expect(notch.value == 1.55)
        #expect(notch.title(locale: Locale(identifier: "en_US")) == "1.55:1")
        #expect(notch.title(locale: Locale(identifier: "de_DE")) == "1,55:1")
        #expect(AspectRatio.of(width: 1496, height: 967) == notch, "notch-height modes group together")
    }

    @Test func catalogGroupsSortsAndFoldsRefreshRates() {
        let current = Self.fourK[2]   // 2560 × 1440 HiDPI
        let c = ModeCatalog(modes: Self.fourK, current: current)
        // 16:9 first (native and most entries), then 4:3; the unusable 800 × 600 is dropped.
        #expect(c.groups.map(\.aspect.name) == ["16:9", "4:3"])
        let sixteenNine = c.groups[0]
        #expect(sixteenNine.isNative)
        #expect(sixteenNine.entries.map(\.key.title) == ["3840 × 2160", "2560 × 1440", "1920 × 1080", "1920 × 1080", "1366 × 768"])
        #expect(sixteenNine.entries[2].isHiDPI && !sixteenNine.entries[3].isHiDPI, "HiDPI first for the same size")
        let native = sixteenNine.entries[0]
        #expect(native.isNative && native.isDefault)
        #expect(native.refreshRates == [60, 59.94, 30], "fastest first")
        #expect(c.currentEntry?.key == current.resolution)
        #expect(c.entries.filter(\.isCurrent).count == 1)
        #expect(c.refreshRates == [60])
        #expect(!c.entries.contains { $0.key.width == 800 })
    }

    @Test func duplicateRatesCollapse() {
        let modes = [Self.mode(1920, 1080, 60, id: 1), Self.mode(1920, 1080, 60.0001, id: 2), Self.mode(1920, 1080, 50, id: 3)]
        let c = ModeCatalog(modes: modes, current: nil)
        #expect(c.entries.first?.refreshRates.count == 2)
        #expect(c.entries.first?.modes.first?.modeID == 1)
    }

    @Test func hidesLowResolutionDuplicates() {
        let all = ModeCatalog(modes: Self.fourK, current: nil)
        #expect(all.entries.filter { $0.key.width == 1920 }.count == 2)
        let hidden = ModeCatalog(modes: Self.fourK, current: nil, hideLowResolutionDuplicates: true)
        #expect(hidden.entries.filter { $0.key.width == 1920 }.map(\.isHiDPI) == [true])
        #expect(hidden.entries.contains { $0.key.width == 3840 }, "native 1× has no HiDPI twin and stays")
        // The current mode is never hidden.
        let keep = ModeCatalog(modes: Self.fourK, current: Self.fourK[3], hideLowResolutionDuplicates: true)
        #expect(keep.entries.filter { $0.key.width == 1920 }.count == 2)
    }

    @Test func favoritesKeepTheirOrderAndSkipMissing() {
        let favs = ["3840x2160/3840x2160", "9999x9999/9999x9999", "1920x1080/3840x2160", "3840x2160/3840x2160"]
        let c = ModeCatalog(modes: Self.fourK, current: nil, favorites: favs)
        #expect(c.favorites.map(\.key.string) == ["3840x2160/3840x2160", "1920x1080/3840x2160"])
        #expect(c.entries.filter(\.isFavorite).count == 2)
    }

    @Test func modeForResolutionKeepsTheRefreshRate() {
        let current = Self.fourK[6]   // 3840 × 2160 @ 59.94
        let c = ModeCatalog(modes: Self.fourK, current: current)
        let hidpi1080 = ResolutionKey(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
        #expect(c.mode(for: hidpi1080)?.refreshRate == 60, "closest to 59.94")
        #expect(c.mode(for: hidpi1080, refresh: 50)?.refreshRate == 50)
        #expect(c.mode(refresh: 30)?.refreshRate == 30)
        #expect(c.mode(for: ResolutionKey(width: 1, height: 1, pixelWidth: 1, pixelHeight: 1)) == nil)
        let noCurrent = ModeCatalog(modes: Self.fourK, current: nil)
        #expect(noCurrent.mode(for: hidpi1080)?.refreshRate == 60, "fastest without a current mode")
    }

    @Test func modeRequestsParse() {
        #expect(ModeRequest.parse("2560x1440") == ModeRequest(width: 2560, height: 1440))
        #expect(ModeRequest.parse("1920X1080@59.94") == ModeRequest(width: 1920, height: 1080, refresh: 59.94))
        #expect(ModeRequest.parse("3840×2160@60Hz")?.refresh == 60)
        #expect(ModeRequest.parse(" 1280x800 ")?.width == 1280)
        for bad in ["", "2560", "x1440", "2560x", "2560x1440@", "2560x1440@fast", "0x100", "1x2x3", "1x1@60@60"] {
            #expect(ModeRequest.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func requestsMatchModes() {
        let c = ModeCatalog(modes: Self.fourK, current: Self.fourK[2])
        // 1920 × 1080 exists as HiDPI and 1×: the current kind (HiDPI) wins without a flag.
        #expect(c.match(ModeRequest(width: 1920, height: 1080))?.isHiDPI == true)
        #expect(c.match(ModeRequest(width: 1920, height: 1080, hiDPI: false))?.isHiDPI == false)
        #expect(c.match(ModeRequest(width: 1920, height: 1080, refresh: 50))?.refreshRate == 50)
        #expect(c.match(ModeRequest(width: 3840, height: 2160, refresh: 30))?.refreshRate == 30)
        #expect(c.match(ModeRequest(width: 3840, height: 2160, hiDPI: true)) == nil)
        #expect(c.match(ModeRequest(width: 1234, height: 567)) == nil)
        #expect(c.match(ModeRequest(modeID: 6))?.refreshRate == 30)
        let onePixel = ModeCatalog(modes: Self.fourK, current: Self.fourK[3])
        #expect(onePixel.match(ModeRequest(width: 1920, height: 1080))?.isHiDPI == false, "current is 1×")
    }

    @Test func refreshRatesFormat() {
        let en = Locale(identifier: "en_US")
        #expect(RefreshFormat.title(59.93998718261719, locale: en) == "59.94 Hz")
        #expect(RefreshFormat.title(120, locale: en) == "120 Hz")
        #expect(RefreshFormat.title(47.94999694824219, locale: en) == "47.95 Hz")
        #expect(RefreshFormat.title(120, proMotion: true, locale: en) == "ProMotion")
        #expect(RefreshFormat.isProMotion(120, builtIn: true, rates: [120, 60, 50]))
        #expect(!RefreshFormat.isProMotion(120, builtIn: false, rates: [120, 60]))
        #expect(!RefreshFormat.isProMotion(60, builtIn: true, rates: [120, 60]))
        #expect(!RefreshFormat.isProMotion(120, builtIn: true, rates: [120]))
    }

    // MARK: Confirmation

    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func confirmationRevertsAfterTimeout() {
        var c = ModeConfirmation()
        let old = Self.mode(1920, 1080, scale: 2), new = Self.mode(2560, 1440, scale: 2)
        #expect(c.begin(display: 2, previous: old, applied: new, now: Self.t0) == nil)
        #expect(c.isPending)
        #expect(c.secondsLeft(at: Self.t0) == 15)
        #expect(c.secondsLeft(at: Self.t0.addingTimeInterval(4.2)) == 11)
        #expect(abs(c.progress(at: Self.t0.addingTimeInterval(7.5)) - 0.5) < 0.0001)
        #expect(c.tick(now: Self.t0.addingTimeInterval(14.9)) == nil)
        #expect(c.tick(now: Self.t0.addingTimeInterval(15)) == .revert(2, old))
        #expect(!c.isPending)
        #expect(c.tick(now: Self.t0.addingTimeInterval(20)) == nil, "fires once")
        #expect(c.secondsLeft(at: Self.t0) == 0)
    }

    @Test func confirmationKeepAndRevert() {
        var c = ModeConfirmation()
        let old = Self.mode(1920, 1080), new = Self.mode(3840, 2160)
        c.begin(display: 2, previous: old, applied: new, now: Self.t0)
        #expect(c.keep() == .kept(2))
        #expect(c.keep() == nil)
        #expect(c.tick(now: Self.t0.addingTimeInterval(60)) == nil)
        c.begin(display: 2, previous: old, applied: new, now: Self.t0)
        #expect(c.revert() == .revert(2, old))
        #expect(c.revert() == nil)
    }

    @Test func confirmationChainsChangesOnOneDisplay() {
        var c = ModeConfirmation()
        let a = Self.mode(1920, 1080), b = Self.mode(2560, 1440), d = Self.mode(3840, 2160)
        c.begin(display: 2, previous: a, applied: b, now: Self.t0)
        // A second change before confirming still falls back to the first mode, with a fresh deadline.
        #expect(c.begin(display: 2, previous: b, applied: d, now: Self.t0.addingTimeInterval(10)) == nil)
        #expect(c.pending?.previous == a)
        #expect(c.tick(now: Self.t0.addingTimeInterval(15)) == nil)
        #expect(c.tick(now: Self.t0.addingTimeInterval(25)) == .revert(2, a))
        // Going back to where it started needs no prompt.
        c.begin(display: 2, previous: a, applied: b, now: Self.t0)
        #expect(c.begin(display: 2, previous: b, applied: a, now: Self.t0) == nil)
        #expect(!c.isPending)
    }

    @Test func confirmationOnAnotherDisplayKeepsTheFirst() {
        var c = ModeConfirmation()
        c.begin(display: 1, previous: Self.mode(1, 1), applied: Self.mode(2, 2), now: Self.t0)
        #expect(c.begin(display: 2, previous: Self.mode(3, 3), applied: Self.mode(4, 4), now: Self.t0) == .kept(1))
        #expect(c.pending?.displayID == 2)
        c.displayRemoved(1)
        #expect(c.isPending)
        c.displayRemoved(2)
        #expect(!c.isPending)
    }

    // MARK: Brightness

    @Test func trackSharesAddUp() {
        let full = BrightnessTrack(hasHardware: true, dimming: true, boost: true)
        #expect(abs(full.dimShare + full.hardwareShare + full.boostShare - 1) < 1e-9)
        #expect(abs(full.hardwareStart - 0.25 / 1.5) < 1e-9)
        let plain = BrightnessTrack(hasHardware: true, dimming: false, boost: false)
        #expect(plain.hardwareShare == 1 && plain.hardwareStart == 0 && plain.hardwareEnd == 1)
        let software = BrightnessTrack(hasHardware: false, dimming: true, boost: false)
        #expect(software.dimShare == 1 && software.hardwareShare == 0)
        #expect(BrightnessTrack(hasHardware: false, dimming: false, boost: false).isEmpty)
    }

    @Test func trackMapsPositionsToComponents() {
        let t = BrightnessTrack(hasHardware: true, dimming: true, boost: false)   // 20 % dim, 80 % hardware
        #expect(t.components(at: 0) == BrightnessComponents(hardware: 0, dim: 1))
        #expect(t.components(at: 0.1) == BrightnessComponents(hardware: 0, dim: 0.5))
        #expect(t.components(at: 0.2) == BrightnessComponents(hardware: 0, dim: 0))
        #expect(t.components(at: 0.6) == BrightnessComponents(hardware: 50))
        #expect(t.components(at: 1) == BrightnessComponents(hardware: 100))
        #expect(t.components(at: 1.7) == BrightnessComponents(hardware: 100), "clamped")
        #expect(t.components(at: -1) == BrightnessComponents(hardware: 0, dim: 1), "clamped")
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(t.position(t.components(at: p)) - p) < 0.002, "round trip at \(p)")
        }
    }

    @Test func trackContinuesIntoExtraBrightness() {
        let t = BrightnessTrack(hasHardware: true, dimming: true, boost: true)
        let c = t.components(at: 1)
        #expect(c.hardware == 100 && c.boost == 1 && c.dim == 0)
        let mid = t.components(at: t.hardwareEnd + t.boostShare / 2)
        #expect(mid.hardware == 100 && abs(mid.boost - 0.5) < 1e-9)
        #expect(abs(t.position(BrightnessComponents(hardware: 100, boost: 0.5)) - (t.hardwareEnd + t.boostShare / 2)) < 1e-9)
        // Software only: the whole track dims; the right end is full brightness.
        let s = BrightnessTrack(hasHardware: false, dimming: true, boost: false)
        #expect(s.components(at: 1) == BrightnessComponents(hardware: 100, dim: 0))
        #expect(s.components(at: 0.25).dim == 0.75)
        #expect(s.position(BrightnessComponents(hardware: 100, dim: 0)) == 1)
        #expect(s.position(BrightnessComponents(hardware: 100, dim: 0.4)) == 0.6)
    }

    @Test func levelsCombineHardwareDimmingAndBoost() {
        #expect(BrightnessLevel.level(BrightnessComponents(hardware: 40)) == 40)
        #expect(BrightnessLevel.level(BrightnessComponents(hardware: 0, dim: 0.3)) == -30)
        #expect(BrightnessLevel.level(BrightnessComponents(hardware: 100, boost: 0.5)) == 150)
        #expect(BrightnessLevel.components(-30, dimming: true, boost: false) == BrightnessComponents(hardware: 0, dim: 0.3))
        #expect(BrightnessLevel.components(-30, dimming: false, boost: false) == BrightnessComponents(hardware: 0))
        #expect(BrightnessLevel.components(170, dimming: true, boost: true) == BrightnessComponents(hardware: 100, boost: 0.7))
        #expect(BrightnessLevel.components(170, dimming: true, boost: false) == BrightnessComponents(hardware: 100))
        #expect(BrightnessLevel.components(-400, dimming: true, boost: true).dim == 1)
    }

    @Test func softwareFactors() {
        #expect(SoftwareFactor.dim(0, maxDim: 0.85) == 1)
        #expect(abs(SoftwareFactor.dim(1, maxDim: 0.85) - 0.15) < 1e-9)
        #expect(abs(SoftwareFactor.dim(0.5, maxDim: 0.8) - 0.6) < 1e-9)
        #expect(abs(SoftwareFactor.dim(1, maxDim: 1.5) - 0.02) < 1e-9, "never fully black")
        #expect(SoftwareFactor.boost(0, maxBoost: 1.6) == 1)
        #expect(abs(SoftwareFactor.boost(0.5, maxBoost: 1.6) - 1.3) < 1e-9)
        #expect(SoftwareFactor.boost(2, maxBoost: 1.6) == 1.6)
        // Headroom not granted yet: ask for the target (within what the panel can do).
        #expect(SoftwareFactor.boostToRender(target: 1.6, potential: 16, current: 1) == 1.6)
        #expect(SoftwareFactor.boostToRender(target: 1.6, potential: 1.4, current: 1) == 1.4)
        // Granted: stay inside it so highlights don't clip.
        #expect(SoftwareFactor.boostToRender(target: 1.6, potential: 16, current: 1.5) == 1.5)
        #expect(SoftwareFactor.boostToRender(target: 1.6, potential: 16, current: 3.2) == 1.6)
        #expect(SoftwareFactor.boostToRender(target: 0.5, potential: 16, current: 3) == 1)
    }

    @Test func dimMethods() {
        #expect(DimMethod.automatic.usesGamma(gammaSupported: true))
        #expect(!DimMethod.automatic.usesGamma(gammaSupported: false))
        #expect(!DimMethod.overlay.usesGamma(gammaSupported: true))
        #expect(DimMethod.gamma.usesGamma(gammaSupported: true))
    }

    @Test func gammaTablesScaleAndClamp() {
        let id = GammaTable.identity(count: 5)
        #expect(id.red == [0, 0.25, 0.5, 0.75, 1])
        #expect(id.count == 5)
        let half = id.scaled(by: 0.5)
        #expect(half.green == [0, 0.125, 0.25, 0.375, 0.5])
        #expect(id.scaled(by: 3) == id, "factors above 1 are clamped")
        #expect(id.scaled(by: -1).blue.allSatisfy { $0 == 0 })
        let odd = GammaTable(red: [0, 1.2], green: [0, 1], blue: [0, 1])
        #expect(odd.scaled(by: 1).red == [0, 1], "values stay within 0…1")
        #expect(GammaTable.identity(count: 1).count == 2)
    }

    @Test func gammaBookkeepingCapturesOnceAndRestores() {
        var b = GammaBookkeeping()
        let original = GammaTable(red: [0, 0.6, 1], green: [0, 0.5, 1], blue: [0, 0.4, 1])
        var reads = 0
        let first = b.set(0.5, for: 7) { reads += 1; return original }
        #expect(first == [.apply(7, original.scaled(by: 0.5))])
        #expect(b.isActive && b.dimmedDisplays == [7])
        // Dimming further doesn't re-read the (already dimmed) table.
        #expect(b.set(0.25, for: 7) { reads += 1; return nil } == [.apply(7, original.scaled(by: 0.25))])
        #expect(reads == 1)
        #expect(b.set(1, for: 7) { nil } == [.restore(7, original)])
        #expect(!b.isActive)
        #expect(b.set(1, for: 7) { nil } == [], "undimmed displays need nothing")
    }

    @Test func gammaBookkeepingFallsBackToFormula() {
        var b = GammaBookkeeping()
        let table = GammaTable.identity(count: 4)
        _ = b.set(0.6, for: 1) { table }
        #expect(b.set(0.4, for: 2) { nil } == [.formula(2, 0.4)])
        // Undoing a formula hands everything back to ColorSync, then re-dims the other display.
        #expect(b.set(1, for: 2) { nil } == [.restoreSystem, .apply(1, table.scaled(by: 0.6))])
        #expect(b.restoreAll() == [.restoreSystem])
        #expect(!b.isActive)
        #expect(b.restoreAll() == [])
    }

    @Test func gammaBookkeepingReappliesAfterSystemReset() {
        var b = GammaBookkeeping()
        _ = b.set(0.5, for: 3) { GammaTable.identity(count: 3) }
        let recalibrated = GammaTable(red: [0, 0.4, 0.9], green: [0, 0.4, 0.9], blue: [0, 0.4, 0.9])
        #expect(b.tablesChanged { _ in recalibrated } == [.restoreSystem, .apply(3, recalibrated.scaled(by: 0.5))])
        #expect(b.originals[3] == .some(recalibrated))
        b.retain(online: [9])
        #expect(!b.isActive)
        #expect(b.tablesChanged { _ in recalibrated } == [])
    }

    @Test func syncKeepsDistance() {
        #expect(BrightnessSync.follow(source: 60, offset: -20, range: -100...100) == 40)
        #expect(BrightnessSync.follow(source: 10, offset: -20, range: -100...100) == -10, "continues into dimming")
        #expect(BrightnessSync.follow(source: 10, offset: -20, range: 0...100) == 0)
        #expect(BrightnessSync.follow(source: 95, offset: 20, range: 0...100) == 100)
        #expect(BrightnessSync.offset(follower: 30, source: 70) == -40)
        #expect(BrightnessSync.range(dimming: true, boost: false) == -100...100)
        #expect(BrightnessSync.range(dimming: false, boost: true) == 0...200)
        #expect(BrightnessSync.moved(from: nil, to: 50))
        #expect(!BrightnessSync.moved(from: 50, to: 50.3))
        #expect(BrightnessSync.moved(from: 50, to: 51))
    }

    // MARK: Arrangement

    @Test func makingMainKeepsTheLayout() {
        let bounds: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            2: CGRect(x: 1728, y: -400, width: 2560, height: 1440),
            3: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        ]
        let o = Arrangement.originsMakingMain(2, bounds: bounds)
        #expect(o?[2] == .zero)
        #expect(o?[1] == CGPoint(x: -1728, y: 400))
        #expect(o?[3] == CGPoint(x: -3648, y: 400))
        #expect(Arrangement.originsMakingMain(9, bounds: bounds) == nil)
    }

    @Test func mirrorSourcesSkipLoops() {
        let sources = Arrangement.mirrorSources(for: 1, displays: [1, 2, 3, 4], mirrorOf: [3: 1, 4: 2])
        #expect(sources == [2], "not itself, not a display mirroring it, not one already mirroring another")
    }

    @Test func stableIDsNumberTwins() {
        let d = DisplayEngine.OnlineDisplay(id: 2, name: "", isBuiltIn: false, vendor: 1, model: 2, serial: 0, bounds: .zero)
        var e = d
        e.id = 3
        let other = DisplayEngine.OnlineDisplay(id: 4, name: "", isBuiltIn: false, vendor: 5, model: 6, serial: 7, bounds: .zero)
        #expect(DisplayEngine.stableIDs([d, other, e]) == ["1-2-0", "5-6-7", "1-2-0#2"])
    }

    // MARK: Virtual displays

    @Test func virtualDisplaySizesKeepShape() {
        let sizes = VirtualDisplayModes.sizes(width: 3840, height: 2160)
        #expect(sizes.first! == (3840, 2160))
        #expect(sizes.allSatisfy { $0.0 % 2 == 0 && $0.1 % 2 == 0 })
        #expect(sizes.allSatisfy { abs(Double($0.0) / Double($0.1) - 16.0 / 9) < 0.01 })
        #expect(sizes.contains { $0 == (1920, 1080) })
        #expect(sizes.allSatisfy { min($0.0, $0.1) >= 480 })
        #expect(VirtualDisplayModes.sizes(width: 640, height: 480).count == 1)
        #expect(VirtualDisplayModes.sizes(width: 0, height: 100).isEmpty)
        let mm = VirtualDisplayModes.millimeters(width: 2180, height: 2180, hiDPI: true)
        #expect(abs(mm.width - 254) < 0.01)
        #expect(VirtualDisplayModes.clamp(100) == 640 && VirtualDisplayModes.clamp(20000) == 8192)
        let c = VirtualDisplayConfig(name: "x", width: 3840, height: 2160)
        #expect(c.looksLike == (1920, 1080))
        #expect(VirtualDisplayConfig(name: "x", width: 1920, height: 1080, hiDPI: false).looksLike == (1920, 1080))
        #expect(VirtualDisplayAPI.isVirtual(vendor: VirtualDisplayAPI.vendorID, model: VirtualDisplayAPI.productID))
        #expect(!VirtualDisplayAPI.isVirtual(vendor: 0x10AC, model: VirtualDisplayAPI.productID))
    }

    /// Builds the runtime objects a virtual display is made of, without creating a display.
    @MainActor @Test func virtualDisplayBridgeBuildsDescriptors() throws {
        guard VirtualDisplayAPI.isAvailable else { return }
        let config = VirtualDisplayConfig(name: "Test", width: 2560, height: 1440, hiDPI: true, serial: 0xABCD)
        let d = try #require(VirtualDisplayAPI.descriptor(for: config))
        #expect(d.value(forKey: "name") as? String == "Test")
        #expect((d.value(forKey: "maxPixelsWide") as? NSNumber)?.intValue == 2560)
        #expect((d.value(forKey: "serialNum") as? NSNumber)?.uint32Value == 0xABCD)
        #expect((d.value(forKey: "vendorID") as? NSNumber)?.uint32Value == VirtualDisplayAPI.vendorID)
        let s = try #require(VirtualDisplayAPI.settings(for: config))
        #expect((s.value(forKey: "hiDPI") as? NSNumber)?.intValue == 1)
        let modes = try #require(s.value(forKey: "modes") as? [NSObject])
        #expect(modes.count == VirtualDisplayModes.sizes(width: 2560, height: 1440).count)
        #expect((modes.first?.value(forKey: "width") as? NSNumber)?.intValue == 2560)
    }

    // MARK: Settings

    @Test func oldSettingsFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pd-settings-\(UUID().uuidString)")
        let store = SettingsStore(directory: dir)
        let old = #"{"linkedBrightness":true,"wheelIncrement":10,"monitors":{"a":{"hidden":true,"lastBrightness":40}}}"#
        try Data(old.utf8).write(to: store.url(for: "powerdisplay"))
        let s = store.load("powerdisplay", default: PowerDisplaySettings())
        #expect(s.linkedBrightness && s.wheelIncrement == 10)
        #expect(s.monitors["a"]?.hidden == true && s.monitors["a"]?.lastBrightness == 40)
        #expect(s.monitors["a"]?.favoriteModes == [])
        #expect(s.softwareDimming && !s.extraBrightness && s.confirmModeChanges)
        #expect(s.pip == PiPOptions() && s.virtualDisplays.isEmpty && s.syncSource == nil)
        var changed = s
        changed.virtualDisplays = [VirtualDisplayConfig(name: "Stream", width: 1920, height: 1080, mirroredBy: "a")]
        changed.monitors["a"]?.favoriteModes = ["1920x1080/3840x2160"]
        changed.syncSource = "a"
        store.save(changed, id: "powerdisplay", defaults: PowerDisplaySettings())
        #expect(store.load("powerdisplay", default: PowerDisplaySettings()) == changed)
    }

    @Test func colorProfilesPutTheDisplaysOwnFirst() {
        let own = URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays/Color LCD-1.icc")
        let list = [
            ColorProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"), name: "sRGB IEC61966-2.1"),
            ColorProfile(url: URL(fileURLWithPath: "/Library/ColorSync/Profiles/Displays/DELL-2.icc"), name: "DELL U2723QE"),
            ColorProfile(url: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Display P3.icc"), name: "Display P3"),
            ColorProfile(url: own, name: "Color LCD"),
            ColorProfile(url: own, name: "Color LCD"),
        ]
        let ordered = ColorProfiles.ordered(list, factory: own)
        #expect(ordered.map(\.name) == ["Color LCD", "DELL U2723QE", "Display P3", "sRGB IEC61966-2.1"])
        #expect(ordered[1].isDisplayProfile && !ordered[2].isDisplayProfile)
    }

    @Test func pipGeometry() {
        let s = PiPGeometry.initialSize(display: CGSize(width: 2560, height: 1440), screen: CGSize(width: 1728, height: 1080))
        #expect(s == CGSize(width: 480, height: 270))
        #expect(PiPGeometry.initialSize(display: CGSize(width: 1080, height: 1920), screen: CGSize(width: 400, height: 800)).width == 240)
        #expect(PiPGeometry.initialSize(display: .zero, screen: CGSize(width: 1000, height: 800)).height == 270)
        #expect(PiPGeometry.captureScale(windowWidth: 480, backing: 2, displayWidth: 2560) == 0.375)
        #expect(PiPGeometry.captureScale(windowWidth: 4000, backing: 2, displayWidth: 1000) == 2)
        #expect(PiPGeometry.captureScale(windowWidth: 10, backing: 1, displayWidth: 5000) == 0.25)
        #expect(PiPGeometry.origin(for: CGSize(width: 100, height: 50), in: CGRect(x: 0, y: 0, width: 1000, height: 800)) == CGPoint(x: 876, y: 24))
    }

    // MARK: Command line

    @Test func cliModeOptions() throws {
        let set = try PowerDisplayCLI.Options.parse(["set-mode", "-n", "2", "2560x1440@60", "--hidpi"])
        #expect(set.command == "set-mode" && set.numbers == [2])
        #expect(set.positional == ["2560x1440@60"] && set.hiDPI == true)
        let byID = try PowerDisplayCLI.Options.parse(["set-mode", "-i", "a-b-c", "--mode-id", "54", "--refresh", "59.94Hz", "--no-hidpi"])
        #expect(byID.modeID == 54 && byID.refresh == 59.94 && byID.hiDPI == false && byID.id == "a-b-c")
        let modes = try PowerDisplayCLI.Options.parse(["modes", "--json"])
        #expect(modes.command == "modes" && modes.json && modes.numbers.isEmpty)
        let dim = try PowerDisplayCLI.Options.parse(["dim", "-n", "1,2", "40"])
        #expect(dim.positional == ["40"] && dim.numbers == [1, 2])
        #expect(try PowerDisplayCLI.Options.parse(["dim", "--level=off"]).level == "off")
        #expect(try PowerDisplayCLI.Options.parse(["pip", "-n", "2", "--close"]).close)
        #expect(throws: PowerDisplayCLI.Failure.self) { try PowerDisplayCLI.Options.parse(["set-mode", "--refresh", "fast"]) }
        #expect(throws: PowerDisplayCLI.Failure.self) { try PowerDisplayCLI.Options.parse(["set-mode", "--mode-id", "x"]) }
        #expect(PowerDisplayCLI.parseDimLevel("off") == 0)
        #expect(PowerDisplayCLI.parseDimLevel("40%") == 40)
        #expect(PowerDisplayCLI.parseDimLevel("100") == 100)
        #expect(PowerDisplayCLI.parseDimLevel("101") == nil && PowerDisplayCLI.parseDimLevel("dark") == nil)
        #expect(PowerDisplayCLI.rateText(59.93998718261719) == "59.94" && PowerDisplayCLI.rateText(120) == "120")
        #expect(PowerDisplayCLI.modeText(Self.mode(1728, 1117, scale: 2, 120)) == "1728x1117 HiDPI @ 120 Hz")
    }
}
