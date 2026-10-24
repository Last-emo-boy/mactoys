import Foundation

extension Scanner {
    /// XML, HTML, SVG, plist: tags, attributes, comments, CDATA, entities, and (HTML) embedded
    /// `<script>`/`<style>` contents highlighted as JavaScript/CSS.
    mutating func scanMarkup() {
        while i < n {
            let b = bytes[i]
            if b == UInt8(ascii: "<") {
                if matches("<!--", at: i) { emit(.comment, find("-->", from: i + 4).map { $0 + 3 } ?? n); continue }
                if matches("<![CDATA[", at: i) { emit(.string, find("]]>", from: i + 9).map { $0 + 3 } ?? n); continue }
                if matches("<?", at: i) { emit(.meta, find("?>", from: i + 2).map { $0 + 2 } ?? n); continue }
                if matches("<!", at: i) { emit(.meta, find(">", from: i + 2).map { $0 + 1 } ?? n); continue }
                let next = peek(1)
                if Byte.isLetter(next) || next == UInt8(ascii: "/") || next == UInt8(ascii: "_") || next == UInt8(ascii: ":") {
                    scanTag()
                    continue
                }
            }
            if b == UInt8(ascii: "&") {
                var k = i + 1
                while k < n && k < i + 12 && (Byte.isWord(bytes[k]) || bytes[k] == UInt8(ascii: "#")) { k += 1 }
                if k < n, k > i + 1, bytes[k] == UInt8(ascii: ";") { emit(.escape, k + 1); continue }
            }
            emit(.plain, i + 1)
        }
    }

    func find(_ s: String, from j: Int) -> Int? {
        guard let first = s.utf8.first else { return nil }
        var k = j
        while k < n {
            if bytes[k] == first && matches(s, at: k) { return k }
            k += 1
        }
        return nil
    }

    private mutating func scanTag() {
        let closing = peek(1) == UInt8(ascii: "/")
        emit(.tag, i + (closing ? 2 : 1))
        var k = i
        while k < n && (Byte.isWord(bytes[k]) || Array(":-.".utf8).contains(bytes[k])) { k += 1 }
        let name = text(i, k).lowercased()
        emit(.tag, k)
        var selfClosing = false
        while i < n {
            let b = bytes[i]
            if b == UInt8(ascii: ">") { emit(.tag, i + 1); break }
            if b == UInt8(ascii: "/") && peek(1) == UInt8(ascii: ">") { selfClosing = true; emit(.tag, i + 2); break }
            if b == UInt8(ascii: "<") { break }     // malformed: let the main loop continue
            if Byte.isSpace(b) || b == 0x0A { emit(.plain, i + 1); continue }
            if b == UInt8(ascii: "=") { emit(.plain, i + 1); continue }
            if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                let end = find(String(UnicodeScalar(b)), from: i + 1).map { $0 + 1 } ?? n
                emit(.attrValue, end)
                continue
            }
            var e = i
            while e < n && !Byte.isSpace(bytes[e]) && !Array("=>/<\"'\n".utf8).contains(bytes[e]) { e += 1 }
            if e == i { emit(.plain, i + 1); continue }
            emit(lastTokenIsEquals() ? .attrValue : .attrName, e)
        }
        guard lang.embedsScriptAndStyle, !closing, !selfClosing, name == "script" || name == "style" else { return }
        let closeTag = "</" + name
        var end = i
        while end < n {
            if bytes[end] == UInt8(ascii: "<"), text(end, min(n, end + closeTag.utf8.count)).lowercased() == closeTag { break }
            end += 1
        }
        guard end > i else { return }
        let inner = text(i, end)
        let embedded = SyntaxHighlighter.tokenize(inner, language: name == "script" ? .javascript : .css)
        append(embedded, advancingTo: end)
    }

    /// Whether the last emitted non-blank text was `=` (so an unquoted word is a value).
    private func lastTokenIsEquals() -> Bool {
        var k = i - 1
        while k >= 0 && (Byte.isSpace(bytes[k]) || bytes[k] == 0x0A) { k -= 1 }
        return k >= 0 && bytes[k] == UInt8(ascii: "=")
    }

    /// CSS, SCSS, Less: selectors, at-rules, properties, values, colors, units.
    mutating func scanCSS() {
        enum Mode { case selector, property, value }
        var mode = Mode.selector
        var depth = 0
        while i < n {
            let b = bytes[i]
            if b == 0x0A || Byte.isSpace(b) { emit(.plain, i + 1); continue }
            if matches("/*", at: i) { emit(.comment, find("*/", from: i + 2).map { $0 + 2 } ?? n); continue }
            if matches("//", at: i), i == 0 || Byte.isSpace(bytes[i - 1]) || bytes[i - 1] == 0x0A {
                emit(.comment, lineEnd(from: i)); continue
            }
            if let end = matchString() { emit(.string, end); continue }
            switch b {
            case UInt8(ascii: "{"):
                depth += 1; mode = .property; emit(.plain, i + 1); continue
            case UInt8(ascii: "}"):
                depth = max(0, depth - 1); mode = depth == 0 ? .selector : .property; emit(.plain, i + 1); continue
            case UInt8(ascii: ";"):
                mode = depth == 0 ? .selector : .property; emit(.plain, i + 1); continue
            case UInt8(ascii: "@"):
                emit(.keyword, wordEnd(from: i + 1)); continue
            case UInt8(ascii: "!"):
                if matches("!important", at: i) { emit(.keyword, i + 10); continue }
            case UInt8(ascii: "$"):
                emit(.variable, wordEnd(from: i + 1)); continue
            case UInt8(ascii: "#"):
                let end = wordEnd(from: i + 1)
                emit(mode == .value ? .number : .attrName, end); continue
            case UInt8(ascii: ":"):
                if mode == .property { mode = .value; emit(.plain, i + 1); continue }
                if mode == .selector {
                    var k = i + 1
                    if k < n && bytes[k] == UInt8(ascii: ":") { k += 1 }
                    emit(.keyword, wordEnd(from: k)); continue
                }
            case UInt8(ascii: "."):
                if mode != .value, Byte.isLetter(peek(1)) || peek(1) == UInt8(ascii: "-") || peek(1) == 0x5F {
                    emit(.attrName, wordEnd(from: i + 1)); continue
                }
            default: break
            }
            if let end = numberEnd(at: i), i == 0 || !Byte.isWord(bytes[i - 1]) {
                var k = end
                if k < n && bytes[k] == UInt8(ascii: "%") { k += 1 }
                emit(.number, k); continue
            }
            if Byte.isLetter(b) || b == UInt8(ascii: "-") || b == 0x5F || b >= 0x80 {
                let end = wordEnd(from: i)
                guard end > i else { emit(.plain, i + 1); continue }
                switch mode {
                case .selector: emit(.tag, end)
                case .property:
                    var k = end
                    while k < n && Byte.isSpace(bytes[k]) { k += 1 }
                    emit(k < n && bytes[k] == UInt8(ascii: ":") && (k + 1 >= n || Byte.isSpace(bytes[k + 1]) || !Byte.isLetter(bytes[k + 1])) ? .property : .tag, end)
                case .value:
                    emit(end < n && bytes[end] == UInt8(ascii: "(") ? .builtin : .literal, end)
                }
                continue
            }
            emit(.plain, i + 1)
        }
    }

    func wordEnd(from j: Int) -> Int {
        var k = j
        while k < n && (Byte.isWord(bytes[k]) || bytes[k] == UInt8(ascii: "-")) { k += 1 }
        return k
    }

    /// JSON and JSONC: object keys are properties, the rest are values.
    mutating func scanJSON() {
        while i < n {
            let b = bytes[i]
            if b == 0x0A || Byte.isSpace(b) { emit(.plain, i + 1); continue }
            if matches("//", at: i) { emit(.comment, lineEnd(from: i)); continue }
            if matches("/*", at: i) { emit(.comment, find("*/", from: i + 2).map { $0 + 2 } ?? n); continue }
            if b == 0x22 || b == 0x27 {
                let end = stringEnd(StringRule(String(UnicodeScalar(b))), contentStart: i + 1) ?? n
                var k = end
                while k < n && (Byte.isSpace(bytes[k]) || bytes[k] == 0x0A) { k += 1 }
                emit(k < n && bytes[k] == UInt8(ascii: ":") ? .property : .string, end)
                continue
            }
            if b == UInt8(ascii: "-") || Byte.isDigit(b) {
                let start = b == UInt8(ascii: "-") ? i + 1 : i
                if let end = numberEnd(at: start) { emit(.number, end); continue }
            }
            if Byte.isLetter(b) {
                let end = wordEnd(from: i)
                emit(literals.contains(text(i, end)) ? .literal : .plain, end)
                continue
            }
            emit(.plain, i + 1)
        }
    }
}
