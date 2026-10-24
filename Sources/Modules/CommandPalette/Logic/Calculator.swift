import Foundation

/// Why an expression could not be evaluated.
enum CalcError: Error, Equatable, LocalizedError {
    case empty
    case unexpectedToken(String)
    case unexpectedEnd
    case unknownFunction(String)
    case unknownIdentifier(String)
    case argumentCount(String, expected: String)
    case divisionByZero
    case domain(String)
    case invalidNumber(String)
    case overflow

    var errorDescription: String? {
        switch self {
        case .empty: "Type an expression"
        case .unexpectedToken(let t): "Unexpected “\(t)”"
        case .unexpectedEnd: "The expression is incomplete"
        case .unknownFunction(let f): "Unknown function “\(f)”"
        case .unknownIdentifier(let i): "Unknown name “\(i)”"
        case .argumentCount(let f, let n): "\(f) takes \(n)"
        case .divisionByZero: "Division by zero"
        case .domain(let f): "\(f) is not defined for this value"
        case .invalidNumber(let n): "Invalid number “\(n)”"
        case .overflow: "The result is too large"
        }
    }
}

/// Which base a result should be shown in (`255 in hex`).
enum NumberBase: String, Codable, CaseIterable, Sendable {
    case decimal, hex, binary, octal

    var radix: Int {
        switch self {
        case .decimal: 10
        case .hex: 16
        case .binary: 2
        case .octal: 8
        }
    }

    var prefix: String {
        switch self {
        case .decimal: ""
        case .hex: "0x"
        case .binary: "0b"
        case .octal: "0o"
        }
    }

    var title: String {
        switch self {
        case .decimal: "Decimal"
        case .hex: "Hexadecimal"
        case .binary: "Binary"
        case .octal: "Octal"
        }
    }
}

/// Angle unit used by the trigonometric functions.
enum AngleUnit: String, Codable, CaseIterable, Sendable {
    case radians, degrees, gradians

    var title: String { rawValue.capitalized }

    /// Factor that converts this unit to radians.
    var toRadians: Double {
        switch self {
        case .radians: 1
        case .degrees: .pi / 180
        case .gradians: .pi / 200
        }
    }
}

/// A recursive-descent expression evaluator.
///
/// Supports `+ - * / × ÷ ^ **`, `%` (modulo between operands, percent after one: `200 + 10%` = 220),
/// `!` factorial, parentheses, implicit multiplication (`2pi`, `2(3+4)`, `(1+2)(3+4)`),
/// hex/binary/octal literals (`0xFF`, `0b1010`, `0o17`), scientific notation (`1.5e3`),
/// constants (`pi π e tau phi`) and functions (`sin cos tan asin acos atan sinh cosh tanh
/// asinh acosh atanh sqrt cbrt log ln log2 logn exp abs round floor ceil trunc sign min max
/// sum avg pow root hypot atan2 mod gcd lcm fact rand randi`).
/// A trailing `in hex` / `to bin` / `as oct` / `in dec` selects the output base.
struct Calculator {
    struct Result: Equatable {
        var value: Double
        /// The base requested with a trailing `in hex`-style suffix.
        var base: NumberBase
        /// True when the input was a bare number (or `e`): not worth showing as a calculation.
        var isTrivial: Bool
    }

    var angleUnit: AngleUnit = .radians
    var random: () -> Double = { Double.random(in: 0..<1) }

    func evaluate(_ input: String) throws -> Result {
        var trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("=") { trimmed.removeLast() }
        let (body, base) = Self.splitBaseSuffix(trimmed)
        var lexer = Lexer(body)
        let tokens = try lexer.tokens()
        guard !tokens.isEmpty else { throw CalcError.empty }
        var parser = Parser(tokens: tokens)
        let node = try parser.parse()
        let value = try eval(node)
        guard !value.isNaN else { throw CalcError.domain("The expression") }
        guard value.isFinite else { throw CalcError.overflow }
        return Result(value: value == 0 ? 0 : value, base: base, isTrivial: node.isTrivial)
    }

    /// Strips a trailing ` in hex` / ` to binary` / ` as oct` / ` in dec`.
    static func splitBaseSuffix(_ input: String) -> (String, NumberBase) {
        let names: [(String, NumberBase)] = [
            ("hexadecimal", .hex), ("hex", .hex), ("binary", .binary), ("bin", .binary),
            ("octal", .octal), ("oct", .octal), ("decimal", .decimal), ("dec", .decimal),
        ]
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        for connector in [" in ", " to ", " as "] {
            for (name, base) in names where lower.hasSuffix(connector + name) {
                let cut = lower.count - (connector.count + name.count)
                return (String(input.trimmingCharacters(in: .whitespaces).prefix(cut)), base)
            }
        }
        return (input, .decimal)
    }

    // MARK: Evaluation

    private func eval(_ node: Node) throws -> Double {
        switch node {
        case .number(let v):
            return v
        case .constant(let name):
            return Self.constants[name] ?? 0
        case .negate(let n):
            return -(try eval(n))
        case .percent(let n):
            return try eval(n) / 100
        case .factorial(let n):
            return try factorial(eval(n))
        case .binary(let op, let lhs, let rhs):
            let a = try eval(lhs)
            // `a + b%` and `a - b%` take the percentage of `a`.
            if case .percent(let p) = rhs, op == "+" || op == "-" {
                let pct = try eval(p) / 100
                return op == "+" ? a * (1 + pct) : a * (1 - pct)
            }
            let b = try eval(rhs)
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/":
                guard b != 0 else { throw CalcError.divisionByZero }
                return a / b
            case "%":
                guard b != 0 else { throw CalcError.divisionByZero }
                return a.truncatingRemainder(dividingBy: b)
            case "^":
                let r = Foundation.pow(a, b)
                if r.isNaN { throw CalcError.domain("^") }
                return r
            default: throw CalcError.unexpectedToken(String(op))
            }
        case .call(let name, let args):
            return try call(name, args.map(eval))
        }
    }

    static let constants: [String: Double] = [
        "pi": .pi, "e": M_E, "tau": 2 * .pi, "phi": (1 + 5.0.squareRoot()) / 2,
    ]

    private func factorial(_ n: Double) throws -> Double {
        guard n >= 0 else { throw CalcError.domain("!") }
        if n == n.rounded() {
            guard n <= 170 else { throw CalcError.overflow }
            var r = 1.0
            var i = 2.0
            while i <= n { r *= i; i += 1 }
            return r
        }
        return tgamma(n + 1)
    }

    private func call(_ name: String, _ a: [Double]) throws -> Double {
        func arity(_ n: Int) throws {
            guard a.count == n else {
                throw CalcError.argumentCount(name, expected: n == 1 ? "1 argument" : "\(n) arguments")
            }
        }
        func checked(_ v: Double) throws -> Double {
            if v.isNaN { throw CalcError.domain(name) }
            return v
        }
        let toRad = angleUnit.toRadians
        switch name {
        case "sin": try arity(1); return Foundation.sin(a[0] * toRad)
        case "cos": try arity(1); return Foundation.cos(a[0] * toRad)
        case "tan": try arity(1); return Foundation.tan(a[0] * toRad)
        case "asin", "arcsin": try arity(1); return try checked(Foundation.asin(a[0])) / toRad
        case "acos", "arccos": try arity(1); return try checked(Foundation.acos(a[0])) / toRad
        case "atan", "arctan": try arity(1); return Foundation.atan(a[0]) / toRad
        case "atan2": try arity(2); return Foundation.atan2(a[0], a[1]) / toRad
        case "sinh": try arity(1); return Foundation.sinh(a[0])
        case "cosh": try arity(1); return Foundation.cosh(a[0])
        case "tanh": try arity(1); return Foundation.tanh(a[0])
        case "asinh", "arsinh", "arcsinh": try arity(1); return Foundation.asinh(a[0])
        case "acosh", "arcosh", "arccosh": try arity(1); return try checked(Foundation.acosh(a[0]))
        case "atanh", "artanh", "arctanh": try arity(1); return try checked(Foundation.atanh(a[0]))
        case "sqrt":
            try arity(1)
            guard a[0] >= 0 else { throw CalcError.domain("sqrt") }
            return a[0].squareRoot()
        case "cbrt": try arity(1); return Foundation.cbrt(a[0])
        case "root":
            try arity(2)
            guard a[1] != 0 else { throw CalcError.divisionByZero }
            if a[0] < 0, a[1].truncatingRemainder(dividingBy: 2).magnitude == 1 {
                return -Foundation.pow(-a[0], 1 / a[1])
            }
            return try checked(Foundation.pow(a[0], 1 / a[1]))
        case "log", "log10":
            try arity(1)
            guard a[0] > 0 else { throw CalcError.domain(name) }
            return Foundation.log10(a[0])
        case "ln":
            try arity(1)
            guard a[0] > 0 else { throw CalcError.domain("ln") }
            return Foundation.log(a[0])
        case "log2":
            try arity(1)
            guard a[0] > 0 else { throw CalcError.domain("log2") }
            return Foundation.log2(a[0])
        case "logn":
            try arity(2)
            guard a[0] > 0, a[1] > 0, a[1] != 1 else { throw CalcError.domain("logn") }
            return Foundation.log(a[0]) / Foundation.log(a[1])
        case "exp": try arity(1); return Foundation.exp(a[0])
        case "abs": try arity(1); return Swift.abs(a[0])
        case "floor": try arity(1); return a[0].rounded(.down)
        case "ceil": try arity(1); return a[0].rounded(.up)
        case "trunc": try arity(1); return a[0].rounded(.towardZero)
        case "round":
            guard a.count == 1 || a.count == 2 else { throw CalcError.argumentCount(name, expected: "1 or 2 arguments") }
            if a.count == 2 {
                let f = Foundation.pow(10, a[1].rounded())
                return (a[0] * f).rounded() / f
            }
            return a[0].rounded()
        case "sign", "sgn": try arity(1); return a[0] > 0 ? 1 : a[0] < 0 ? -1 : 0
        case "min", "max", "sum", "avg", "mean":
            guard !a.isEmpty else { throw CalcError.argumentCount(name, expected: "at least 1 argument") }
            switch name {
            case "min": return a.min() ?? 0
            case "max": return a.max() ?? 0
            case "sum": return a.reduce(0, +)
            default: return a.reduce(0, +) / Double(a.count)
            }
        case "pow": try arity(2); return try checked(Foundation.pow(a[0], a[1]))
        case "hypot": try arity(2); return Foundation.hypot(a[0], a[1])
        case "mod":
            try arity(2)
            guard a[1] != 0 else { throw CalcError.divisionByZero }
            return a[0].truncatingRemainder(dividingBy: a[1])
        case "gcd", "lcm":
            try arity(2)
            guard a.allSatisfy({ $0 == $0.rounded() && Swift.abs($0) < 9e15 }) else { throw CalcError.domain(name) }
            let x = Int64(Swift.abs(a[0])), y = Int64(Swift.abs(a[1]))
            let g = Self.gcd(x, y)
            if name == "gcd" { return Double(g) }
            return g == 0 ? 0 : Double(x / g * y)
        case "fact", "factorial": try arity(1); return try factorial(a[0])
        case "rand": try arity(0); return random()
        case "randi":
            try arity(1)
            guard a[0] >= 1 else { throw CalcError.domain("randi") }
            return (random() * a[0].rounded(.down)).rounded(.down)
        default:
            throw CalcError.unknownFunction(name)
        }
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (x, y) = (a, b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    static let functions: Set<String> = [
        "sin", "cos", "tan", "asin", "arcsin", "acos", "arccos", "atan", "arctan", "atan2", "sinh", "cosh", "tanh",
        "asinh", "arsinh", "arcsinh", "acosh", "arcosh", "arccosh", "atanh", "artanh", "arctanh", "sqrt", "cbrt",
        "root", "log", "log10", "ln", "log2", "logn", "exp", "abs", "floor", "ceil", "trunc", "round", "sign", "sgn",
        "min", "max", "sum", "avg", "mean", "pow", "hypot", "mod", "gcd", "lcm", "fact", "factorial", "rand", "randi",
    ]
}

// MARK: - Syntax tree

private indirect enum Node {
    case number(Double)
    case constant(String)
    case negate(Node)
    case percent(Node)
    case factorial(Node)
    case binary(Character, Node, Node)
    case call(String, [Node])

    var isTrivial: Bool {
        switch self {
        case .number: true
        case .constant(let c): c == "e"
        case .negate(let n): n.isTrivial
        default: false
        }
    }
}

// MARK: - Lexer

private enum Token: Equatable {
    case number(Double, text: String)
    case ident(String)
    case symbol(Character)

    var text: String {
        switch self {
        case .number(_, let t): t
        case .ident(let s): s
        case .symbol(let c): String(c)
        }
    }

    /// Whether this token can begin an operand (for implicit multiplication).
    var startsOperand: Bool {
        switch self {
        case .number: true
        case .ident(let s): s != "mod"
        case .symbol(let c): c == "(" || c == "√"
        }
    }
}

private struct Lexer {
    let chars: [Character]
    var i = 0

    init(_ input: String) {
        let replaced = input
            .replacingOccurrences(of: "**", with: "^")
            .map { c -> Character in
                switch c {
                case "×", "·", "∙", "⋅": "*"
                case "÷", "∕": "/"
                case "−", "–", "—": "-"
                default: c
                }
            }
        chars = replaced
    }

    mutating func tokens() throws -> [Token] {
        var out: [Token] = []
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                out.append(try number())
            } else if c == "π" {
                out.append(.ident("pi")); i += 1
            } else if c == "τ" {
                out.append(.ident("tau")); i += 1
            } else if c == "φ" {
                out.append(.ident("phi")); i += 1
            } else if c.isLetter || c == "_" {
                let ident = identifier()
                // "15% of 80" reads as 15% × 80.
                out.append(ident == .ident("of") ? .symbol("*") : ident)
            } else if "+-*/^%!(),√".contains(c) {
                out.append(.symbol(c)); i += 1
            } else {
                throw CalcError.unexpectedToken(String(c))
            }
        }
        return out
    }

    private mutating func identifier() -> Token {
        let start = i
        while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
        return .ident(String(chars[start..<i]).lowercased())
    }

    private mutating func number() throws -> Token {
        let start = i
        if chars[i] == "0", i + 1 < chars.count, let radix = ["x": 16, "X": 16, "b": 2, "B": 2, "o": 8, "O": 8][chars[i + 1]] {
            i += 2
            let digitsStart = i
            while i < chars.count, chars[i].isHexDigit || chars[i] == "_" { i += 1 }
            let digits = String(chars[digitsStart..<i]).replacingOccurrences(of: "_", with: "")
            let text = String(chars[start..<i])
            guard !digits.isEmpty, let v = UInt64(digits, radix: radix) else { throw CalcError.invalidNumber(text) }
            return .number(Double(v), text: text)
        }
        while i < chars.count, chars[i].isNumber || chars[i] == "_" { i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isNumber || chars[i] == "_" { i += 1 }
        }
        // Exponent only when digits follow, so `2e` stays 2·e.
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            if j < chars.count, chars[j].isNumber {
                i = j
                while i < chars.count, chars[i].isNumber { i += 1 }
            }
        }
        let text = String(chars[start..<i])
        guard let v = Double(text.replacingOccurrences(of: "_", with: "")) else { throw CalcError.invalidNumber(text) }
        return .number(v, text: text)
    }
}

// MARK: - Parser

private struct Parser {
    let tokens: [Token]
    var i = 0

    init(tokens: [Token]) { self.tokens = tokens }

    var peek: Token? { i < tokens.count ? tokens[i] : nil }

    func isSymbol(_ c: Character, at index: Int? = nil) -> Bool {
        let k = index ?? i
        guard k < tokens.count, case .symbol(let s) = tokens[k] else { return false }
        return s == c
    }

    mutating func parse() throws -> Node {
        let node = try additive()
        if let extra = peek { throw CalcError.unexpectedToken(extra.text) }
        return node
    }

    mutating func additive() throws -> Node {
        var node = try multiplicative()
        while let t = peek, case .symbol(let c) = t, c == "+" || c == "-" {
            i += 1
            node = .binary(c, node, try multiplicative())
        }
        return node
    }

    mutating func multiplicative() throws -> Node {
        var node = try implicitProduct()
        while let t = peek {
            if case .symbol(let c) = t, c == "*" || c == "/" || c == "%" {
                i += 1
                node = .binary(c, node, try implicitProduct())
            } else if case .ident("mod") = t {
                i += 1
                node = .binary("%", node, try implicitProduct())
            } else {
                break
            }
        }
        return node
    }

    /// `2pi`, `2(3+4)`, `(1+2)(3+4)`: juxtaposition multiplies and binds tighter than `*` and `/`,
    /// so `1/2pi` is 1/(2π). Two plain numbers in a row are an error.
    mutating func implicitProduct() throws -> Node {
        var node = try unary()
        while let t = peek, t.startsOperand {
            if case .number = t, case .number = tokens[i - 1] { throw CalcError.unexpectedToken(t.text) }
            node = .binary("*", node, try power())
        }
        return node
    }

    mutating func unary() throws -> Node {
        if isSymbol("-") { i += 1; return .negate(try unary()) }
        if isSymbol("+") { i += 1; return try unary() }
        return try power()
    }

    /// Right-associative and tighter than unary minus on its left: `-2^2` = -4, `2^3^2` = 512.
    mutating func power() throws -> Node {
        let base = try postfix()
        if isSymbol("^") {
            i += 1
            return .binary("^", base, try unary())
        }
        return base
    }

    mutating func postfix() throws -> Node {
        var node = try primary()
        while true {
            if isSymbol("!") {
                i += 1
                node = .factorial(node)
            } else if isSymbol("%"), !(i + 1 < tokens.count && tokens[i + 1].startsOperand) {
                // A `%` not followed by an operand is a percentage; otherwise it is modulo.
                i += 1
                node = .percent(node)
            } else {
                return node
            }
        }
    }

    mutating func primary() throws -> Node {
        guard let t = peek else { throw CalcError.unexpectedEnd }
        switch t {
        case .number(let v, _):
            i += 1
            return .number(v)
        case .symbol("("):
            i += 1
            let inner = try additive()
            guard isSymbol(")") else { throw peek.map { CalcError.unexpectedToken($0.text) } ?? .unexpectedEnd }
            i += 1
            return inner
        case .symbol("√"):
            i += 1
            return .call("sqrt", [try postfix()])
        case .ident(let name):
            i += 1
            if Calculator.functions.contains(name) {
                if isSymbol("(") {
                    i += 1
                    var args: [Node] = []
                    if !isSymbol(")") {
                        args.append(try additive())
                        while isSymbol(",") {
                            i += 1
                            args.append(try additive())
                        }
                    }
                    guard isSymbol(")") else { throw peek.map { CalcError.unexpectedToken($0.text) } ?? .unexpectedEnd }
                    i += 1
                    return .call(name, args)
                }
                // `sqrt 16`, `sin pi`: a function applied to the next operand.
                return .call(name, [try postfix()])
            }
            if Calculator.constants[name] != nil { return .constant(name) }
            throw isSymbol("(") ? CalcError.unknownFunction(name) : CalcError.unknownIdentifier(name)
        case .symbol(let c):
            throw CalcError.unexpectedToken(String(c))
        }
    }
}

// MARK: - Formatting

/// Formats calculator results for display and copying.
enum CalcFormatter {
    /// Up to 15 significant digits, no grouping, trailing zeros trimmed: `141.42135623731`.
    static func decimal(_ x: Double) -> String {
        if x == 0 { return "0" }
        var s = String(format: "%.15g", x)
        if let e = s.firstIndex(where: { $0 == "e" }) {
            let mantissa = trimZeros(String(s[..<e]))
            var exp = String(s[s.index(after: e)...])
            if exp.hasPrefix("+") { exp.removeFirst() }
            if exp.hasPrefix("-0") { exp = "-" + exp.dropFirst(2) } else if exp.hasPrefix("0") { exp.removeFirst() }
            s = "\(mantissa)e\(exp)"
        } else if s.contains(".") {
            s = trimZeros(s)
        }
        return s
    }

    /// `1.4142135623731 × 10²`.
    static func scientific(_ x: Double) -> String {
        if x == 0 { return "0" }
        let s = String(format: "%.14e", x)
        guard let e = s.firstIndex(of: "e"), let exp = Int(s[s.index(after: e)...]) else { return decimal(x) }
        let mantissa = trimZeros(String(s[..<e]))
        return exp == 0 ? mantissa : "\(mantissa) × 10\(superscript(exp))"
    }

    /// `0xFF`, `0b1010`, `0o17` for integral values that fit in 64 bits (two's complement for negatives).
    static func integer(_ x: Double, base: NumberBase) -> String? {
        guard x == x.rounded(), Swift.abs(x) < 9.2e18 else { return nil }
        if base == .decimal { return String(Int64(x)) }
        let v = Int64(x)
        let digits = v < 0 ? String(UInt64(bitPattern: v), radix: base.radix) : String(v, radix: base.radix)
        return base.prefix + (base == .hex ? digits.uppercased() : digits)
    }

    private static func trimZeros(_ s: String) -> String {
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    static func superscript(_ n: Int) -> String {
        let map: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
                                           "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻"]
        return String(String(n).map { map[$0] ?? $0 })
    }
}
