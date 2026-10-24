import Foundation

/// A JSON document that keeps object keys in their original order and numbers as written,
/// so converting and pretty-printing never reshuffles or reformats the user's data.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal number text, e.g. `"1.50"`.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    /// Indented with two spaces, `"key": value`.
    public func pretty(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.pretty(indent: indent + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { inner + Self.quote($0.key) + ": " + $0.value.pretty(indent: indent + 1) }
                .joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// A JSON string literal.
    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// A scalar from untyped text: booleans and canonical numbers become typed, everything
    /// else stays a string. `"00123"` stays a string so ZIP codes and ids survive.
    static func inferred(_ raw: String) -> JSONValue {
        let t = raw.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: break
        }
        if JSONParser.isCanonicalNumber(t) { return .number(t) }
        return .string(raw)
    }
}

/// Strict RFC 8259 parser producing `JSONValue`.
struct JSONParser {
    struct Failure: Error {}

    private let bytes: [UInt8]
    private var i = 0

    static func parse(_ text: String) -> JSONValue? {
        var p = JSONParser(bytes: Array(text.utf8))
        do {
            p.skipSpace()
            let v = try p.value()
            p.skipSpace()
            return p.i == p.bytes.count ? v : nil
        } catch {
            return nil
        }
    }

    /// Whether `s` is a JSON number without leading zeros (`12`, `-0.5`, `1e9`).
    static func isCanonicalNumber(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        var p = JSONParser(bytes: Array(s.utf8))
        guard (try? p.number()) != nil else { return false }
        return p.i == p.bytes.count
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

    private mutating func skipSpace() {
        while let c = peek, c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 { i += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard peek == b else { throw Failure() }
            i += 1
        }
    }

    private mutating func value() throws -> JSONValue {
        guard let c = peek else { throw Failure() }
        switch c {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func object() throws -> JSONValue {
        i += 1
        var members: [JSONValue.Member] = []
        skipSpace()
        if peek == UInt8(ascii: "}") { i += 1; return .object([]) }
        while true {
            skipSpace()
            guard peek == UInt8(ascii: "\"") else { throw Failure() }
            let key = try string()
            skipSpace()
            try expect(":")
            skipSpace()
            members.append(.init(key, try value()))
            skipSpace()
            if peek == UInt8(ascii: ",") { i += 1; continue }
            try expect("}")
            return .object(members)
        }
    }

    private mutating func array() throws -> JSONValue {
        i += 1
        var items: [JSONValue] = []
        skipSpace()
        if peek == UInt8(ascii: "]") { i += 1; return .array([]) }
        while true {
            skipSpace()
            items.append(try value())
            skipSpace()
            if peek == UInt8(ascii: ",") { i += 1; continue }
            try expect("]")
            return .array(items)
        }
    }

    private mutating func string() throws -> String {
        i += 1
        var out: [UInt8] = []
        while let c = peek {
            i += 1
            switch c {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let e = peek else { throw Failure() }
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), peek == UInt8(ascii: "\\") {
                        i += 1
                        try expect("u")
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw Failure() }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw Failure()
                }
            default:
                guard c >= 0x20 else { throw Failure() }
                out.append(c)
            }
        }
        throw Failure()
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
            throw Failure()
        }
        i += 4
        return v
    }

    private mutating func number() throws -> String {
        let start = i
        func digits() -> Int {
            var n = 0
            while let c = peek, c >= 0x30 && c <= 0x39 { i += 1; n += 1 }
            return n
        }
        if peek == UInt8(ascii: "-") { i += 1 }
        if peek == UInt8(ascii: "0") {
            i += 1
        } else if digits() == 0 {
            throw Failure()
        }
        if peek == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw Failure() }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw Failure() }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }
}
