import Foundation

/// Converts structured text to JSON: existing JSON is pretty-printed; CSV/TSV, XML, INI or
/// `key=value` lines and YAML are translated; anything else becomes an array of its lines.
public enum JSONConverter {
    public enum Format: Equatable, Sendable {
        case json
        case xml
        /// Delimited rows; `rows` counts records (excluding a header row).
        case delimited(Character, rows: Int)
        case keyValue(keys: Int)
        case yaml
        case lines(Int)

        public var label: String {
            switch self {
            case .json: "JSON"
            case .xml: "XML"
            case .delimited(let d, let rows): "\(d == "\t" ? "TSV" : "CSV") · \(rows) row\(rows == 1 ? "" : "s")"
            case .keyValue(let n): "Key/value · \(n) key\(n == 1 ? "" : "s")"
            case .yaml: "YAML"
            case .lines(let n): "Text · \(n) line\(n == 1 ? "" : "s")"
            }
        }
    }

    /// Pretty-printed JSON for `text`.
    public static func convert(_ text: String) -> String {
        value(for: text).pretty()
    }

    /// What `convert` will treat `text` as.
    public static func detect(_ text: String) -> Format {
        analyze(text).format
    }

    /// The parsed JSON value for `text`.
    public static func value(for text: String) -> JSONValue {
        analyze(text).value
    }

    private static func analyze(_ text: String) -> (format: Format, value: JSONValue) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let v = JSONParser.parse(trimmed) { return (.json, v) }
        if trimmed.hasPrefix("<"), let v = XMLToJSON.convert(trimmed) { return (.xml, v) }
        if let (v, n) = KeyValueToJSON.convert(trimmed) { return (.keyValue(keys: n), v) }
        if let v = YAMLLite.parse(trimmed) { return (.yaml, v) }
        if let (v, d, rows) = CSVToJSON.convert(trimmed) { return (.delimited(d, rows: rows), v) }
        let lines = trimmed.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (.lines(lines.count), .array(lines.map { .string($0) }))
    }
}

// MARK: - CSV / TSV

enum CSVToJSON {
    /// Parses delimited text with a consistent column count on every row. With a header row of
    /// unique names the result is an array of objects, otherwise an array of arrays.
    static func convert(_ text: String) -> (JSONValue, Character, Int)? {
        for delimiter in ["\t", ",", ";", "|"] as [Character] {
            guard let rows = parse(text, delimiter: delimiter), rows.count >= 2,
                  let width = rows.first?.count, width >= 2, rows.allSatisfy({ $0.count == width }) else { continue }
            let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces) }
            if !header.contains(where: \.isEmpty), Set(header).count == header.count,
               !header.contains(where: { JSONParser.isCanonicalNumber($0) }) {
                let objects = rows.dropFirst().map { row in
                    JSONValue.object(zip(header, row).map { .init($0, JSONValue.inferred($1)) })
                }
                return (.array(Array(objects)), delimiter, rows.count - 1)
            }
            return (.array(rows.map { .array($0.map(JSONValue.inferred)) }), delimiter, rows.count)
        }
        return nil
    }

    /// RFC 4180 rows: quoted fields may contain delimiters, `""` and line breaks. Blank lines are skipped.
    static func parse(_ text: String, delimiter: Character) -> [[String]]? {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        var sawDelimiter = false
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && !fieldStarted {
                inQuotes = true
                fieldStarted = true
                field = ""
            } else if c == delimiter {
                row.append(field)
                field = ""
                fieldStarted = false
                sawDelimiter = true
            } else if c == "\n" || c == "\r" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field)
                if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
                row = []
                field = ""
                fieldStarted = false
            } else {
                field.append(c)
                if !c.isWhitespace { fieldStarted = true }
            }
            i += 1
        }
        if inQuotes || !sawDelimiter { return nil }
        return rows
    }
}

// MARK: - XML

/// XML in the Json.NET convention: `@attr` for attributes, `#text` for mixed text,
/// repeated children become arrays, empty elements become null.
final class XMLToJSON: NSObject, XMLParserDelegate {
    private final class Element {
        let name: String
        let attributes: [(String, String)]
        var children: [Element] = []
        var text = ""
        init(name: String, attributes: [(String, String)]) {
            self.name = name
            self.attributes = attributes
        }
    }

    private var stack: [Element] = []
    private var root: Element?

    static func convert(_ text: String) -> JSONValue? {
        let parser = XMLParser(data: Data(text.utf8))
        let delegate = XMLToJSON()
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = delegate.root else { return nil }
        return .object([.init(root.name, json(root))])
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let el = Element(name: elementName, attributes: attributeDict.sorted { $0.key < $1.key })
        stack.last?.children.append(el)
        stack.append(el)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let el = stack.removeLast()
        if stack.isEmpty { root = el }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    private static func json(_ el: Element) -> JSONValue {
        let text = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if el.attributes.isEmpty && el.children.isEmpty {
            return text.isEmpty ? .null : .string(text)
        }
        var members: [JSONValue.Member] = el.attributes.map { .init("@" + $0.0, .string($0.1)) }
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for child in el.children {
            if groups[child.name] == nil { order.append(child.name) }
            groups[child.name, default: []].append(json(child))
        }
        for name in order {
            let values = groups[name] ?? []
            members.append(.init(name, values.count == 1 ? values[0] : .array(values)))
        }
        if !text.isEmpty { members.append(.init("#text", .string(text))) }
        return .object(members)
    }
}

// MARK: - INI / key=value

enum KeyValueToJSON {
    /// INI files, `.env` files and `key=value` lists. Values stay strings, surrounding quotes removed.
    static func convert(_ text: String) -> (JSONValue, Int)? {
        var top: [JSONValue.Member] = []
        var sections: [(String, [JSONValue.Member])] = []
        var keys = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") && line.count > 2 {
                sections.append((String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces), []))
                continue
            }
            var body = Substring(line)
            if body.hasPrefix("export ") { body = body.dropFirst(7) }
            guard let eq = body.firstIndex(of: "=") else { return nil }
            let key = body[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.split(separator: " ").count <= 3,
                  !key.contains(where: { "\"'<>{}[],".contains($0) }) else { return nil }
            let value = unquote(body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            keys += 1
            if sections.isEmpty { top.append(.init(key, .string(value))) } else { sections[sections.count - 1].1.append(.init(key, .string(value))) }
        }
        guard keys > 0 else { return nil }
        return (.object(top + sections.map { .init($0.0, .object($0.1)) }), keys)
    }

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { return String(s.dropFirst().dropLast()) }
        return s
    }
}

// MARK: - YAML

/// The block-style YAML people paste: nested mappings and sequences, quoted and plain scalars,
/// flow collections, `|`/`>` block scalars and comments. Anchors and tags are not supported.
enum YAMLLite {
    struct Line {
        var indent: Int
        var text: String
    }

    private struct Failure: Error {}

    static func parse(_ text: String) -> JSONValue? {
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces) == "---" || raw.trimmingCharacters(in: .whitespaces) == "..." { continue }
            guard !raw.contains("\t") || raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
            let indent = raw.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: String(raw.dropFirst(indent))))
        }
        var p = Parser(lines: lines)
        p.skipBlank()
        guard p.i < p.lines.count else { return nil }
        let first = p.lines[p.i]
        guard isSequenceItem(first.text) || splitKey(stripComment(first.text)) != nil else { return nil }
        do {
            let v = try p.block(indent: first.indent)
            p.skipBlank()
            guard p.i == p.lines.count else { return nil }
            switch v {
            case .object, .array: return v
            default: return nil
            }
        } catch {
            return nil
        }
    }

    static func isSequenceItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    /// `key: rest` outside quotes; nil when the line isn't a mapping entry.
    static func splitKey(_ text: String) -> (String, String)? {
        var quote: Character?
        var depth = 0
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            switch c {
            case "\"" where i == 0, "'" where i == 0: quote = c
            case "[", "{": depth += 1
            case "]", "}": depth -= 1
            case ":" where depth == 0 && (i + 1 == chars.count || chars[i + 1] == " "):
                let key = String(chars[..<i]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (unquoteKey(key), String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            default: break
            }
        }
        return nil
    }

    private static func unquoteKey(_ k: String) -> String {
        if k.count >= 2, let f = k.first, f == "\"" || f == "'", k.last == f { return String(k.dropFirst().dropLast()) }
        return k
    }

    /// Removes a ` # comment` outside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { if i == 0 || chars[i - 1] == " " || chars[i - 1] == ":" || chars[i - 1] == "[" || chars[i - 1] == "," { quote = c } }
            if c == "#" && (i == 0 || chars[i - 1] == " ") {
                return String(chars[..<i]).trimmingCharacters(in: .whitespaces)
            }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private struct Parser {
        var lines: [Line]
        var i = 0

        mutating func skipBlank() {
            while i < lines.count, stripComment(lines[i].text).isEmpty { i += 1 }
        }

        mutating func block(indent: Int) throws -> JSONValue {
            skipBlank()
            guard i < lines.count else { return .null }
            if isSequenceItem(lines[i].text) { return try sequence(indent: indent) }
            if splitKey(stripComment(lines[i].text)) != nil { return try mapping(indent: indent) }
            // A multi-line plain scalar.
            var parts: [String] = []
            while i < lines.count, lines[i].indent >= indent, !stripComment(lines[i].text).isEmpty {
                parts.append(stripComment(lines[i].text))
                i += 1
            }
            return YAMLLite.scalar(parts.joined(separator: " "))
        }

        mutating func sequence(indent: Int) throws -> JSONValue {
            var items: [JSONValue] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent, isSequenceItem(lines[i].text) else { break }
                let text = lines[i].text
                let rest = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                let offset = text.count - rest.count
                if stripComment(rest).isEmpty {
                    i += 1
                    skipBlank()
                    if i < lines.count, lines[i].indent > indent { items.append(try block(indent: lines[i].indent)) } else { items.append(.null) }
                } else if isSequenceItem(rest) || splitKey(stripComment(rest)) != nil {
                    // "- key: value" or "- - x": the rest starts a nested node at the item's content column.
                    lines[i] = Line(indent: indent + offset, text: rest)
                    items.append(try block(indent: indent + offset))
                } else if let style = blockScalarStyle(stripComment(rest)) {
                    i += 1
                    items.append(.string(blockScalar(parentIndent: indent, folded: style)))
                } else {
                    items.append(YAMLLite.scalar(stripComment(rest)))
                    i += 1
                }
            }
            return .array(items)
        }

        mutating func mapping(indent: Int) throws -> JSONValue {
            var members: [JSONValue.Member] = []
            while true {
                skipBlank()
                guard i < lines.count, lines[i].indent == indent, !isSequenceItem(lines[i].text) else { break }
                guard let (key, rest) = splitKey(stripComment(lines[i].text)) else { throw Failure() }
                i += 1
                if rest.isEmpty {
                    skipBlank()
                    if i < lines.count, lines[i].indent > indent || (lines[i].indent == indent && isSequenceItem(lines[i].text)) {
                        members.append(.init(key, try block(indent: lines[i].indent)))
                    } else {
                        members.append(.init(key, .null))
                    }
                } else if let style = blockScalarStyle(rest) {
                    members.append(.init(key, .string(blockScalar(parentIndent: indent, folded: style))))
                } else {
                    members.append(.init(key, YAMLLite.scalar(rest)))
                }
            }
            if i < lines.count, lines[i].indent > indent, !stripComment(lines[i].text).isEmpty { throw Failure() }
            return .object(members)
        }

        /// `|` → false (literal), `>` → true (folded); nil for anything else.
        func blockScalarStyle(_ s: String) -> Bool? {
            let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-0123456789"))
            if s.hasPrefix("|"), t == "|" { return false }
            if s.hasPrefix(">"), t == ">" { return true }
            return nil
        }

        mutating func blockScalar(parentIndent: Int, folded: Bool) -> String {
            var body: [String] = []
            var contentIndent: Int?
            while i < lines.count {
                let line = lines[i]
                if line.text.isEmpty { body.append(""); i += 1; continue }
                guard line.indent > parentIndent else { break }
                let ci = contentIndent ?? line.indent
                contentIndent = ci
                body.append(String(repeating: " ", count: max(0, line.indent - ci)) + line.text)
                i += 1
            }
            while body.last == "" { body.removeLast() }
            if !folded { return body.joined(separator: "\n") + "\n" }
            var out = ""
            for (n, l) in body.enumerated() {
                if l.isEmpty { out += "\n" } else { out += (n > 0 && !out.hasSuffix("\n") ? " " : "") + l }
            }
            return out + "\n"
        }
    }

    /// A plain, quoted or flow scalar.
    static func scalar(_ raw: String) -> JSONValue {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") || s.hasPrefix("{") {
            var f = Flow(chars: Array(s))
            if let v = f.value(), f.atEnd { return v }
        }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") { return .string(unescapeDouble(String(s.dropFirst().dropLast()))) }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return .string(String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if JSONParser.isCanonicalNumber(s) { return .number(s) }
        if s.hasPrefix("+"), JSONParser.isCanonicalNumber(String(s.dropFirst())) { return .number(String(s.dropFirst())) }
        return .string(s)
    }

    private static func unescapeDouble(_ s: String) -> String {
        var out = ""
        var escape = false
        for c in s {
            if escape {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                default: out.append(c)
                }
                escape = false
            } else if c == "\\" {
                escape = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// `[a, b]` and `{k: v}` with nesting.
    private struct Flow {
        let chars: [Character]
        var i = 0
        var atEnd: Bool {
            mutating get { skip(); return i == chars.count }
        }

        mutating func skip() { while i < chars.count, chars[i] == " " { i += 1 } }

        mutating func value() -> JSONValue? {
            skip()
            guard i < chars.count else { return nil }
            if chars[i] == "[" {
                i += 1
                var items: [JSONValue] = []
                skip()
                if i < chars.count, chars[i] == "]" { i += 1; return .array([]) }
                while i < chars.count {
                    guard let v = value() else { return nil }
                    items.append(v)
                    skip()
                    guard i < chars.count else { return nil }
                    if chars[i] == "," { i += 1; continue }
                    if chars[i] == "]" { i += 1; return .array(items) }
                    return nil
                }
                return nil
            }
            if chars[i] == "{" {
                i += 1
                var members: [JSONValue.Member] = []
                skip()
                if i < chars.count, chars[i] == "}" { i += 1; return .object([]) }
                while i < chars.count {
                    let key = token(stopAt: [":"])
                    guard i < chars.count, chars[i] == ":" else { return nil }
                    i += 1
                    guard let v = value() else { return nil }
                    members.append(.init(key, v))
                    skip()
                    guard i < chars.count else { return nil }
                    if chars[i] == "," { i += 1; continue }
                    if chars[i] == "}" { i += 1; return .object(members) }
                    return nil
                }
                return nil
            }
            return YAMLLite.scalar(token(stopAt: [",", "]", "}"]))
        }

        mutating func token(stopAt: Set<Character>) -> String {
            skip()
            var out = ""
            var quote: Character?
            while i < chars.count {
                let c = chars[i]
                if let q = quote {
                    out.append(c)
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                    out.append(c)
                } else if stopAt.contains(c) {
                    break
                } else {
                    out.append(c)
                }
                i += 1
            }
            let t = out.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, let f = t.first, f == "\"" || f == "'", t.last == f, stopAt.contains(":") {
                return String(t.dropFirst().dropLast())
            }
            return t
        }
    }
}
