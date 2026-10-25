import Foundation

/// State shared by all inline runs of one document.
final class MDInlineContext {
    let references: [String: MDLinkDefinition]
    let footnoteLabels: Set<String>
    let allowHTML: Bool
    let image: (String) -> String?
    private(set) var footnoteOrder: [String] = []

    init(references: [String: MDLinkDefinition], footnoteLabels: Set<String>, allowHTML: Bool,
         image: @escaping (String) -> String?) {
        self.references = references
        self.footnoteLabels = footnoteLabels
        self.allowHTML = allowHTML
        self.image = image
    }

    func footnoteNumber(_ label: String) -> Int {
        if let i = footnoteOrder.firstIndex(of: label) { return i + 1 }
        footnoteOrder.append(label)
        return footnoteOrder.count
    }
}

/// Inline Markdown: emphasis, code spans, links, images, autolinks, raw HTML, entities, breaks.
enum MDInline {
    static func render(_ text: String, _ ctx: MDInlineContext) -> String {
        var p = InlineParser(chars: Array(text), ctx: ctx)
        return p.run()
    }

    static func normalizeLabel(_ s: some StringProtocol) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Text content of rendered inline HTML (for `alt` attributes and heading ids).
    static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func isASCIIPunctuation(_ c: Character) -> Bool {
        guard let a = c.asciiValue else { return false }
        return (33...47).contains(a) || (58...64).contains(a) || (91...96).contains(a) || (123...126).contains(a)
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for ch in s {
            if escaped {
                if !isASCIIPunctuation(ch) { out.append("\\") }
                out.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Link destination: `<…>` or a run without spaces and with balanced parentheses.
    static func linkDestination(_ chars: [Character], at start: Int) -> (String, Int)? {
        var j = start
        guard j < chars.count else { return nil }
        if chars[j] == "<" {
            j += 1
            var dest = ""
            while j < chars.count, chars[j] != ">" {
                if chars[j] == "\n" || chars[j] == "<" { return nil }
                if chars[j] == "\\", j + 1 < chars.count { dest.append(chars[j]); dest.append(chars[j + 1]); j += 2; continue }
                dest.append(chars[j])
                j += 1
            }
            guard j < chars.count else { return nil }
            return (unescape(dest), j + 1)
        }
        var depth = 0
        var dest = ""
        while j < chars.count {
            let c = chars[j]
            if c.isWhitespace || (c.asciiValue.map { $0 < 0x20 } ?? false) { break }
            if c == "\\", j + 1 < chars.count { dest.append(c); dest.append(chars[j + 1]); j += 2; continue }
            if c == "(" { depth += 1 }
            if c == ")" { if depth == 0 { break }; depth -= 1 }
            dest.append(c)
            j += 1
        }
        guard depth == 0 else { return nil }
        return (unescape(dest), j)
    }

    /// Link title in `"…"`, `'…'` or `(…)`.
    static func linkTitle(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard start < chars.count, "\"'(".contains(chars[start]) else { return nil }
        let open = chars[start]
        let close: Character = open == "(" ? ")" : open
        var j = start + 1
        var title = ""
        while j < chars.count, chars[j] != close {
            if chars[j] == "\\", j + 1 < chars.count { title.append(chars[j]); title.append(chars[j + 1]); j += 2; continue }
            if open == "(" && chars[j] == "(" { return nil }
            title.append(chars[j])
            j += 1
        }
        guard j < chars.count else { return nil }
        return (unescape(title), j + 1)
    }

    static func skipSpace(_ chars: [Character], _ j: inout Int, allowNewline: Bool = true) {
        var newlines = 0
        while j < chars.count, chars[j] == " " || chars[j] == "\t" || (allowNewline && chars[j] == "\n" && newlines == 0) {
            if chars[j] == "\n" { newlines += 1 }
            j += 1
        }
    }

    /// `[label]: destination "title"` at the start of `s`; returns the characters consumed (to end of line).
    static func parseLinkDefinition(_ s: String) -> (String, MDLinkDefinition, Int)? {
        let chars = Array(s)
        var j = 0
        while j < chars.count, j < 3, chars[j] == " " { j += 1 }
        guard j < chars.count, chars[j] == "[" else { return nil }
        j += 1
        var label = ""
        while j < chars.count, chars[j] != "]" {
            if chars[j] == "[" { return nil }
            if chars[j] == "\\", j + 1 < chars.count { label.append(chars[j]); label.append(chars[j + 1]); j += 2; continue }
            label.append(chars[j])
            j += 1
        }
        guard j + 1 < chars.count, chars[j + 1] == ":", !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        j += 2
        skipSpace(chars, &j)
        guard let (dest, afterDest) = linkDestination(chars, at: j), !(dest.isEmpty && chars.indices.contains(j) && chars[j] != "<") else { return nil }
        j = afterDest
        let lineEnd = { (k: Int) -> Int? in
            var m = k
            while m < chars.count, chars[m] == " " || chars[m] == "\t" { m += 1 }
            return m == chars.count || chars[m] == "\n" ? m : nil
        }
        var t = j
        skipSpace(chars, &t)
        if t > j, let (title, afterTitle) = linkTitle(chars, at: t), let end = lineEnd(afterTitle) {
            return (normalizeLabel(label), MDLinkDefinition(url: dest, title: title), end)
        }
        guard let end = lineEnd(j) else { return nil }
        return (normalizeLabel(label), MDLinkDefinition(url: dest, title: nil), end)
    }

    /// End index (after `>`) of raw inline HTML starting at `p`: a tag, comment, declaration,
    /// processing instruction or CDATA section.
    static func rawTagEnd(_ chars: [Character], at p: Int) -> Int? {
        guard p < chars.count, chars[p] == "<" else { return nil }
        func has(_ s: String, _ at: Int) -> Bool {
            let a = Array(s)
            guard at + a.count <= chars.count else { return false }
            return Array(chars[at..<(at + a.count)]) == a
        }
        func find(_ s: String, from: Int) -> Int? {
            var k = from
            while k < chars.count { if has(s, k) { return k + s.count }; k += 1 }
            return nil
        }
        if has("<!-->", p) { return p + 5 }
        if has("<!--->", p) { return p + 6 }
        if has("<!--", p) { return find("-->", from: p + 4) }
        if has("<?", p) { return find("?>", from: p + 2) }
        if has("<![CDATA[", p) { return find("]]>", from: p + 9) }
        if has("<!", p), p + 2 < chars.count, chars[p + 2].isLetter { return find(">", from: p + 2) }
        var j = p + 1
        let closing = j < chars.count && chars[j] == "/"
        if closing { j += 1 }
        guard j < chars.count, chars[j].isASCII, chars[j].isLetter else { return nil }
        while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" { j += 1 }
        if closing {
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count && chars[j] == ">" ? j + 1 : nil
        }
        while j < chars.count {
            let before = j
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            guard j < chars.count else { return nil }
            if chars[j] == ">" { return j + 1 }
            if chars[j] == "/" { return j + 1 < chars.count && chars[j + 1] == ">" ? j + 2 : nil }
            guard j > before else { return nil }      // attributes need whitespace before them
            guard chars[j].isASCII, chars[j].isLetter || chars[j] == "_" || chars[j] == ":" else { return nil }
            while j < chars.count, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber || "_.:-".contains(chars[j]) { j += 1 }
            var k = j
            while k < chars.count, chars[k].isWhitespace { k += 1 }
            if k < chars.count, chars[k] == "=" {
                k += 1
                while k < chars.count, chars[k].isWhitespace { k += 1 }
                guard k < chars.count else { return nil }
                if chars[k] == "\"" || chars[k] == "'" {
                    let q = chars[k]
                    k += 1
                    while k < chars.count, chars[k] != q { k += 1 }
                    guard k < chars.count else { return nil }
                    j = k + 1
                } else {
                    let start = k
                    while k < chars.count, !chars[k].isWhitespace, !"\"'=<>`".contains(chars[k]) { k += 1 }
                    guard k > start else { return nil }
                    j = k
                }
            }
        }
        return nil
    }

    static func safeURL(_ url: String) -> String {
        let lower = url.trimmingCharacters(in: .whitespaces).lowercased()
        for bad in ["javascript:", "vbscript:", "data:", "file:"] where lower.hasPrefix(bad) { return "#" }
        return url
    }

    /// GFM extended autolinks (`www.…`, `https://…`, e-mail addresses) in plain text, rendered to HTML.
    static func autolinked(_ text: String) -> String {
        guard text.contains(".") else { return HTML.escape(text) }
        let ns = text as NSString
        let matches = autolinkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return HTML.escape(text) }
        var out = ""
        var last = 0
        for m in matches {
            var candidate = ns.substring(with: m.range)
            candidate = trimAutolink(candidate)
            guard !candidate.isEmpty else { continue }
            let isEmail = !candidate.hasPrefix("www.") && !candidate.lowercased().hasPrefix("http") && candidate.contains("@")
            if isEmail, let lastChar = candidate.last, lastChar == "-" || lastChar == "_" { continue }
            if !isEmail, candidate.hasPrefix("www."), !candidate.dropFirst(4).contains(".") { continue }
            out += HTML.escape(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            let href = isEmail ? "mailto:" + candidate : (candidate.hasPrefix("www.") ? "http://" + candidate : candidate)
            out += "<a href=\"\(HTML.escape(href))\">\(HTML.escape(candidate))</a>"
            last = m.range.location + (candidate as NSString).length
        }
        out += HTML.escape(ns.substring(from: last))
        return out
    }

    private static let autolinkPattern: NSRegularExpression = {
        let pattern = #"(?<![\w/@.+-])(?:(?:https?://|www\.)[^\s<]+|[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9_-]+)+)"#
        do { return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
        catch { preconditionFailure("Invalid autolink pattern: \(error)") }
    }()

    /// Drops trailing punctuation and an unbalanced closing parenthesis, as GFM does.
    static func trimAutolink(_ s: String) -> String {
        var t = s
        while let last = t.last {
            if "?!.,:*_~'\"".contains(last) { t.removeLast(); continue }
            if last == ")" {
                let opens = t.filter { $0 == "(" }.count, closes = t.filter { $0 == ")" }.count
                if closes > opens { t.removeLast(); continue }
            }
            if last == ";", let amp = t.lastIndex(of: "&"), t[amp...].dropFirst().dropLast().allSatisfy({ $0.isLetter || $0.isNumber }) {
                t = String(t[..<amp]); continue
            }
            break
        }
        return t
    }
}

private struct InlineParser {
    enum Node {
        case text(String)
        case html(String)
        case delim(Delim)
        case bracket(Bracket)
    }

    struct Delim {
        var char: Character
        var count: Int
        var original: Int
        var canOpen: Bool
        var canClose: Bool
    }

    struct Bracket {
        var image: Bool
        var active: Bool
        var labelStart: Int
    }

    let chars: [Character]
    let ctx: MDInlineContext
    var pos = 0
    var nodes: [Node] = []
    var brackets: [Int] = []

    init(chars: [Character], ctx: MDInlineContext) {
        self.chars = chars
        self.ctx = ctx
    }

    mutating func run() -> String {
        while pos < chars.count { step() }
        processEmphasis(bottom: 0, autolink: true)
        return render(nodes[...], autolink: true)
    }

    private mutating func appendText(_ s: String) {
        if case .text(let t) = nodes.last { nodes[nodes.count - 1] = .text(t + s) } else { nodes.append(.text(s)) }
    }

    private mutating func step() {
        let c = chars[pos]
        switch c {
        case "\\":
            if pos + 1 < chars.count, chars[pos + 1] == "\n" { trimTrailingSpaces(); nodes.append(.html("<br>\n")); pos += 2 }
            else if pos + 1 < chars.count, MDInline.isASCIIPunctuation(chars[pos + 1]) { appendText(String(chars[pos + 1])); pos += 2 }
            else { appendText("\\"); pos += 1 }
        case "`": codeSpan()
        case "*", "_", "~": delimiterRun(c)
        case "[":
            brackets.append(nodes.count)
            nodes.append(.bracket(Bracket(image: false, active: true, labelStart: pos + 1)))
            pos += 1
        case "!":
            if pos + 1 < chars.count, chars[pos + 1] == "[" {
                brackets.append(nodes.count)
                nodes.append(.bracket(Bracket(image: true, active: true, labelStart: pos + 2)))
                pos += 2
            } else { appendText("!"); pos += 1 }
        case "]": closeBracket()
        case "<": angle()
        case "&": entity()
        case "\n":
            let hard = trimTrailingSpaces() >= 2
            nodes.append(hard ? .html("<br>\n") : .text("\n"))
            pos += 1
        default:
            var j = pos + 1
            while j < chars.count, !"\\`*_~[!]<&\n".contains(chars[j]) { j += 1 }
            appendText(String(chars[pos..<j]))
            pos = j
        }
    }

    /// Removes trailing spaces from the last text node; returns how many there were.
    @discardableResult
    private mutating func trimTrailingSpaces() -> Int {
        guard case .text(let t) = nodes.last else { return 0 }
        let trimmed = String(t.reversed().drop { $0 == " " }.reversed())
        nodes[nodes.count - 1] = .text(trimmed)
        return t.count - trimmed.count
    }

    private mutating func codeSpan() {
        var run = 0
        while pos + run < chars.count, chars[pos + run] == "`" { run += 1 }
        var j = pos + run
        while j < chars.count {
            if chars[j] == "`" {
                var k = 0
                while j + k < chars.count, chars[j + k] == "`" { k += 1 }
                if k == run {
                    var content = String(chars[(pos + run)..<j]).replacingOccurrences(of: "\n", with: " ")
                    if content.count >= 2, content.first == " ", content.last == " ", !content.allSatisfy({ $0 == " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    nodes.append(.html("<code>\(HTML.escape(content))</code>"))
                    pos = j + k
                    return
                }
                j += k
            } else {
                j += 1
            }
        }
        appendText(String(repeating: "`", count: run))
        pos += run
    }

    private static func isPunct(_ c: Character) -> Bool {
        c.isPunctuation || c.isSymbol
    }

    private mutating func delimiterRun(_ c: Character) {
        var run = 0
        while pos + run < chars.count, chars[pos + run] == c { run += 1 }
        let prev: Character = pos > 0 ? chars[pos - 1] : " "
        let next: Character = pos + run < chars.count ? chars[pos + run] : " "
        let prevSpace = prev.isWhitespace, nextSpace = next.isWhitespace
        let prevPunct = Self.isPunct(prev), nextPunct = Self.isPunct(next)
        let left = !nextSpace && (!nextPunct || prevSpace || prevPunct)
        let right = !prevSpace && (!prevPunct || nextSpace || nextPunct)
        var canOpen = left, canClose = right
        if c == "_" {
            canOpen = left && (!right || prevPunct)
            canClose = right && (!left || nextPunct)
        }
        if c == "~" && run > 2 {
            appendText(String(repeating: "~", count: run))
        } else {
            nodes.append(.delim(Delim(char: c, count: run, original: run, canOpen: canOpen, canClose: canClose)))
        }
        pos += run
    }

    private mutating func angle() {
        if let close = chars[(pos + 1)...].firstIndex(where: { $0 == ">" || $0 == "<" || $0 == " " || $0 == "\n" }), chars[close] == ">" {
            let inner = String(chars[(pos + 1)..<close])
            if inner.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]{1,31}:[^\s<>]*$"#, options: .regularExpression) != nil {
                nodes.append(.html("<a href=\"\(HTML.escape(MDInline.safeURL(inner)))\">\(HTML.escape(inner))</a>"))
                pos = close + 1
                return
            }
            if inner.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#, options: .regularExpression) != nil {
                nodes.append(.html("<a href=\"mailto:\(HTML.escape(inner))\">\(HTML.escape(inner))</a>"))
                pos = close + 1
                return
            }
        }
        if ctx.allowHTML, let end = MDInline.rawTagEnd(chars, at: pos) {
            nodes.append(.html(String(chars[pos..<end])))
            pos = end
            return
        }
        appendText("<")
        pos += 1
    }

    private mutating func entity() {
        var j = pos + 1
        if j < chars.count, chars[j] == "#" {
            j += 1
            let hex = j < chars.count && (chars[j] == "x" || chars[j] == "X")
            if hex { j += 1 }
            let start = j
            while j < chars.count, j - start < 7, hex ? chars[j].isHexDigit : (chars[j].isASCII && chars[j].isNumber) { j += 1 }
            if j > start, j < chars.count, chars[j] == ";" {
                nodes.append(.html(String(chars[pos...j])))
                pos = j + 1
                return
            }
        } else {
            let start = j
            while j < chars.count, j - start < 32, chars[j].isASCII, chars[j].isLetter || chars[j].isNumber { j += 1 }
            if j > start, chars[start].isLetter, j < chars.count, chars[j] == ";" {
                nodes.append(.html(String(chars[pos...j])))
                pos = j + 1
                return
            }
        }
        appendText("&")
        pos += 1
    }

    private mutating func closeBracket() {
        guard let bi = brackets.last, case .bracket(let br) = nodes[bi] else {
            appendText("]"); pos += 1; return
        }
        guard br.active else {
            brackets.removeLast()
            nodes[bi] = .text(br.image ? "![" : "[")
            appendText("]"); pos += 1; return
        }
        let label = String(chars[br.labelStart..<pos])
        let after = pos + 1

        if !br.image, label.hasPrefix("^") {
            let key = MDInline.normalizeLabel(label.dropFirst())
            if ctx.footnoteLabels.contains(key) {
                let n = ctx.footnoteNumber(key)
                let id = HTML.escape(HTML.slug(key))
                nodes.removeSubrange(bi...)
                brackets.removeLast()
                nodes.append(.html("<sup class=\"fnref\"><a href=\"#fn-\(id)\" id=\"fnref-\(id)\">\(n)</a></sup>"))
                pos = after
                return
            }
        }

        var dest: String?
        var title: String?
        var end = after
        if after < chars.count, chars[after] == "(" {
            var j = after + 1
            MDInline.skipSpace(chars, &j)
            if let (d, afterDest) = MDInline.linkDestination(chars, at: j) {
                var k = afterDest
                MDInline.skipSpace(chars, &k)
                var t: String?
                if k > afterDest || d.isEmpty, let (tt, afterTitle) = MDInline.linkTitle(chars, at: k) {
                    t = tt
                    k = afterTitle
                    MDInline.skipSpace(chars, &k)
                }
                if k < chars.count, chars[k] == ")" { dest = d; title = t; end = k + 1 }
            }
        }
        if dest == nil {
            if after < chars.count, chars[after] == "[", let close = chars[(after + 1)...].firstIndex(where: { $0 == "]" || $0 == "[" }), chars[close] == "]" {
                let ref = String(chars[(after + 1)..<close])
                let key = MDInline.normalizeLabel(ref.isEmpty ? label : ref)
                if let def = ctx.references[key] { dest = def.url; title = def.title; end = close + 1 }
            } else if let def = ctx.references[MDInline.normalizeLabel(label)] {
                dest = def.url; title = def.title; end = after
            }
        }
        guard let dest else {
            brackets.removeLast()
            nodes[bi] = .text(br.image ? "![" : "[")
            appendText("]"); pos += 1; return
        }

        processEmphasis(bottom: bi + 1, autolink: false)
        let inner = render(nodes[(bi + 1)...], autolink: false)
        nodes.removeSubrange(bi...)
        brackets.removeLast()
        let titleAttr = title.map { " title=\"\(HTML.escape($0))\"" } ?? ""
        if br.image {
            let alt = MDInline.plainText(inner)
            if let src = ctx.image(dest) {
                nodes.append(.html("<img src=\"\(HTML.escape(src))\" alt=\"\(HTML.escape(alt))\"\(titleAttr)>"))
            } else {
                nodes.append(.html("<span class=\"img-blocked\" title=\"\(HTML.escape(dest))\">\(HTML.escape(alt.isEmpty ? String(localized: "Image", comment: "Markdown preview: stands in for an image that isn't loaded") : alt))</span>"))
            }
        } else {
            nodes.append(.html("<a href=\"\(HTML.escape(MDInline.safeURL(dest)))\"\(titleAttr)>\(inner)</a>"))
            for index in brackets {
                if case .bracket(var b) = nodes[index], !b.image { b.active = false; nodes[index] = .bracket(b) }
            }
        }
        pos = end
    }

    private mutating func processEmphasis(bottom: Int, autolink: Bool) {
        var openersBottom: [String: Int] = [:]
        var c = bottom
        while c < nodes.count {
            guard case .delim(var closer) = nodes[c], closer.canClose else { c += 1; continue }
            let key = "\(closer.char)\(closer.canOpen ? 1 : 0)\(closer.original % 3)"
            let floor = max(bottom, openersBottom[key] ?? bottom)
            var found: Int?
            var o = c - 1
            while o >= floor {
                if case .delim(let op) = nodes[o], op.char == closer.char, op.canOpen, op.count > 0 {
                    if closer.char == "~" {
                        if op.count == closer.count { found = o; break }
                    } else {
                        let multipleOfThree = (op.canClose || closer.canOpen) && (op.original + closer.original) % 3 == 0
                            && !(op.original % 3 == 0 && closer.original % 3 == 0)
                        if !multipleOfThree { found = o; break }
                    }
                }
                o -= 1
            }
            guard let o = found, case .delim(var opener) = nodes[o] else {
                openersBottom[key] = c
                if !closer.canOpen { nodes[c] = .text(String(repeating: closer.char, count: closer.count)) }
                c += 1
                continue
            }
            let use = closer.char == "~" ? closer.count : (opener.count >= 2 && closer.count >= 2 ? 2 : 1)
            let tag = closer.char == "~" ? "del" : (use == 2 ? "strong" : "em")
            let inner = render(nodes[(o + 1)..<c], autolink: autolink)
            opener.count -= use
            closer.count -= use
            var replacement: [Node] = []
            if opener.count > 0 { replacement.append(.delim(opener)) }
            replacement.append(.html("<\(tag)>\(inner)</\(tag)>"))
            if closer.count > 0 { replacement.append(.delim(closer)) }
            nodes.replaceSubrange(o...c, with: replacement)
            for (k, v) in openersBottom where v > o { openersBottom[k] = o }
            c = o + replacement.count - (closer.count > 0 ? 1 : 0)
        }
    }

    private func render(_ slice: ArraySlice<Node>, autolink: Bool) -> String {
        var out = ""
        for node in slice {
            switch node {
            case .text(let t): out += autolink ? MDInline.autolinked(t) : HTML.escape(t)
            case .html(let h): out += h
            case .delim(let d): out += HTML.escape(String(repeating: d.char, count: d.count))
            case .bracket(let b): out += b.image ? "![" : "["
            }
        }
        return out
    }
}
