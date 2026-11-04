import Foundation

/// The JSON-lines protocol between MacToys and the charge helper, over a Unix socket only the console
/// user can open. One request per connection: `{"cmd":"setLimit","lower":75,"upper":80}` → one response.
public enum HelperProtocol {
    /// Bump whenever the helper's behavior or protocol changes: MacToys reinstalls helpers that report
    /// another version.
    public static let version = 1
    /// Longest accepted line, in bytes.
    public static let maxLineLength = 4096
}

public enum HelperProtocolError: Error, Equatable, CustomStringConvertible {
    case malformed
    case tooLong
    case unknownCommand(String)
    case missingField(String)
    case outOfRange(String)

    public var description: String {
        switch self {
        case .malformed: "malformed request"
        case .tooLong: "request too long"
        case .unknownCommand(let c): "unknown command '\(c)'"
        case .missingField(let f): "missing field '\(f)'"
        case .outOfRange(let f): "'\(f)' is out of range"
        }
    }
}

/// A request to the helper. Decoding validates every value; nothing out of range reaches the controller.
public enum HelperRequest: Equatable, Sendable {
    case status
    case setLimit(lower: Int, upper: Int)
    case setDischarge(Bool)
    case setHeat(enabled: Bool, maxCelsius: Int)
    case setLED(LEDMode)
    case pause
    case resume
    case topUp(Bool)
    case calibrate(Bool)
    case uninstall

    private struct Wire: Codable {
        var cmd: String
        var lower: Int?
        var upper: Int?
        var on: Bool?
        var max: Int?
        var mode: String?
    }

    /// One JSON line (with the trailing newline).
    public func encoded() -> Data {
        var w = Wire(cmd: name)
        switch self {
        case .status, .pause, .resume, .uninstall: break
        case let .setLimit(lower, upper): w.lower = lower; w.upper = upper
        case .setDischarge(let on), .topUp(let on), .calibrate(let on): w.on = on
        case let .setHeat(enabled, maxCelsius): w.on = enabled; w.max = maxCelsius
        case .setLED(let mode): w.mode = mode.rawValue
        }
        return HelperJSON.line(w)
    }

    public var name: String {
        switch self {
        case .status: "status"
        case .setLimit: "setLimit"
        case .setDischarge: "setDischarge"
        case .setHeat: "setHeat"
        case .setLED: "setLED"
        case .pause: "pause"
        case .resume: "resume"
        case .topUp: "topUp"
        case .calibrate: "calibrate"
        case .uninstall: "uninstall"
        }
    }

    public static func decode(_ data: Data) throws -> HelperRequest {
        guard data.count <= HelperProtocol.maxLineLength else { throw HelperProtocolError.tooLong }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { throw HelperProtocolError.malformed }
        func on() throws -> Bool {
            guard let on = w.on else { throw HelperProtocolError.missingField("on") }
            return on
        }
        switch w.cmd {
        case "status": return .status
        case "pause": return .pause
        case "resume": return .resume
        case "uninstall": return .uninstall
        case "setDischarge": return .setDischarge(try on())
        case "topUp": return .topUp(try on())
        case "calibrate": return .calibrate(try on())
        case "setLimit":
            guard let upper = w.upper else { throw HelperProtocolError.missingField("upper") }
            guard let lower = w.lower else { throw HelperProtocolError.missingField("lower") }
            guard ChargePolicy.upperRange.contains(upper) else { throw HelperProtocolError.outOfRange("upper") }
            guard (ChargePolicy.lowestLower(for: upper)...upper).contains(lower) else { throw HelperProtocolError.outOfRange("lower") }
            return .setLimit(lower: lower, upper: upper)
        case "setHeat":
            guard let max = w.max else { throw HelperProtocolError.missingField("max") }
            guard ChargePolicy.temperatureRange.contains(max) else { throw HelperProtocolError.outOfRange("max") }
            return .setHeat(enabled: try on(), maxCelsius: max)
        case "setLED":
            guard let raw = w.mode else { throw HelperProtocolError.missingField("mode") }
            guard let mode = LEDMode(rawValue: raw) else { throw HelperProtocolError.outOfRange("mode") }
            return .setLED(mode)
        default:
            throw HelperProtocolError.unknownCommand(String(w.cmd.prefix(40)))
        }
    }
}

/// What the helper reports.
public struct HelperStatus: Codable, Equatable, Sendable {
    public var version: Int
    public var config: ChargeConfig
    public var state: ChargeState
    public var charging: ChargingCommand
    public var adapter: AdapterCommand
    public var percent: Int?
    public var adapterConnected: Bool
    public var hardware: ChargeHardware
    /// The last write that failed, if any (the helper restored normal charging after it).
    public var lastError: String?
    public var updated: Date

    public init(version: Int = HelperProtocol.version, config: ChargeConfig, state: ChargeState, charging: ChargingCommand,
                adapter: AdapterCommand, percent: Int?, adapterConnected: Bool, hardware: ChargeHardware,
                lastError: String? = nil, updated: Date = Date()) {
        self.version = version
        self.config = config
        self.state = state
        self.charging = charging
        self.adapter = adapter
        self.percent = percent
        self.adapterConnected = adapterConnected
        self.hardware = hardware
        self.lastError = lastError
        self.updated = updated
    }
}

public struct HelperResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: HelperStatus?

    public init(ok: Bool, error: String? = nil, status: HelperStatus? = nil) {
        self.ok = ok
        self.error = error
        self.status = status
    }

    public static func failure(_ message: String) -> HelperResponse { HelperResponse(ok: false, error: message) }

    public func encoded() -> Data { HelperJSON.line(self) }

    public static func decode(_ data: Data) throws -> HelperResponse {
        try HelperJSON.decoder.decode(HelperResponse.self, from: data)
    }
}

enum HelperJSON {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func line<T: Encodable>(_ value: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return ((try? e.encode(value)) ?? Data("{}".utf8)) + Data("\n".utf8)
    }
}
