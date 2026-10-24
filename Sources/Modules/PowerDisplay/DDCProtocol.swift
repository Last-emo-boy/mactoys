import Foundation

/// DDC/CI (VESA Display Data Channel Command Interface) packets, as pure data.
///
/// On Apple silicon the transport is `IOAVServiceWriteI2C(service, 0x37, 0x51, bytes)`: the chip
/// address 0x37 and the host's source address 0x51 are supplied by the call, so a packet here
/// starts at the length byte. Checksums are the XOR of every byte on the wire, including the
/// display's address 0x6E and the source address 0x51 (or the virtual host address 0x50 in replies).
public enum DDCPacket {
    public static let chipAddress: UInt32 = 0x37
    public static let sourceAddress: UInt8 = 0x51
    public static let displayAddress: UInt8 = 0x6E
    public static let replyHostAddress: UInt8 = 0x50

    /// Checksum seed for requests: destination ⊕ source.
    public static let requestSeed: UInt8 = displayAddress ^ sourceAddress
    /// Seed used by m1ddc and MonitorControl for Get requests; some displays only answer to it.
    public static let legacyReadSeed: UInt8 = displayAddress

    public static let getVCPOpcode: UInt8 = 0x01
    public static let getVCPReplyOpcode: UInt8 = 0x02
    public static let setVCPOpcode: UInt8 = 0x03
    public static let capabilitiesOpcode: UInt8 = 0xF3
    public static let capabilitiesReplyOpcode: UInt8 = 0xE3

    /// Size of a Get VCP Feature reply read back from the display.
    public static let vcpReplyLength = 11
    /// Size of a capabilities fragment read: 32 data bytes plus framing.
    public static let capabilitiesReplyLength = 38

    public static func checksum<S: Sequence>(_ bytes: S, seed: UInt8) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Set VCP Feature: `84 03 <code> <hi> <lo> <chk>`.
    public static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x84, setVCPOpcode, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        p.append(checksum(p, seed: requestSeed))
        return p
    }

    /// Get VCP Feature request: `82 01 <code> <chk>`.
    public static func getVCP(_ code: UInt8, seed: UInt8 = requestSeed) -> [UInt8] {
        var p: [UInt8] = [0x82, getVCPOpcode, code]
        p.append(checksum(p, seed: seed))
        return p
    }

    /// Capabilities Request at a byte offset: `83 F3 <hi> <lo> <chk>`.
    public static func capabilitiesRequest(offset: UInt16) -> [UInt8] {
        var p: [UInt8] = [0x83, capabilitiesOpcode, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        p.append(checksum(p, seed: requestSeed))
        return p
    }

    /// Whether a reply's last byte matches the XOR of the virtual host address and the rest.
    public static func replyChecksumValid(_ bytes: [UInt8], length: Int) -> Bool {
        guard length >= 2, bytes.count >= length else { return false }
        return checksum(bytes[0..<(length - 1)], seed: replyHostAddress) == bytes[length - 1]
    }

    /// Parses a Get VCP Feature reply:
    /// `6E 88 02 <result> <code> <type> <max hi> <max lo> <cur hi> <cur lo> <chk>`.
    public static func parseVCPReply(_ bytes: [UInt8], code: UInt8) -> VCPReply? {
        guard bytes.count >= vcpReplyLength, bytes[2] == getVCPReplyOpcode, bytes[4] == code,
              bytes[1] & 0x80 != 0, Int(bytes[1] & 0x7F) == 8,
              replyChecksumValid(bytes, length: vcpReplyLength) else { return nil }
        return VCPReply(code: code, supported: bytes[3] == 0, isMomentary: bytes[5] == 1,
                        maximum: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
                        current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]))
    }

    /// Parses one capabilities fragment: `6E <80|n> E3 <off hi> <off lo> <data…> <chk>`.
    /// Returns the fragment's data (empty at the end of the string), or nil when invalid.
    public static func parseCapabilitiesReply(_ bytes: [UInt8], offset: UInt16) -> [UInt8]? {
        guard bytes.count >= 6, bytes[1] & 0x80 != 0, bytes[2] == capabilitiesReplyOpcode else { return nil }
        let n = Int(bytes[1] & 0x7F)
        guard n >= 3, n <= 35, bytes.count >= n + 3,
              UInt16(bytes[3]) << 8 | UInt16(bytes[4]) == offset,
              replyChecksumValid(bytes, length: n + 3) else { return nil }
        return Array(bytes[5..<(2 + n)])
    }
}

/// A decoded Get VCP Feature reply.
public struct VCPReply: Equatable, Sendable {
    public var code: UInt8
    /// False when the display answered "unsupported VCP code".
    public var supported: Bool
    public var isMomentary: Bool
    public var maximum: UInt16
    public var current: UInt16
}

/// A parsed MCCS capabilities string, e.g.
/// `(prot(monitor)type(lcd)model(27UK850)cmds(01 02 03 0C E3 F3)vcp(10 12 14(05 08 0B) 60(0F 11 12) 62 D6(01 04))mccs_ver(2.1))`.
public struct DDCCapabilities: Codable, Equatable, Sendable {
    public var raw: String
    public var type: String?
    public var model: String?
    public var mccsVersion: String?
    public var commands: [UInt8]
    /// VCP code → the discrete values the display lists for it (empty for continuous controls).
    public var vcp: [UInt8: [UInt16]]

    public func supports(_ code: UInt8) -> Bool { vcp[code] != nil }

    /// VCP codes in ascending order.
    public var codes: [UInt8] { vcp.keys.sorted() }

    public static func parse(_ text: String) -> DDCCapabilities {
        // NULs go; other control characters (line breaks some monitors send) become spaces.
        let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.compactMap { u -> Unicode.Scalar? in
            if u.value == 0 || u.value >= 0x7F { return nil }
            return u.value < 0x20 ? " " : u
        }))
        var caps = DDCCapabilities(raw: cleaned, type: nil, model: nil, mccsVersion: nil, commands: [], vcp: [:])
        for (key, value) in sections(of: cleaned) {
            switch key.lowercased() {
            case "type": caps.type = value.trimmingCharacters(in: .whitespaces)
            case "model": caps.model = value.trimmingCharacters(in: .whitespaces)
            case "mccs_ver": caps.mccsVersion = value.trimmingCharacters(in: .whitespaces)
            case "cmds": caps.commands = hexBytes(value).map { UInt8(truncatingIfNeeded: $0) }
            case "vcp":
                for (code, values) in vcpList(value) { caps.vcp[code] = values }
            default: break
            }
        }
        return caps
    }

    /// Top-level `key(value)` pairs; tolerates a missing outer pair of parentheses.
    static func sections(of text: String) -> [(String, String)] {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "(" {
            let close = matchingClose(in: s, from: s.startIndex)
            if close == s.index(before: s.endIndex) { s = s.dropFirst().dropLast() }
            else if close == nil { s = s.dropFirst() }   // truncated string: missing final ")"
        }
        var out: [(String, String)] = []
        var i = s.startIndex
        while i < s.endIndex {
            var key = ""
            while i < s.endIndex, s[i] != "(" {
                if s[i].isLetter || s[i].isNumber || s[i] == "_" { key.append(s[i]) } else if s[i] == ")" { key = "" }
                i = s.index(after: i)
            }
            guard i < s.endIndex else { break }
            let close = matchingClose(in: s, from: i) ?? s.index(before: s.endIndex)
            let valueStart = s.index(after: i)
            let value = valueStart <= close ? String(s[valueStart..<close]) : ""
            if !key.isEmpty { out.append((key, value)) }
            i = close < s.endIndex ? s.index(after: close) : s.endIndex
        }
        return out
    }

    /// The index of the `)` that closes the `(` at `open`, or nil when unbalanced.
    static func matchingClose(in s: Substring, from open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var i = open
        while i < s.endIndex {
            if s[i] == "(" { depth += 1 }
            if s[i] == ")" { depth -= 1; if depth == 0 { return i } }
            i = s.index(after: i)
        }
        return nil
    }

    /// `10 12 14(05 08 0B) 60(0F 11 12)` → [(0x10, []), (0x12, []), (0x14, [5, 8, 11]), …].
    /// Accepts run-together codes ("1012"), missing spaces before "(" and nested lists.
    static func vcpList(_ text: String) -> [(UInt8, [UInt16])] {
        var out: [(UInt8, [UInt16])] = []
        let s = Substring(text)
        var i = s.startIndex
        var token = ""
        func flush() {
            for code in hexBytes(token) { out.append((UInt8(truncatingIfNeeded: code), [])) }
            token = ""
        }
        while i < s.endIndex {
            let ch = s[i]
            if ch == "(" {
                let close = matchingClose(in: s, from: i) ?? s.index(before: s.endIndex)
                let inner = String(s[s.index(after: i)..<max(s.index(after: i), close)])
                flush()
                if let last = out.popLast() {
                    // Nested lists (rare) contribute their top-level values only.
                    let flat = inner.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
                    out.append((last.0, hexBytes(flat).map { UInt16($0) }))
                }
                i = close < s.endIndex ? s.index(after: close) : s.endIndex
                continue
            }
            if ch.isHexDigit { token.append(ch) } else { flush() }
            i = s.index(after: i)
        }
        flush()
        return out
    }

    /// Splits whitespace-separated hex tokens; tokens longer than two digits are read as byte pairs.
    static func hexBytes(_ text: String) -> [Int] {
        var out: [Int] = []
        for token in text.split(whereSeparator: { !$0.isHexDigit }) {
            var t = Substring(token)
            if t.count % 2 == 1 { t = "0" + t }
            while !t.isEmpty {
                if let v = Int(t.prefix(2), radix: 16) { out.append(v) }
                t = t.dropFirst(2)
            }
        }
        return out
    }
}

/// MCCS names for VCP codes and their well-known values.
public enum MCCS {
    public static let brightness: UInt8 = 0x10
    public static let contrast: UInt8 = 0x12
    public static let colorPreset: UInt8 = 0x14
    public static let inputSource: UInt8 = 0x60
    public static let volume: UInt8 = 0x62
    public static let mute: UInt8 = 0x8D
    public static let orientation: UInt8 = 0xAA
    public static let powerMode: UInt8 = 0xD6

    public static let featureNames: [UInt8: String] = [
        0x02: "New control value", 0x04: "Restore factory defaults", 0x05: "Restore brightness and contrast",
        0x06: "Restore geometry", 0x08: "Restore color defaults", 0x0B: "Color temperature increment",
        0x0C: "Color temperature request", 0x10: "Brightness", 0x12: "Contrast", 0x14: "Select color preset",
        0x16: "Video gain: red", 0x18: "Video gain: green", 0x1A: "Video gain: blue", 0x1E: "Auto setup",
        0x20: "Horizontal position", 0x30: "Vertical position", 0x52: "Active control", 0x56: "Horizontal moiré",
        0x59: "6-axis saturation: red", 0x5A: "6-axis saturation: yellow", 0x5B: "6-axis saturation: green",
        0x5C: "6-axis saturation: cyan", 0x5D: "6-axis saturation: blue", 0x5E: "6-axis saturation: magenta",
        0x60: "Input source", 0x62: "Audio speaker volume", 0x6C: "Video black level: red",
        0x6E: "Video black level: green", 0x70: "Video black level: blue", 0x72: "Gamma", 0x86: "Display scaling",
        0x87: "Sharpness", 0x8A: "Color saturation", 0x8D: "Audio mute", 0x90: "Hue", 0x9B: "6-axis hue: red",
        0x9C: "6-axis hue: yellow", 0x9D: "6-axis hue: green", 0x9E: "6-axis hue: cyan", 0x9F: "6-axis hue: blue",
        0xA0: "6-axis hue: magenta", 0xAA: "Screen orientation", 0xAC: "Horizontal frequency",
        0xAE: "Vertical frequency", 0xB2: "Flat panel sub-pixel layout", 0xB6: "Display technology type",
        0xC0: "Display usage time", 0xC6: "Application enable key", 0xC8: "Display controller type",
        0xC9: "Display firmware level", 0xCA: "OSD", 0xCC: "OSD language", 0xD6: "Power mode",
        0xDC: "Display mode", 0xDF: "VCP version", 0xE0: "Manufacturer specific",
    ]

    public static let inputSourceNames: [UInt16: String] = [
        0x01: "VGA 1", 0x02: "VGA 2", 0x03: "DVI 1", 0x04: "DVI 2", 0x05: "Composite 1", 0x06: "Composite 2",
        0x07: "S-Video 1", 0x08: "S-Video 2", 0x09: "Tuner 1", 0x0A: "Tuner 2", 0x0B: "Tuner 3",
        0x0C: "Component 1", 0x0D: "Component 2", 0x0E: "Component 3", 0x0F: "DisplayPort 1",
        0x10: "DisplayPort 2", 0x11: "HDMI 1", 0x12: "HDMI 2", 0x13: "HDMI 3", 0x14: "HDMI 4",
        0x15: "Thunderbolt 1", 0x16: "Thunderbolt 2", 0x19: "USB-C 1", 0x1A: "USB-C 2", 0x1B: "USB-C 3",
    ]

    public static let colorPresetNames: [UInt16: String] = [
        0x01: "sRGB", 0x02: "Display native", 0x03: "4000 K", 0x04: "5000 K", 0x05: "6500 K", 0x06: "7500 K",
        0x07: "8200 K", 0x08: "9300 K", 0x09: "10000 K", 0x0A: "11500 K", 0x0B: "User 1", 0x0C: "User 2",
        0x0D: "User 3",
    ]

    public static let powerModeNames: [UInt16: String] = [
        0x01: "On", 0x02: "Standby", 0x03: "Suspend", 0x04: "Off (DPM)", 0x05: "Off (power button)",
    ]

    public static func featureName(_ code: UInt8) -> String {
        featureNames[code] ?? (code >= 0xE0 ? "Manufacturer specific" : "Unknown")
    }

    public static func hex(_ v: Int) -> String { String(format: "0x%02X", v) }
}

/// Maps between slider percentages and a display's raw VCP range (not every display uses 0–100).
public enum VCPScale {
    public static func percent(raw: UInt16, maximum: UInt16) -> Double {
        let m = maximum == 0 ? 100 : Double(maximum)
        return max(0, min(100, (Double(raw) / m * 100).rounded()))
    }

    public static func raw(percent: Double, maximum: UInt16) -> UInt16 {
        let m = maximum == 0 ? 100 : Double(maximum)
        return UInt16(max(0, min(m, (max(0, min(100, percent)) / 100 * m).rounded())))
    }
}
