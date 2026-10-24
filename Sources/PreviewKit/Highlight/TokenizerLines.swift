import Foundation

extension Scanner {
    // MARK: YAML

    mutating func scanYAML() {
        var blockScalarIndent: Int?     // inside `key: |` text, lines indented deeper than this are text
        while i < n {
            let lineStart = i
            let end = lineEnd(from: i)
            var k = i
            while k < end && bytes[k] == 0x20 { k += 1 }
            let indent = k - lineStart
            if let bi = blockScalarIndent {
                if k == end || indent > bi { emit(.string, end); emit(.plain, end + 1); continue }
                blockScalarIndent = nil
            }
            emit(.plain, k)
            if matches("---", at: i) || matches("...", at: i), indent == 0 {
                emit(.meta, i + 3)
            } else if peek() == UInt8(ascii: "%") && indent == 0 {
                emit(.meta, end)
            }
            // Sequence markers.
            while i < end, bytes[i] == UInt8(ascii: "-"), i + 1 >= end || bytes[i + 1] == 0x20 {
                emit(.keyword, i + 1)
                while i < end && bytes[i] == 0x20 { emit(.plain, i + 1) }
            }
            if let colon = yamlKeyColon(from: i, to: end) {
                emit(.property, colon)
                emit(.plain, colon + 1)
            }
            if scanYAMLValue(to: end) { blockScalarIndent = indent }
            emit(.plain, min(n, end + 1))
        }
    }

    /// The `:` ending a mapping key on this line, if the line starts with one.
    private func yamlKeyColon(from j: Int, to end: Int) -> Int? {
        guard j < end else { return nil }
        let first = bytes[j]
        if Array("#[{|>&*!%@`".utf8).contains(first) { return nil }
        var k = j
        if first == 0x22 || first == 0x27 {
            guard let close = stringEnd(StringRule(String(UnicodeScalar(first)), escapes: first == 0x22), contentStart: j + 1) else { return nil }
            k = close
            while k < end && bytes[k] == 0x20 { k += 1 }
            return k < end && bytes[k] == UInt8(ascii: ":") && (k + 1 == end || bytes[k + 1] == 0x20) ? k : nil
        }
        while k < end {
            if bytes[k] == UInt8(ascii: ":") && (k + 1 == end || bytes[k + 1] == 0x20 || bytes[k + 1] == 0x0D) { return k }
            if bytes[k] == UInt8(ascii: "#") && k > j && bytes[k - 1] == 0x20 { return nil }
            k += 1
        }
        return nil
    }

    /// Colors the rest of a YAML line; returns true when it opens a block scalar (`|`, `>`).
    private mutating func scanYAMLValue(to end: Int) -> Bool {
        var opensBlock = false
        while i < end {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0D { emit(.plain, i + 1); continue }
            if b == UInt8(ascii: "#") && (i == 0 || Byte.isSpace(bytes[i - 1]) || bytes[i - 1] == 0x0A) { emit(.comment, end); break }
            if b == 0x22 || b == 0x27 {
                let close = stringEnd(StringRule(String(UnicodeScalar(b)), escapes: b == 0x22, multiline: true), contentStart: i + 1) ?? n
                emit(.string, close)
                continue
            }
            if b == UInt8(ascii: "&") || b == UInt8(ascii: "*") { emit(.variable, plainScalarEnd(from: i, to: end, stopAtSpace: true)); continue }
            if b == UInt8(ascii: "!") { emit(.type, plainScalarEnd(from: i, to: end, stopAtSpace: true)); continue }
            if (b == UInt8(ascii: "|") || b == UInt8(ascii: ">")) {
                var k = i + 1
                while k < end && (Byte.isDigit(bytes[k]) || bytes[k] == UInt8(ascii: "-") || bytes[k] == UInt8(ascii: "+")) { k += 1 }
                emit(.meta, k)
                opensBlock = true
                continue
            }
            if Array("[]{},".utf8).contains(b) { emit(.plain, i + 1); continue }
            let scalarEnd = plainScalarEnd(from: i, to: end, stopAtSpace: false)
            let word = text(i, scalarEnd).trimmingCharacters(in: .whitespaces)
            let kind: TokenKind
            if literals.contains(word) { kind = .literal }
            else if Double(word.replacingOccurrences(of: "_", with: "")) != nil || word.hasPrefix("0x") { kind = .number }
            else { kind = .string }
            emit(kind, scalarEnd)
        }
        return opensBlock
    }

    private func plainScalarEnd(from j: Int, to end: Int, stopAtSpace: Bool) -> Int {
        var k = j + 1
        while k < end {
            let c = bytes[k]
            if stopAtSpace && c == 0x20 { break }
            if c == UInt8(ascii: "#") && bytes[k - 1] == 0x20 { return k - 1 }
            if Array(",]}".utf8).contains(c) { break }
            if c == UInt8(ascii: ":") && (k + 1 == end || bytes[k + 1] == 0x20) { break }
            k += 1
        }
        return k
    }

    // MARK: INI, TOML, .properties, .env, .gitignore

    mutating func scanINI() {
        while i < n {
            let end = lineEnd(from: i)
            while i < end && Byte.isSpace(bytes[i]) { emit(.plain, i + 1) }
            guard i < end else { emit(.plain, min(n, end + 1)); continue }
            let b = bytes[i]
            if lang.lineComments.contains(where: { matches($0, at: i) }) {
                emit(.comment, end)
            } else if b == UInt8(ascii: "[") {
                var k = i
                while k < end && bytes[k] != UInt8(ascii: "]") { k += 1 }
                while k < end && bytes[k] == UInt8(ascii: "]") { k += 1 }
                emit(.section, k)
                scanINIValue()
            } else if let sep = iniSeparator(from: i, to: end) {
                var keyEnd = sep
                while keyEnd > i && Byte.isSpace(bytes[keyEnd - 1]) { keyEnd -= 1 }
                if matches("export ", at: i) { emit(.keyword, i + 6) }
                emit(.property, keyEnd)
                emit(.plain, sep + 1)
                scanINIValue()
            } else {
                emit(.plain, end)
            }
            // A multi-line string may have moved us past the end of this line already.
            if i < n && bytes[i] == 0x0A { emit(.plain, i + 1) }
        }
    }

    private func iniSeparator(from j: Int, to end: Int) -> Int? {
        var k = j
        while k < end {
            let c = bytes[k]
            if c == UInt8(ascii: "=") || (c == UInt8(ascii: ":") && lang.id == "ini") { return k > j ? k : nil }
            if c == 0x22 || c == 0x27 || c == UInt8(ascii: "[") || c == UInt8(ascii: "{") { return nil }
            k += 1
        }
        return nil
    }

    /// Values after `=`: strings (including TOML multi-line), numbers, dates, literals, arrays.
    private mutating func scanINIValue() {
        while i < n && bytes[i] != 0x0A {
            let b = bytes[i]
            if Byte.isSpace(b) { emit(.plain, i + 1); continue }
            if (b == UInt8(ascii: "#") || b == UInt8(ascii: ";")) && (i == 0 || Byte.isSpace(bytes[i - 1])) {
                emit(.comment, lineEnd(from: i)); continue
            }
            if let end = matchString() { emit(.string, end); continue }
            if Byte.isDigit(b) || ((b == UInt8(ascii: "-") || b == UInt8(ascii: "+")) && Byte.isDigit(peek(1))) {
                var k = i + 1
                while k < n && (Byte.isWord(bytes[k]) || Array(".:-+".utf8).contains(bytes[k])) { k += 1 }
                emit(.number, k); continue
            }
            if Byte.isLetter(b) {
                let end = wordEnd(from: i)
                let word = text(i, end)
                if literals.contains(word.lowercased()) { emit(.literal, end); continue }
                if lang.id == "toml" {
                    // Inline table keys: `{ name = "x" }`
                    var k = end
                    while k < n && Byte.isSpace(bytes[k]) { k += 1 }
                    if k < n && bytes[k] == UInt8(ascii: "=") { emit(.property, end); continue }
                    emit(.plain, end); continue
                }
                // INI values are free text up to an inline comment.
                var k = end
                while k < n && bytes[k] != 0x0A && !((bytes[k] == UInt8(ascii: "#") || bytes[k] == UInt8(ascii: ";")) && Byte.isSpace(bytes[k - 1])) { k += 1 }
                emit(.string, k); continue
            }
            if b == UInt8(ascii: "$"), let end = variableEnd(at: i) { emit(.variable, end); continue }
            emit(.plain, i + 1)
        }
    }

    // MARK: Diff

    mutating func scanDiff() {
        while i < n {
            let end = lineEnd(from: i)
            let kind: TokenKind
            if ["+++ ", "--- ", "diff ", "index ", "new file", "deleted file", "similarity", "rename ", "Binary files", "Only in"]
                .contains(where: { matches($0, at: i) }) {
                kind = .meta
            } else if matches("@@", at: i) {
                kind = .section
            } else if matches("+", at: i) || matches(">", at: i) {
                kind = .inserted
            } else if matches("-", at: i) || matches("<", at: i) {
                kind = .deleted
            } else if matches("\\", at: i) {
                kind = .comment
            } else {
                kind = .plain
            }
            emit(kind, end)
            emit(.plain, min(n, end + 1))
        }
    }

    // MARK: Markdown source

    mutating func scanMarkdown() {
        var fence: [UInt8]?
        while i < n {
            let end = lineEnd(from: i)
            var k = i
            while k < end && bytes[k] == 0x20 { k += 1 }
            let isFence = k + 2 < end && (bytes[k] == UInt8(ascii: "`") || bytes[k] == UInt8(ascii: "~"))
                && bytes[k + 1] == bytes[k] && bytes[k + 2] == bytes[k]
            if let f = fence {
                if isFence && matches(String(decoding: f, as: UTF8.self), at: k) { fence = nil; emit(.meta, end) }
                else { emit(.string, end) }
                emit(.plain, min(n, end + 1))
                continue
            }
            if isFence {
                fence = Array(bytes[k..<(k + 3)])
                emit(.meta, end)
                emit(.plain, min(n, end + 1))
                continue
            }
            emit(.plain, k)
            if peek() == UInt8(ascii: "#") {
                emit(.heading, end)
            } else if let kind = ruleLineKind(from: i, to: end) {
                emit(kind, end)
            } else {
                if peek() == UInt8(ascii: ">") { emit(.comment, i + 1) }
                while i < end && bytes[i] == 0x20 { emit(.plain, i + 1) }
                if i + 1 < end, Array("-*+".utf8).contains(bytes[i]), bytes[i + 1] == 0x20 { emit(.keyword, i + 1) }
                else {
                    var d = i
                    while d < end && Byte.isDigit(bytes[d]) { d += 1 }
                    if d > i, d < end, bytes[d] == UInt8(ascii: ".") || bytes[d] == UInt8(ascii: ")") { emit(.keyword, d + 1) }
                }
                scanMarkdownInline(to: end)
            }
            emit(.plain, min(n, end + 1))
        }
    }

    /// `===` (setext heading underline) or a `---`/`***`/`___` thematic break.
    private func ruleLineKind(from j: Int, to end: Int) -> TokenKind? {
        guard j < end, Array("=-*_".utf8).contains(bytes[j]) else { return nil }
        let c = bytes[j]
        var count = 0
        for k in j..<end {
            if bytes[k] == c { count += 1 } else if !Byte.isSpace(bytes[k]) { return nil }
        }
        if c == UInt8(ascii: "=") { return .heading }
        return count >= 3 ? .meta : nil
    }

    private mutating func scanMarkdownInline(to end: Int) {
        while i < end {
            let b = bytes[i]
            if b == UInt8(ascii: "`") {
                if let close = find("`", from: i + 1), close < end { emit(.string, close + 1); continue }
            }
            if b == UInt8(ascii: "*") || b == UInt8(ascii: "_") {
                let strong = peek(1) == b
                let delim = String(repeating: String(UnicodeScalar(b)), count: strong ? 2 : 1)
                if let close = find(delim, from: i + delim.count), close < end, close > i + delim.count {
                    emit(strong ? .strong : .emphasis, close + delim.count); continue
                }
            }
            if b == UInt8(ascii: "[") || (b == UInt8(ascii: "!") && peek(1) == UInt8(ascii: "[")) {
                if let close = find("]", from: i + 1), close < end {
                    var k = close + 1
                    if k < end, bytes[k] == UInt8(ascii: "("), let paren = find(")", from: k), paren < end { k = paren + 1 }
                    emit(.link, k); continue
                }
            }
            if b == UInt8(ascii: "<"), matches("<http", at: i), let close = find(">", from: i), close < end {
                emit(.link, close + 1); continue
            }
            emit(.plain, i + 1)
        }
    }
}
