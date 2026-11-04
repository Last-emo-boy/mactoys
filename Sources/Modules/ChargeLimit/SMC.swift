import Darwin
import Foundation
import IOKit
import MacToysCore

/// A four-character SMC key such as `CHTE`.
public struct FourCC: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Exactly four printable ASCII characters.
    public init?(_ string: String) {
        let bytes = Array(string.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        rawValue = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8((rawValue >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// What the SMC reports about a key: its data size and type (`ui8 `, `hex_`, `flt `…).
public struct SMCKeyInfo: Equatable, Sendable, Codable {
    public var size: Int
    public var type: String

    public init(size: Int, type: String) {
        self.size = size
        self.type = type
    }
}

/// The 80-byte parameter block of the AppleSMC user client, packed by hand at fixed offsets so it never
/// depends on how Swift lays out structs.
struct SMCParam: Equatable {
    static let size = 80

    enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let dataAttributes = 36
        static let result = 40
        static let status = 41
        static let command = 42
        static let data32 = 44
        static let bytes = 48
    }

    /// Selector of the user client's struct method.
    static let handleEvent: UInt32 = 2
    static let readKey: UInt8 = 5
    static let keyInfoCommand: UInt8 = 9
    /// `result` when the key doesn't exist.
    static let keyNotFound: UInt8 = 0x84

    var key: UInt32 = 0
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var result: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    /// Up to 32 data bytes.
    var bytes: [UInt8] = []

    init(key: UInt32 = 0, command: UInt8, dataSize: UInt32 = 0, bytes: [UInt8] = []) {
        self.key = key
        self.command = command
        self.dataSize = dataSize
        self.bytes = Array(bytes.prefix(32))
    }

    init(decoding raw: [UInt8]) {
        precondition(raw.count >= Self.size)
        key = Self.u32(raw, Offset.key)
        dataSize = Self.u32(raw, Offset.dataSize)
        dataType = Self.u32(raw, Offset.dataType)
        result = raw[Offset.result]
        command = raw[Offset.command]
        data32 = Self.u32(raw, Offset.data32)
        bytes = Array(raw[Offset.bytes..<Offset.bytes + 32])
    }

    func encoded() -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: Self.size)
        Self.put(key, into: &raw, at: Offset.key)
        Self.put(dataSize, into: &raw, at: Offset.dataSize)
        Self.put(dataType, into: &raw, at: Offset.dataType)
        raw[Offset.result] = result
        raw[Offset.command] = command
        Self.put(data32, into: &raw, at: Offset.data32)
        for (i, b) in bytes.prefix(32).enumerated() { raw[Offset.bytes + i] = b }
        return raw
    }

    /// The user client works in host byte order (little-endian on every Mac that runs macOS 26).
    private static func u32(_ raw: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(raw[offset + $1]) << UInt32(8 * $1) }
    }

    private static func put(_ value: UInt32, into raw: inout [UInt8], at offset: Int) {
        for i in 0..<4 { raw[offset + i] = UInt8((value >> UInt32(8 * i)) & 0xFF) }
    }

    var info: SMCKeyInfo {
        SMCKeyInfo(size: Int(dataSize), type: FourCC(rawValue: dataType).description)
    }
}

/// Decodes SMC temperature readings.
enum SMCTemperature {
    /// Battery temperature sensors, in the order tried.
    static let batteryKeys = ["TB0T", "TB1T", "TB2T"]

    /// `flt ` (little-endian Float32) or `sp78` (big-endian signed 7.8 fixed point); nil for other formats
    /// and implausible values.
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        let value: Double
        switch type {
        case "flt " where bytes.count >= 4:
            let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << UInt32(8 * $1) }
            value = Double(Float(bitPattern: bits))
        case "sp78" where bytes.count >= 2:
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
        return value.isFinite && value > -40 && value < 120 ? value : nil
    }
}

// MARK: - Whitelist

/// Every SMC key Charge Limit may ever write, with the one data format accepted for each. There is no
/// way to name any other key: `ChargeKey(key:)` returns nil for it.
public enum ChargeKey: String, CaseIterable, Codable, Sendable {
    /// Charging switch on newer Apple silicon firmware.
    case chte = "CHTE"
    /// Charging switches on older Apple silicon firmware (written together).
    case ch0b = "CH0B"
    case ch0c = "CH0C"
    /// Adapter switch ("run from the battery while plugged in") on newer firmware.
    case chie = "CHIE"
    /// Adapter switch on older firmware.
    case ch0i = "CH0I"
    /// MagSafe LED color.
    case aclc = "ACLC"
    /// Firmware-kept charge limit on Intel Macs.
    case bclm = "BCLM"

    public init?(key: String) {
        self.init(rawValue: key)
    }

    var fourCC: FourCC { FourCC(rawValue)! }

    /// Data types accepted for the key, and the exact size.
    var format: (types: Set<String>, size: Int) {
        switch self {
        case .chte: (["ui32"], 4)
        case .ch0b, .ch0c, .chie, .ch0i, .aclc: (["ui8 ", "hex_"], 1)
        case .bclm: (["ui8 "], 1)
        }
    }

    /// Whether the key on this Mac has exactly the format Charge Limit knows.
    public func accepts(_ info: SMCKeyInfo) -> Bool {
        format.types.contains(info.type) && info.size == format.size
    }
}

/// One write Charge Limit may make: a whitelisted key with one of its known values. Values come only from
/// the constructors below; nothing else can build one.
public struct WhitelistedWrite: Equatable, Sendable, CustomStringConvertible {
    public let key: ChargeKey
    public let bytes: [UInt8]

    private init(_ key: ChargeKey, _ bytes: [UInt8]) {
        self.key = key
        self.bytes = bytes
    }

    public var description: String {
        "\(key.rawValue) = \(bytes.map { String(format: "%02x", $0) }.joined())"
    }

    /// Stops (`inhibit`) or allows charging. nil for keys that aren't charging switches.
    public static func charging(_ command: ChargingCommand, key: ChargeKey) -> WhitelistedWrite? {
        let on = command == .inhibit
        switch key {
        case .chte: return WhitelistedWrite(key, on ? [0x01, 0x00, 0x00, 0x00] : [0x00, 0x00, 0x00, 0x00])
        case .ch0b, .ch0c: return WhitelistedWrite(key, on ? [0x02] : [0x00])
        default: return nil
        }
    }

    /// Runs the Mac from its battery (`disabled`) or from the adapter. nil for keys that aren't adapter switches.
    public static func adapter(_ command: AdapterCommand, key: ChargeKey) -> WhitelistedWrite? {
        let off = command == .disabled
        switch key {
        case .chie: return WhitelistedWrite(key, off ? [0x08] : [0x00])
        case .ch0i: return WhitelistedWrite(key, off ? [0x01] : [0x00])
        default: return nil
        }
    }

    public static func led(_ color: LEDColor) -> WhitelistedWrite {
        switch color {
        case .system: WhitelistedWrite(.aclc, [0x00])
        case .off: WhitelistedWrite(.aclc, [0x01])
        case .green: WhitelistedWrite(.aclc, [0x03])
        case .orange: WhitelistedWrite(.aclc, [0x04])
        }
    }

    /// The firmware-kept limit; nil outside 50–100 %.
    public static func firmwareLimit(_ percent: Int) -> WhitelistedWrite? {
        guard ChargePolicy.upperRange.contains(percent) else { return nil }
        return WhitelistedWrite(.bclm, [UInt8(percent)])
    }
}

/// Reads back what a whitelisted key currently says; nil for values Charge Limit never writes.
public enum ChargeKeyValue {
    public static func charging(_ bytes: [UInt8], key: ChargeKey) -> ChargingCommand? {
        for command in [ChargingCommand.allow, .inhibit] where WhitelistedWrite.charging(command, key: key)?.bytes == bytes {
            return command
        }
        return nil
    }

    public static func adapter(_ bytes: [UInt8], key: ChargeKey) -> AdapterCommand? {
        for command in [AdapterCommand.enabled, .disabled] where WhitelistedWrite.adapter(command, key: key)?.bytes == bytes {
            return command
        }
        return nil
    }

    public static func led(_ bytes: [UInt8]) -> LEDColor? {
        [LEDColor.system, .off, .green, .orange].first { WhitelistedWrite.led($0).bytes == bytes }
    }

    public static func firmwareLimit(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 1, ChargePolicy.upperRange.contains(Int(bytes[0])) else { return nil }
        return Int(bytes[0])
    }
}

// MARK: - Connection

public enum SMCError: Error, Equatable, CustomStringConvertible {
    case notRoot
    case keyMissing(String)
    case unexpectedFormat(String, SMCKeyInfo)
    case callFailed(String, Int32)
    case smcResult(String, UInt8)

    public var description: String {
        switch self {
        case .notRoot: "SMC writes need the root helper"
        case .keyMissing(let k): "\(k) is not present"
        case let .unexpectedFormat(k, info): "\(k) has an unexpected format (\(info.type.trimmingCharacters(in: .whitespaces)), \(info.size) bytes)"
        case let .callFailed(k, code): "\(k): IOConnectCallStructMethod failed (\(String(format: "0x%x", code)))"
        case let .smcResult(k, r): "\(k): SMC returned \(String(format: "0x%02x", r))"
        }
    }
}

/// The AppleSMC user client. Reading needs no privileges. The only write path is `perform(_:)`,
/// which takes a `WhitelistedWrite`, runs only as root, checks the key's format first and reads the
/// value back afterwards.
public final class SMCConnection {
    private let connection: io_connect_t
    private let log = Log.for("chargelimit")

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        connection = conn
    }

    deinit { IOServiceClose(connection) }

    /// The key's size and type; nil when the key doesn't exist (or can't be read).
    public func keyInfo(_ key: String) -> SMCKeyInfo? {
        guard let fourCC = FourCC(key),
              let out = call(SMCParam(key: fourCC.rawValue, command: SMCParam.keyInfoCommand)),
              out.result == 0 else { return nil }
        return out.info
    }

    /// The key's current bytes.
    public func read(_ key: String) -> [UInt8]? {
        guard let info = keyInfo(key) else { return nil }
        return read(key, info: info)
    }

    private func read(_ key: String, info: SMCKeyInfo) -> [UInt8]? {
        guard let fourCC = FourCC(key), info.size > 0, info.size <= 32,
              let out = call(SMCParam(key: fourCC.rawValue, command: SMCParam.readKey, dataSize: UInt32(info.size))),
              out.result == 0 else { return nil }
        return Array(out.bytes.prefix(info.size))
    }

    /// The warmest battery sensor, in °C.
    public func batteryTemperature() -> Double? {
        SMCTemperature.batteryKeys.compactMap { key -> Double? in
            guard let info = keyInfo(key), let bytes = read(key, info: info) else { return nil }
            return SMCTemperature.decode(bytes, type: info.type)
        }.max()
    }

    /// Writes one whitelisted value. Returns whether reading the key back gave the value written.
    @discardableResult
    public func perform(_ write: WhitelistedWrite) throws -> Bool {
        guard geteuid() == 0 else { throw SMCError.notRoot }
        let name = write.key.rawValue
        guard let info = keyInfo(name) else { throw SMCError.keyMissing(name) }
        guard write.key.accepts(info), info.size == write.bytes.count else { throw SMCError.unexpectedFormat(name, info) }
        let param = SMCParam(key: write.key.fourCC.rawValue, command: Self.writeKey, dataSize: UInt32(info.size), bytes: write.bytes)
        var output = [UInt8](repeating: 0, count: SMCParam.size)
        var outSize = SMCParam.size
        let kr = IOConnectCallStructMethod(connection, SMCParam.handleEvent, param.encoded(), SMCParam.size, &output, &outSize)
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(name, kr) }
        let result = SMCParam(decoding: output).result
        guard result == 0 else { throw SMCError.smcResult(name, result) }
        let back = read(name, info: info)
        if back != write.bytes {
            log.error("\(write.description, privacy: .public) read back as \(back.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "nil", privacy: .public)")
        }
        return back == write.bytes
    }

    /// The user client's write command; used only by `perform(_:)` above.
    private static let writeKey: UInt8 = 6

    private func call(_ param: SMCParam) -> SMCParam? {
        precondition(param.command != Self.writeKey, "writes go through perform(_:)")
        var output = [UInt8](repeating: 0, count: SMCParam.size)
        var outSize = SMCParam.size
        let kr = IOConnectCallStructMethod(connection, SMCParam.handleEvent, param.encoded(), SMCParam.size, &output, &outSize)
        guard kr == KERN_SUCCESS, outSize == SMCParam.size else { return nil }
        return SMCParam(decoding: output)
    }
}
