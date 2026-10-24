import Foundation
import MacToysCore

/// The *Replace with* text, parsed once into pieces that are rendered for each item and match.
///
/// Understood everywhere: `$$` (a literal `$`), file date variables (`$YYYY`, `$MMM`, … see `DateTokens`),
/// photo metadata variables (`$CAMERA_MODEL`, … see `PhotoMetadata`), and when enabled the
/// counters `${start=10,increment=2,padding=4}` (`;` works as separator too) and random values
/// `${rstringalnum=9}`, `${rstringalpha=9}`, `${rstringdigit=9}`, `${ruuidv4}`.
/// With regular expressions: `$1`…`$99`, `$0`/`$&`, `` $` `` and `$'`; the extended flavor adds
/// `${1}`, `${name}`, `$+{name}`, backslash escapes and `\U \L \E \u \l` case conversion.
public struct RenameTemplate: Equatable, Sendable {
    public enum CaseOp: Equatable, Sendable { case upperNext, lowerNext, upperOn, lowerOn, end }
    public enum RandomKind: String, Equatable, Sendable { case alnum, alpha, digit, uuid }

    public enum Piece: Equatable, Sendable {
        case literal(String)
        /// `$n`/`$nn` as written; resolved against the regex's group count when rendering.
        case groupDigits(String)
        case group(Int)
        case namedGroup(String)
        case prefix, suffix
        case counter(start: Int, increment: Int, padding: Int)
        case random(RandomKind, length: Int)
        case date(String)
        case metadata(String)
        case caseOp(CaseOp)
    }

    public let pieces: [Piece]

    public var usesDate: Bool { pieces.contains { if case .date = $0 { true } else { false } } }
    public var usesMetadata: Bool { pieces.contains { if case .metadata = $0 { true } else { false } } }
    public var usesCounter: Bool { pieces.contains { if case .counter = $0 { true } else { false } } }

    public init(_ text: String, regex: Bool, flavor: RegexFlavor, enumerate: Bool, randomize: Bool) {
        pieces = Self.parse(Array(text), regex: regex, extended: regex && flavor == .extended,
                            enumerate: enumerate, randomize: randomize)
    }

    // MARK: Parsing

    private static func parse(_ s: [Character], regex: Bool, extended: Bool, enumerate: Bool, randomize: Bool) -> [Piece] {
        var pieces: [Piece] = []
        var literal = ""
        func emit(_ p: Piece) {
            if !literal.isEmpty { pieces.append(.literal(literal)); literal = "" }
            pieces.append(p)
        }
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" && extended {
                guard i + 1 < s.count else { literal.append(c); i += 1; continue }
                switch s[i + 1] {
                case "U": emit(.caseOp(.upperOn))
                case "L": emit(.caseOp(.lowerOn))
                case "E": emit(.caseOp(.end))
                case "u": emit(.caseOp(.upperNext))
                case "l": emit(.caseOp(.lowerNext))
                default: literal.append(s[i + 1])
                }
                i += 2
                continue
            }
            guard c == "$", i + 1 < s.count else { literal.append(c); i += 1; continue }
            let n = s[i + 1]
            if n == "$" { literal.append("$"); i += 2; continue }
            if n == "{", let close = s[(i + 2)...].firstIndex(of: "}") {
                let body = String(s[(i + 2)..<close])
                if let piece = brace(body, regex: regex, extended: extended, enumerate: enumerate, randomize: randomize) {
                    emit(piece)
                } else {
                    literal += "${" + body + "}"
                }
                i = close + 1
                continue
            }
            if extended, n == "+", i + 2 < s.count, s[i + 2] == "{", let close = s[(i + 3)...].firstIndex(of: "}") {
                let name = String(s[(i + 3)..<close])
                if isIdentifier(name) { emit(.namedGroup(name)); i = close + 1; continue }
            }
            if regex {
                if n.isASCII, n.isNumber {
                    var digits = String(n)
                    if i + 2 < s.count, s[i + 2].isASCII, s[i + 2].isNumber { digits.append(s[i + 2]) }
                    emit(.groupDigits(digits))
                    i += 1 + digits.count
                    continue
                }
                switch n {
                case "&": emit(.group(0)); i += 2; continue
                case "`": emit(.prefix); i += 2; continue
                case "'": emit(.suffix); i += 2; continue
                default: break
                }
            }
            let rest = s[(i + 1)...]
            if let name = PhotoMetadata.match(String(rest.prefix(PhotoMetadata.longestToken))) {
                emit(.metadata(name))
                i += 1 + name.count
                continue
            }
            if let token = DateTokens.match(String(rest.prefix(4))) {
                emit(.date(token))
                i += 1 + token.count
                continue
            }
            literal.append("$")
            i += 1
        }
        if !literal.isEmpty { pieces.append(.literal(literal)) }
        return pieces
    }

    /// The meaning of `${body}`, or nil to keep it as text.
    private static func brace(_ body: String, regex: Bool, extended: Bool, enumerate: Bool, randomize: Bool) -> Piece? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if enumerate, let counter = counter(trimmed) { return counter }
        if randomize, let random = random(trimmed) { return random }
        if regex, !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(trimmed) {
            return .group(n)
        }
        if extended, isIdentifier(trimmed) { return .namedGroup(trimmed) }
        return nil
    }

    /// `""`, `start=1`, `padding=3,increment=2` (or `;`-separated).
    static func counter(_ body: String) -> Piece? {
        var start = 0, increment = 1, padding = 0
        guard !body.isEmpty else { return .counter(start: 0, increment: 1, padding: 0) }
        for part in body.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let value = Int(kv[1]) else { return nil }
            switch kv[0].lowercased() {
            case "start": start = value
            case "increment": increment = value
            case "padding": padding = max(0, min(value, 64))
            default: return nil
            }
        }
        return .counter(start: start, increment: increment, padding: padding)
    }

    static func random(_ body: String) -> Piece? {
        if body.lowercased() == "ruuidv4" { return .random(.uuid, length: 36) }
        let kv = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard kv.count == 2, let n = Int(kv[1]), n >= 0 else { return nil }
        let length = min(n, 255)
        switch kv[0].lowercased() {
        case "rstringalnum": return .random(.alnum, length: length)
        case "rstringalpha": return .random(.alpha, length: length)
        case "rstringdigit": return .random(.digit, length: length)
        default: return nil
        }
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return s.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    // MARK: Rendering

    /// Per-item values the pieces draw from.
    public struct Context {
        public var counterIndex: Int
        public var date: Date?
        public var metadata: [String: String]
        public var random: RandomSource

        public init(counterIndex: Int = 0, date: Date? = nil, metadata: [String: String] = [:],
                    random: RandomSource = RandomSource(seed: 0)) {
            self.counterIndex = counterIndex
            self.date = date
            self.metadata = metadata
            self.random = random
        }
    }

    /// The replacement for one match. `match` is nil for plain-text search; `source` is the searched text.
    public func render(match: NSTextCheckingResult?, in source: NSString, context: inout Context) -> String {
        var out = ""
        var mode: CaseOp?
        var oneShot: CaseOp?
        func put(_ text: String) {
            guard mode != nil || oneShot != nil else { out += text; return }
            for ch in text {
                if let o = oneShot {
                    out += o == .upperNext ? ch.uppercased() : ch.lowercased()
                    oneShot = nil
                } else if mode == .upperOn {
                    out += ch.uppercased()
                } else if mode == .lowerOn {
                    out += ch.lowercased()
                } else {
                    out.append(ch)
                }
            }
        }
        func group(_ n: Int) -> String? {
            guard let match, n < match.numberOfRanges else { return nil }
            let r = match.range(at: n)
            return r.location == NSNotFound ? "" : source.substring(with: r)
        }
        for piece in pieces {
            switch piece {
            case .literal(let s): put(s)
            case .group(let n): put(group(n) ?? "")
            case .groupDigits(let d):
                let groups = (match?.numberOfRanges ?? 1) - 1
                if d.count == 2, let n = Int(d), n <= groups, n > 0 { put(group(n) ?? "") }
                else if let n = Int(String(d.prefix(1))), n <= groups { put((group(n) ?? "") + d.dropFirst()) }
                else { put("$" + d) }
            case .namedGroup(let name):
                if let match {
                    let r = match.range(withName: name)
                    put(r.location == NSNotFound ? "" : source.substring(with: r))
                }
            case .prefix:
                if let match { put(source.substring(to: match.range.location)) }
            case .suffix:
                if let match { put(source.substring(from: NSMaxRange(match.range))) }
            case .counter(let start, let increment, let padding):
                put(Self.formatCounter(start + context.counterIndex * increment, padding: padding))
            case .random(let kind, let length):
                put(context.random.string(kind, length: length))
            case .date(let token):
                if let date = context.date { put(DateTokens.value(of: token, date: date)) }
            case .metadata(let name):
                put(context.metadata[name] ?? "")
            case .caseOp(let op):
                switch op {
                case .upperNext, .lowerNext: oneShot = op
                case .upperOn, .lowerOn: mode = op
                case .end: mode = nil
                }
            }
        }
        return out
    }

    static func formatCounter(_ value: Int, padding: Int) -> String {
        let digits = String(value.magnitude)
        let padded = digits.count >= padding ? digits : String(repeating: "0", count: padding - digits.count) + digits
        return value < 0 ? "-" + padded : padded
    }
}

/// Deterministic random values, so the preview shows exactly what Apply will write.
public struct RandomSource: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// SplitMix64.
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    private static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    private static let digits = Array("0123456789")

    public mutating func string(_ kind: RenameTemplate.RandomKind, length: Int) -> String {
        if kind == .uuid { return uuid() }
        let alphabet: [Character]
        switch kind {
        case .alnum: alphabet = Self.upper + Self.lower + Self.digits
        case .alpha: alphabet = Self.upper + Self.lower
        default: alphabet = Self.digits
        }
        var s = ""
        for _ in 0..<length { s.append(alphabet[Int(next() % UInt64(alphabet.count))]) }
        return s
    }

    /// A version 4 UUID, lowercase.
    public mutating func uuid() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in stride(from: 0, to: 16, by: 8) {
            let v = next()
            for j in 0..<8 { bytes[i + j] = UInt8(truncatingIfNeeded: v >> (8 * j)) }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        return String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-"
            + String(a[16..<20]) + "-" + String(a[20..<32])
    }
}
