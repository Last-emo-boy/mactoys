import Foundation

/// Re-indents or minifies JSON text without parsing it into dictionaries, so key order,
/// number spelling and string escapes stay exactly as written.
public enum JSONFormatter {
    /// Two-space indentation, `"key": value`, empty containers as `{}` and `[]`. Nil when the
    /// text is not valid JSON.
    public static func pretty(_ text: String, indent: Int = 2) -> String? {
        var writer = Writer(indentUnit: String(repeating: " ", count: indent), pretty: true)
        return run(text, &writer)
    }

    /// No whitespace outside strings. Nil when the text is not valid JSON.
    public static func minify(_ text: String) -> String? {
        var writer = Writer(indentUnit: "", pretty: false)
        return run(text, &writer)
    }

    /// Whether the text is a JSON object or array (the shapes worth formatting).
    public static func isContainer(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
        return minify(text) != nil
    }

    private static func run(_ text: String, _ writer: inout Writer) -> String? {
        var parser = Parser(Array(text.unicodeScalars))
        parser.skipWhitespace()
        guard parser.value(&writer), parser.atEndAfterWhitespace() else { return nil }
        return writer.out
    }

    private struct Writer {
        let indentUnit: String
        let pretty: Bool
        var out = ""
        var depth = 0

        mutating func newline() {
            guard pretty else { return }
            out += "\n" + String(repeating: indentUnit, count: depth)
        }

        mutating func raw(_ s: String) { out += s }
        mutating func colon() { out += pretty ? ": " : ":" }
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        /// Guards against stack exhaustion on pathological input.
        var nesting = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var current: Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func skipWhitespace() {
            while let c = current, c == " " || c == "\n" || c == "\r" || c == "\t" { i += 1 }
        }

        mutating func atEndAfterWhitespace() -> Bool {
            skipWhitespace()
            return i == s.count
        }

        mutating func value(_ w: inout Writer) -> Bool {
            guard let c = current else { return false }
            switch c {
            case "{": return container(&w, open: "{", close: "}", keyed: true)
            case "[": return container(&w, open: "[", close: "]", keyed: false)
            case "\"":
                guard let str = string() else { return false }
                w.raw(str)
                return true
            case "t": return literal("true", &w)
            case "f": return literal("false", &w)
            case "n": return literal("null", &w)
            default: return number(&w)
            }
        }

        mutating func container(_ w: inout Writer, open: Unicode.Scalar, close: Unicode.Scalar, keyed: Bool) -> Bool {
            nesting += 1
            defer { nesting -= 1 }
            guard nesting < 512 else { return false }
            i += 1
            w.raw(String(open))
            skipWhitespace()
            if current == close {
                i += 1
                w.raw(String(close))
                return true
            }
            w.depth += 1
            while true {
                w.newline()
                if keyed {
                    guard current == "\"", let key = string() else { return false }
                    w.raw(key)
                    skipWhitespace()
                    guard current == ":" else { return false }
                    i += 1
                    w.colon()
                    skipWhitespace()
                }
                guard value(&w) else { return false }
                skipWhitespace()
                if current == "," {
                    i += 1
                    w.raw(",")
                    skipWhitespace()
                    continue
                }
                guard current == close else { return false }
                i += 1
                w.depth -= 1
                w.newline()
                w.raw(String(close))
                return true
            }
        }

        /// A string token, returned verbatim (quotes and escapes included) after validation.
        mutating func string() -> String? {
            let start = i
            i += 1
            while let c = current {
                if c == "\"" {
                    i += 1
                    var out = ""
                    out.unicodeScalars.append(contentsOf: s[start..<i])
                    return out
                }
                if c.value < 0x20 { return nil }
                if c == "\\" {
                    i += 1
                    guard let e = current else { return nil }
                    switch e {
                    case "\"", "\\", "/", "b", "f", "n", "r", "t": i += 1
                    case "u":
                        for _ in 0..<4 {
                            i += 1
                            guard let h = current, h.properties.isASCIIHexDigit else { return nil }
                        }
                        i += 1
                    default: return nil
                    }
                } else {
                    i += 1
                }
            }
            return nil
        }

        mutating func literal(_ word: String, _ w: inout Writer) -> Bool {
            let scalars = Array(word.unicodeScalars)
            guard i + scalars.count <= s.count, Array(s[i..<(i + scalars.count)]) == scalars else { return false }
            i += scalars.count
            w.raw(word)
            return true
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
        mutating func number(_ w: inout Writer) -> Bool {
            let start = i
            if current == "-" { i += 1 }
            guard let first = current, first.isASCII, ("0"..."9").contains(first) else { return false }
            if first == "0" { i += 1 } else { digits() }
            if current == "." {
                i += 1
                guard digits() else { return false }
            }
            if current == "e" || current == "E" {
                i += 1
                if current == "+" || current == "-" { i += 1 }
                guard digits() else { return false }
            }
            var out = ""
            out.unicodeScalars.append(contentsOf: s[start..<i])
            w.raw(out)
            return true
        }

        @discardableResult
        mutating func digits() -> Bool {
            let start = i
            while let c = current, c.isASCII, ("0"..."9").contains(c) { i += 1 }
            return i > start
        }
    }
}
