import Foundation

/// Evaluates arithmetic written in prose: `1,280 × 0.85 + 64`, `sqrt(2) * 100`, `2^10`,
/// `200 + 15%`, `15% of 80`, `(3 + 4) / 2 =`.
///
/// Operators: `+ - * × · / ÷ ^ mod`, postfix `%` and `!`, implicit multiplication before
/// `(` and names (`2pi`, `3(4 + 1)`). Functions: sqrt cbrt abs sin cos tan asin acos atan
/// sinh cosh tanh ln log log2 log10 exp round floor ceil min max pow. Constants: pi π e tau τ.
public enum ArithmeticEvaluator {
    public enum Failure: Error, Equatable {
        case syntax
        case divisionByZero
        case domain
        case unknownName(String)
    }

    /// The value when `text` reads as a calculation; nil for plain numbers, dates, ranges,
    /// version numbers, phone numbers and anything that doesn't parse.
    public static func evaluateIfExpression(_ text: String) -> Double? {
        let source = stripped(text)
        guard (2...200).contains(source.count), source.contains(where: \.isNumber),
              !looksLikeIdentifierNumber(source) else { return nil }
        guard let result = try? run(source), result.usedOperation, result.value.isFinite else { return nil }
        return result.value
    }

    /// Evaluates `text` (a trailing `=` is ignored).
    public static func evaluate(_ text: String) throws -> Double {
        try run(stripped(text)).value
    }

    /// Plain text for inserting: integers without decimals, otherwise up to 12 significant
    /// digits with a `.` decimal point and no grouping.
    public static func canonical(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.12g", value)
    }

    /// Grouped, locale-aware display of a result.
    public static func display(_ value: Double, locale: Locale = .current) -> String {
        if abs(value) >= 1e15 || (abs(value) < 1e-6 && value != 0) {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(1...10)).locale(locale))
        }
        return value.formatted(.number.precision(.significantDigits(1...12)).locale(locale))
    }

    // MARK: Heuristics

    private static func stripped(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("=") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// `2026-11-04`, `10-20`, `1.2.3`, `11/04/2026`, `555-123-4567`: digit groups joined by
    /// `-`, `/` or `.` without spaces read as dates, ranges and identifiers, not arithmetic.
    /// A single `/` between two numbers (`3/4`) stays a division.
    private static func looksLikeIdentifierNumber(_ s: String) -> Bool {
        let groups = s.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "/" || $0 == "." }
        guard groups.count >= 2, groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        if groups.count == 2 && s.contains("/") { return false }
        if groups.count == 2 && s.contains(".") { return false }
        return true
    }

    // MARK: Parser

    private struct Result {
        var value: Double
        var usedOperation: Bool
    }

    private static func run(_ source: String) throws -> Result {
        var parser = Parser(tokens: try tokenize(source))
        let value = try parser.sum().value
        guard parser.atEnd else { throw Failure.syntax }
        return Result(value: value, usedOperation: parser.usedOperation)
    }

    enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(Character)
    }

    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isASCII && (c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber)) {
                var text = ""
                var sawDot = false
                while i < chars.count {
                    let d = chars[i]
                    if d.isASCII && d.isNumber {
                        text.append(d)
                    } else if d == "." && !sawDot {
                        sawDot = true
                        text.append(d)
                    } else if d == ",", !sawDot, isThousandsGroup(chars, at: i) {
                        // 1,234,567 — grouping, not an argument separator
                    } else if (d == "e" || d == "E"), i + 1 < chars.count,
                              chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                        text.append("e")
                        text.append(chars[i + 1])
                        i += 2
                        while i < chars.count, chars[i].isASCII, chars[i].isNumber { text.append(chars[i]); i += 1 }
                        break
                    } else {
                        break
                    }
                    i += 1
                }
                guard let v = Double(text) else { throw Failure.syntax }
                tokens.append(.number(v))
                continue
            }
            if c.isLetter || c == "_" {
                var name = ""
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    name.append(chars[i])
                    i += 1
                }
                tokens.append(.name(name.lowercased()))
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%", "!", "(", ")", ",": tokens.append(.op(c))
            case "−", "–": tokens.append(.op("-"))
            case "×", "·", "⋅", "∙": tokens.append(.op("*"))
            case "÷", "∕": tokens.append(.op("/"))
            case "π": tokens.append(.name("pi"))
            case "τ": tokens.append(.name("tau"))
            case "√": tokens.append(.name("sqrt"))
            default: throw Failure.syntax
            }
            i += 1
        }
        return tokens
    }

    /// A comma followed by exactly three digits (and not a fourth) inside a number.
    private static func isThousandsGroup(_ chars: [Character], at i: Int) -> Bool {
        for k in 1...3 {
            guard i + k < chars.count, chars[i + k].isASCII, chars[i + k].isNumber else { return false }
        }
        return !(i + 4 < chars.count && chars[i + 4].isNumber)
    }

    private struct Operand {
        var value: Double
        /// The operand is a bare percentage (`15%`), for `a + b%` meaning a plus b percent of a.
        var isPercent = false
    }

    private struct Parser {
        let tokens: [Token]
        var i = 0
        var usedOperation = false

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool { i == tokens.count }
        var current: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func sum() throws -> Operand {
            var left = try product()
            while let t = current, t == .op("+") || t == .op("-") {
                i += 1
                let right = try product()
                usedOperation = true
                let delta = right.isPercent ? left.value * right.value : right.value
                left = Operand(value: t == .op("+") ? left.value + delta : left.value - delta)
            }
            return left
        }

        mutating func product() throws -> Operand {
            var left = try unary()
            var factors = 1
            while let t = current {
                let op: Character
                switch t {
                case .op("*"), .op("/"): op = t == .op("*") ? "*" : "/"; i += 1
                case .name("x"), .name("of"): op = "*"; i += 1
                case .name("mod"): op = "m"; i += 1
                case .op("("), .name: op = "*"     // implicit: 2(3), 2pi, 3 sqrt(4)
                default: return factors == 1 ? left : Operand(value: left.value)
                }
                let right = try unary()
                usedOperation = true
                factors += 1
                switch op {
                case "*": left = Operand(value: left.value * right.value)
                case "/":
                    guard right.value != 0 else { throw Failure.divisionByZero }
                    left = Operand(value: left.value / right.value)
                default:
                    guard right.value != 0 else { throw Failure.divisionByZero }
                    left = Operand(value: left.value.truncatingRemainder(dividingBy: right.value))
                }
            }
            return factors == 1 ? left : Operand(value: left.value)
        }

        mutating func unary() throws -> Operand {
            if current == .op("-") {
                i += 1
                let v = try unary()
                return Operand(value: -v.value, isPercent: v.isPercent)
            }
            if current == .op("+") {
                i += 1
                return try unary()
            }
            return try power()
        }

        mutating func power() throws -> Operand {
            let base = try postfix()
            guard current == .op("^") else { return base }
            i += 1
            let exponent = try unary()
            usedOperation = true
            let v = Foundation.pow(base.value, exponent.value)
            guard v.isFinite else { throw Failure.domain }
            return Operand(value: v)
        }

        mutating func postfix() throws -> Operand {
            var operand = try primary()
            while let t = current {
                if t == .op("%") {
                    // A bare percentage ("grew 50%") is not a calculation by itself.
                    i += 1
                    operand = Operand(value: operand.value / 100, isPercent: true)
                } else if t == .op("!") {
                    i += 1
                    usedOperation = true
                    let n = operand.value
                    guard n >= 0, n == n.rounded(), n <= 170 else { throw Failure.domain }
                    operand = Operand(value: (0..<Int(n)).reduce(1.0) { $0 * Double($1 + 1) })
                } else {
                    break
                }
            }
            return operand
        }

        mutating func primary() throws -> Operand {
            guard let t = current else { throw Failure.syntax }
            i += 1
            switch t {
            case .number(let v):
                return Operand(value: v)
            case .op("("):
                let v = try sum()
                guard current == .op(")") else { throw Failure.syntax }
                i += 1
                return Operand(value: v.value)
            case .name(let name):
                if current == .op("(") {
                    i += 1
                    var args: [Double] = []
                    if current != .op(")") {
                        args.append(try sum().value)
                        while current == .op(",") {
                            i += 1
                            args.append(try sum().value)
                        }
                    }
                    guard current == .op(")") else { throw Failure.syntax }
                    i += 1
                    usedOperation = true
                    return Operand(value: try call(name, args))
                }
                if let constant = Self.constants[name] {
                    return Operand(value: constant)
                }
                if Self.unary[name] != nil {
                    // `sqrt 16`, `√2`: a function applied to the next operand.
                    let arg = try postfix()
                    usedOperation = true
                    return Operand(value: try call(name, [arg.value]))
                }
                throw Failure.unknownName(name)
            default:
                throw Failure.syntax
            }
        }

        static let constants: [String: Double] = ["pi": .pi, "e": M_E, "tau": 2 * .pi]

        static let unary: [String: (Double) -> Double] = [
            "sqrt": { $0.squareRoot() }, "cbrt": { Foundation.cbrt($0) }, "abs": { Swift.abs($0) },
            "sin": { Foundation.sin($0) }, "cos": { Foundation.cos($0) }, "tan": { Foundation.tan($0) },
            "asin": { Foundation.asin($0) }, "acos": { Foundation.acos($0) }, "atan": { Foundation.atan($0) },
            "sinh": { Foundation.sinh($0) }, "cosh": { Foundation.cosh($0) }, "tanh": { Foundation.tanh($0) },
            "ln": { Foundation.log($0) }, "log": { Foundation.log10($0) }, "log10": { Foundation.log10($0) },
            "log2": { Foundation.log2($0) }, "exp": { Foundation.exp($0) },
            "round": { $0.rounded() }, "floor": { $0.rounded(.down) }, "ceil": { $0.rounded(.up) },
        ]

        func call(_ name: String, _ args: [Double]) throws -> Double {
            if let f = Self.unary[name] {
                guard args.count == 1 else { throw Failure.syntax }
                let v = f(args[0])
                guard v.isFinite else { throw Failure.domain }
                return v
            }
            switch name {
            case "min": guard let v = args.min() else { throw Failure.syntax }; return v
            case "max": guard let v = args.max() else { throw Failure.syntax }; return v
            case "pow":
                guard args.count == 2 else { throw Failure.syntax }
                let v = Foundation.pow(args[0], args[1])
                guard v.isFinite else { throw Failure.domain }
                return v
            default: throw Failure.unknownName(name)
            }
        }
    }
}
