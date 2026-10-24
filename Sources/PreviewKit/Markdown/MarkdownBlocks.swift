import Foundation

/// Block structure of a GitHub-flavored Markdown document. Inline text stays raw until rendering,
/// when link references and footnotes are known.
indirect enum MDBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(info: String, text: String)
    case html(String)
    case quote([MDBlock])
    case list(ordered: Bool, start: Int, tight: Bool, items: [MDListItem])
    case table(align: [MDAlign], header: [String], rows: [[String]])
    case rule
}

struct MDListItem: Equatable {
    /// nil: not a task; true/false: checked state of `- [x]` / `- [ ]`.
    var task: Bool?
    var blocks: [MDBlock]
}

enum MDAlign: Equatable { case none, left, center, right }

struct MDLinkDefinition: Equatable {
    var url: String
    var title: String?
}

/// Parses lines into blocks (CommonMark container/leaf rules, plus GFM tables, task lists and footnotes).
final class MDBlockParser {
    var references: [String: MDLinkDefinition] = [:]
    var footnotes: [String: [MDBlock]] = [:]
    let allowHTML: Bool

    init(allowHTML: Bool) { self.allowHTML = allowHTML }

    static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { expandTabs(String($0)) }
    }

    /// Tabs become spaces up to the next multiple of 4 (only in the leading whitespace, where it matters).
    static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        var column = 0
        var leading = true
        for ch in line {
            if ch == "\t" && leading {
                let width = 4 - column % 4
                out += String(repeating: " ", count: width)
                column += width
            } else {
                if ch != " " { leading = false }
                out.append(ch)
                column += 1
            }
        }
        return out
    }

    // MARK: Line tests

    static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    static func indent(_ s: String) -> Int {
        var n = 0
        for ch in s { if ch == " " { n += 1 } else { break } }
        return n
    }

    static func dropIndent(_ s: String, _ count: Int) -> String {
        var removed = 0
        var idx = s.startIndex
        while removed < count, idx < s.endIndex, s[idx] == " " { idx = s.index(after: idx); removed += 1 }
        return String(s[idx...])
    }

    static func atxHeading(_ line: String) -> (Int, String)? {
        guard indent(line) <= 3 else { return nil }
        let s = line.drop { $0 == " " }
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: "## Title ##"
        if let r = text.range(of: "#+$", options: .regularExpression) {
            let before = text[..<r.lowerBound]
            if before.isEmpty || before.hasSuffix(" ") { text = before.trimmingCharacters(in: .whitespaces) }
        }
        return (hashes, text)
    }

    static func isThematicBreak(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let c = chars.first, "*-_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    static func setextLevel(_ line: String) -> Int? {
        guard indent(line) <= 3 else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = t.first, c == "=" || c == "-", t.allSatisfy({ $0 == c }) else { return nil }
        return c == "=" ? 1 : 2
    }

    struct Fence { var char: Character; var count: Int; var indent: Int; var info: String }

    static func fenceOpen(_ line: String) -> Fence? {
        let ind = indent(line)
        guard ind <= 3 else { return nil }
        let s = line.dropFirst(ind)
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let count = s.prefix { $0 == c }.count
        guard count >= 3 else { return nil }
        let info = s.dropFirst(count).trimmingCharacters(in: .whitespaces)
        if c == "`" && info.contains("`") { return nil }
        return Fence(char: c, count: count, indent: ind, info: info)
    }

    static func closesFence(_ line: String, _ fence: Fence) -> Bool {
        guard indent(line) <= 3 else { return false }
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count >= fence.count && t.allSatisfy { $0 == fence.char }
    }

    static func quoteContent(_ line: String) -> String? {
        let ind = indent(line)
        guard ind <= 3 else { return nil }
        var s = line.dropFirst(ind)
        guard s.first == ">" else { return nil }
        s = s.dropFirst()
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    struct Marker {
        var ordered: Bool
        var char: Character       // bullet char or ordered delimiter
        var start: Int
        var contentIndent: Int
        var content: String
        var isEmpty: Bool { content.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func listMarker(_ line: String) -> Marker? {
        let ind = indent(line)
        guard ind <= 3 else { return nil }
        let s = Array(line.dropFirst(ind))
        guard let first = s.first else { return nil }
        var markerWidth: Int
        var ordered = false
        var char = first
        var start = 1
        if "-+*".contains(first) {
            markerWidth = 1
        } else {
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), digits.count < s.count else { return nil }
            let delim = s[digits.count]
            guard delim == "." || delim == ")" else { return nil }
            ordered = true
            char = delim
            start = Int(String(digits)) ?? 1
            markerWidth = digits.count + 1
        }
        let after = s.dropFirst(markerWidth)
        if after.isEmpty {
            return Marker(ordered: ordered, char: char, start: start, contentIndent: ind + markerWidth + 1, content: "")
        }
        guard after.first == " " else { return nil }
        let spaces = after.prefix { $0 == " " }.count
        let rest = String(after)
        if spaces >= 5 || spaces == after.count {
            // Content is indented code (or blank): the marker takes one space.
            return Marker(ordered: ordered, char: char, start: start, contentIndent: ind + markerWidth + 1,
                          content: String(rest.dropFirst()))
        }
        return Marker(ordered: ordered, char: char, start: start, contentIndent: ind + markerWidth + spaces,
                      content: String(rest.dropFirst(spaces)))
    }

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "picture", "search", "section", "summary", "table", "tbody", "td",
        "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    /// CommonMark HTML block start condition (1…7), or nil.
    static func htmlBlockKind(_ line: String) -> Int? {
        guard indent(line) <= 3 else { return nil }
        let s = line.drop { $0 == " " }
        guard s.first == "<" else { return nil }
        let lower = s.lowercased()
        for tag in ["script", "pre", "style", "textarea"] {
            let p = "<" + tag
            if lower.hasPrefix(p) {
                let next = lower.dropFirst(p.count).first
                if next == nil || next == " " || next == ">" { return 1 }
            }
        }
        if s.hasPrefix("<!--") { return 2 }
        if s.hasPrefix("<?") { return 3 }
        if s.hasPrefix("<![CDATA[") { return 5 }
        if s.hasPrefix("<!"), let c = s.dropFirst(2).first, c.isLetter { return 4 }
        let afterLT = lower.dropFirst(lower.hasPrefix("</") ? 2 : 1)
        let name = afterLT.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        if !name.isEmpty, blockTags.contains(String(name)) {
            let next = afterLT.dropFirst(name.count)
            if next.isEmpty || next.hasPrefix(" ") || next.hasPrefix(">") || next.hasPrefix("/>") { return 6 }
        }
        let trimmed = String(s).trimmingCharacters(in: .whitespaces)
        let chars = Array(trimmed)
        if let end = MDInline.rawTagEnd(chars, at: 0), end == chars.count, !trimmed.hasPrefix("<!") { return 7 }
        return nil
    }

    static func htmlBlockEnds(_ line: String, kind: Int) -> Bool {
        let lower = line.lowercased()
        switch kind {
        case 1: return ["</script>", "</pre>", "</style>", "</textarea>"].contains { lower.contains($0) }
        case 2: return line.contains("-->")
        case 3: return line.contains("?>")
        case 4: return line.contains(">")
        case 5: return line.contains("]]>")
        default: return false
        }
    }

    static func tableCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for ch in t {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        // `\|` inside a cell is a literal pipe.
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    static func tableDelimiter(_ line: String) -> [MDAlign]? {
        guard line.contains("-"), indent(line) <= 3 else { return nil }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return nil }
        var aligns: [MDAlign] = []
        for c in cells {
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            guard !c.dropFirst().dropLast().contains(":") else { return nil }
            aligns.append(left && right ? .center : right ? .right : left ? .left : .none)
        }
        if cells.count == 1 && !line.contains("|") { return nil }
        return aligns
    }

    /// Whether `line` would start a block that ends a paragraph or a lazy continuation.
    func interruptsParagraph(_ line: String) -> Bool {
        if Self.atxHeading(line) != nil || Self.isThematicBreak(line) || Self.fenceOpen(line) != nil
            || Self.quoteContent(line) != nil { return true }
        if let m = Self.listMarker(line), !m.isEmpty, !m.ordered || m.start == 1 { return true }
        if allowHTML, let k = Self.htmlBlockKind(line), k < 7 { return true }
        return false
    }

    // MARK: Parsing

    func parse(_ lines: [String]) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flushParagraph() {
            guard !para.isEmpty else { return }
            let rest = extractReferences(para)
            if !rest.isEmpty {
                blocks.append(.paragraph(rest.map { String($0.drop { $0 == " " }) }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespaces)))
            }
            para = []
        }

        while i < lines.count {
            let line = lines[i]
            if Self.isBlank(line) { flushParagraph(); i += 1; continue }
            let ind = Self.indent(line)

            if ind >= 4 {
                if !para.isEmpty { para.append(line); i += 1; continue }   // lazy continuation
                var code: [String] = []
                while i < lines.count, Self.isBlank(lines[i]) || Self.indent(lines[i]) >= 4 {
                    code.append(Self.dropIndent(lines[i], 4))
                    i += 1
                }
                while code.last.map(Self.isBlank) == true { code.removeLast() }
                blocks.append(.code(info: "", text: code.joined(separator: "\n") + "\n"))
                continue
            }
            if let fence = Self.fenceOpen(line) {
                flushParagraph()
                i += 1
                var code: [String] = []
                while i < lines.count, !Self.closesFence(lines[i], fence) {
                    code.append(Self.dropIndent(lines[i], fence.indent))
                    i += 1
                }
                i += 1
                blocks.append(.code(info: fence.info, text: code.isEmpty ? "" : code.joined(separator: "\n") + "\n"))
                continue
            }
            if let (level, text) = Self.atxHeading(line) {
                flushParagraph()
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }
            if !para.isEmpty, let level = Self.setextLevel(line) {
                let text = para.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                para = []
                let rest = extractReferences(text.components(separatedBy: "\n"))
                if rest.isEmpty { para = [line] } else { blocks.append(.heading(level: level, text: rest.joined(separator: "\n"))) }
                i += 1
                continue
            }
            if Self.isThematicBreak(line) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }
            if Self.quoteContent(line) != nil {
                flushParagraph()
                blocks.append(.quote(parse(collectQuote(lines, &i))))
                continue
            }
            if let marker = Self.listMarker(line), para.isEmpty || (!marker.isEmpty && (!marker.ordered || marker.start == 1)) {
                flushParagraph()
                blocks.append(parseList(lines, &i))
                continue
            }
            if allowHTML, let kind = Self.htmlBlockKind(line), kind < 7 || para.isEmpty {
                flushParagraph()
                var html: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if kind >= 6 && Self.isBlank(l) { break }
                    html.append(l)
                    i += 1
                    if kind < 6 && Self.htmlBlockEnds(l, kind: kind) { break }
                }
                blocks.append(.html(html.joined(separator: "\n")))
                continue
            }
            if line.contains("|"), i + 1 < lines.count, let align = Self.tableDelimiter(lines[i + 1]),
               Self.tableCells(line).count == align.count {
                flushParagraph()
                let header = Self.tableCells(line)
                i += 2
                var rows: [[String]] = []
                while i < lines.count, !Self.isBlank(lines[i]), !interruptsParagraph(lines[i]) {
                    var cells = Self.tableCells(lines[i])
                    if cells.count < align.count { cells += Array(repeating: "", count: align.count - cells.count) }
                    rows.append(Array(cells.prefix(align.count)))
                    i += 1
                }
                blocks.append(.table(align: align, header: header, rows: rows))
                continue
            }
            if para.isEmpty, let (label, first) = footnoteDefinition(line) {
                var body = [first]
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if Self.isBlank(l) {
                        if i + 1 < lines.count, Self.indent(lines[i + 1]) >= 4 { body.append(""); i += 1; continue }
                        break
                    }
                    if Self.indent(l) >= 4 { body.append(Self.dropIndent(l, 4)); i += 1; continue }
                    if footnoteDefinition(l) != nil || interruptsParagraph(l) { break }
                    body.append(l)
                    i += 1
                }
                footnotes[label] = parse(body)
                continue
            }
            para.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private func collectQuote(_ lines: [String], _ i: inout Int) -> [String] {
        var inner: [String] = []
        var lastWasText = false
        while i < lines.count {
            let l = lines[i]
            if let c = Self.quoteContent(l) {
                inner.append(c)
                lastWasText = !Self.isBlank(c) && Self.fenceOpen(c) == nil
                i += 1
            } else if lastWasText, !Self.isBlank(l), !interruptsParagraph(l) {
                inner.append(l)     // lazy continuation
                i += 1
            } else {
                break
            }
        }
        return inner
    }

    private func parseList(_ lines: [String], _ i: inout Int) -> MDBlock {
        guard let first = Self.listMarker(lines[i]) else { return .paragraph(lines[i]) }
        var items: [MDListItem] = []
        var tight = true
        while i < lines.count, let marker = Self.listMarker(lines[i]),
              marker.ordered == first.ordered, marker.char == first.char {
            var body = [marker.content]
            i += 1
            var lastBlank = marker.isEmpty
            var lastWasText = !marker.isEmpty
            if marker.isEmpty, i < lines.count, Self.isBlank(lines[i]) { i += 1 } // empty item
            while i < lines.count {
                let l = lines[i]
                if Self.isBlank(l) { body.append(""); lastBlank = true; lastWasText = false; i += 1; continue }
                if Self.indent(l) >= marker.contentIndent {
                    body.append(Self.dropIndent(l, marker.contentIndent))
                    lastBlank = false
                    lastWasText = true
                    i += 1
                    continue
                }
                if lastBlank || !lastWasText || Self.listMarker(l) != nil || interruptsParagraph(l) { break }
                body.append(l)      // lazy paragraph continuation
                i += 1
            }
            var trailing = 0
            while body.count > 1, body.last.map(Self.isBlank) == true { body.removeLast(); trailing += 1 }
            var task: Bool?
            if let head = body.first {
                for (prefix, checked) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where head.hasPrefix(prefix) {
                    task = checked
                    body[0] = String(head.dropFirst(prefix.count))
                }
                if task == nil, ["[ ]", "[x]", "[X]"].contains(head) { task = head != "[ ]"; body[0] = "" }
            }
            let blocks = parse(body)
            if hasInternalBlankLine(body) && blocks.count > 1 { tight = false }
            items.append(MDListItem(task: task, blocks: blocks))
            if trailing > 0, i < lines.count, let next = Self.listMarker(lines[i]),
               next.ordered == first.ordered, next.char == first.char { tight = false }
        }
        return .list(ordered: first.ordered, start: first.start, tight: tight, items: items)
    }

    /// A blank line between two blocks of an item (blank lines inside fenced code don't count).
    private func hasInternalBlankLine(_ body: [String]) -> Bool {
        var fence: Fence?
        var sawText = false
        var pendingBlank = false
        for l in body {
            if let f = fence { if Self.closesFence(l, f) { fence = nil }; continue }
            if let f = Self.fenceOpen(l) { if pendingBlank && sawText { return true }; fence = f; sawText = true; continue }
            if Self.isBlank(l) { pendingBlank = sawText; continue }
            if pendingBlank && Self.indent(l) == 0 { return true }
            pendingBlank = false
            sawText = true
        }
        return false
    }

    private func footnoteDefinition(_ line: String) -> (String, String)? {
        guard Self.indent(line) <= 3 else { return nil }
        let s = line.drop { $0 == " " }
        guard s.hasPrefix("[^"), let close = s.range(of: "]:") else { return nil }
        let label = String(s[s.index(s.startIndex, offsetBy: 2)..<close.lowerBound])
        guard !label.isEmpty, !label.contains(" "), !label.contains("]") else { return nil }
        return (MDInline.normalizeLabel(label), String(s[close.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    /// Removes `[label]: url "title"` definitions from the start of a paragraph and records them.
    private func extractReferences(_ lines: [String]) -> [String] {
        var rest = lines
        while let first = rest.first, first.drop(while: { $0 == " " }).hasPrefix("["), !first.drop(while: { $0 == " " }).hasPrefix("[^") {
            let joined = rest.joined(separator: "\n")
            guard let (label, def, consumed) = MDInline.parseLinkDefinition(joined) else { break }
            if references[label] == nil { references[label] = def }
            let remaining = String(joined.dropFirst(consumed))
            rest = remaining.isEmpty ? [] : remaining.components(separatedBy: "\n")
            if rest.first == "" { rest.removeFirst() }
        }
        return rest
    }
}
