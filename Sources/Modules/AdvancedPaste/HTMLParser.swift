import Foundation

/// A forgiving HTML tree: enough structure for clipboard fragments from browsers, Office,
/// Google Docs and Notes (unclosed `<p>`/`<li>`/`<td>`, void elements, comments, entities).
final class HTMLNode {
    enum Kind { case root, element, text }

    let kind: Kind
    /// Lower-case tag name for elements.
    let name: String
    let attributes: [String: String]
    /// Decoded text for text nodes.
    let text: String
    private(set) var children: [HTMLNode] = []
    private(set) weak var parent: HTMLNode?

    init(kind: Kind, name: String = "", attributes: [String: String] = [:], text: String = "") {
        self.kind = kind
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    func append(_ child: HTMLNode) {
        child.parent = self
        children.append(child)
    }

    subscript(attribute: String) -> String? { attributes[attribute] }

    /// Concatenated text of all descendants (`<br>` as a newline).
    var textContent: String {
        switch kind {
        case .text: return text
        default:
            if name == "br" { return "\n" }
            return children.map(\.textContent).joined()
        }
    }

    var elementChildren: [HTMLNode] { children.filter { $0.kind == .element } }
}

enum HTMLParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link",
                                            "meta", "param", "source", "track", "wbr", "basefont", "frame"]
    /// Elements whose start closes an open `<p>`.
    static let closesParagraph: Set<String> = ["address", "article", "aside", "blockquote", "details", "div", "dl",
                                               "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2",
                                               "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p",
                                               "pre", "section", "table", "ul"]
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp"]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(kind: .root)
        var stack = [root]
        let s = Array(html.unicodeScalars)
        var i = 0
        var buffer = String.UnicodeScalarView()

        func flush() {
            guard !buffer.isEmpty else { return }
            stack[stack.count - 1].append(HTMLNode(kind: .text, text: decodeEntities(String(buffer))))
            buffer = String.UnicodeScalarView()
        }
        func isLetter(_ c: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(c) }
        func lower(_ c: Unicode.Scalar) -> UInt32 { (65...90).contains(c.value) ? c.value + 32 : c.value }
        func has(_ prefix: String, at index: Int) -> Bool {
            var k = index
            for c in prefix.unicodeScalars {
                guard k < s.count, lower(s[k]) == lower(c) else { return false }
                k += 1
            }
            return true
        }
        func isHeading(_ n: String?) -> Bool {
            guard let n, n.count == 2, n.hasPrefix("h"), let d = n.last?.wholeNumberValue else { return false }
            return (1...6).contains(d)
        }
        func find(_ needle: String, from index: Int) -> Int? {
            var j = index
            while j < s.count {
                if has(needle, at: j) { return j }
                j += 1
            }
            return nil
        }
        func close(_ name: String) {
            guard let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 else { return }
            stack.removeSubrange(idx...)
        }
        /// Closes `name` if it is open above the nearest of `boundaries`.
        func closeOpen(_ names: Set<String>, within boundaries: Set<String>) {
            for idx in stride(from: stack.count - 1, to: 0, by: -1) {
                let n = stack[idx].name
                if names.contains(n) { stack.removeSubrange(idx...); return }
                if boundaries.contains(n) { return }
            }
        }

        while i < s.count {
            let c = s[i]
            guard c == "<", i + 1 < s.count else { buffer.append(c); i += 1; continue }
            let next = s[i + 1]
            if has("<!--", at: i) {
                flush()
                i = (find("-->", from: i + 4).map { $0 + 3 }) ?? s.count
            } else if next == "!" || next == "?" {
                flush()
                if has("<![CDATA[", at: i) {
                    let end = find("]]>", from: i + 9) ?? s.count
                    stack[stack.count - 1].append(HTMLNode(kind: .text, text: String(String.UnicodeScalarView(s[(i + 9)..<end]))))
                    i = min(s.count, end + 3)
                } else {
                    i = (find(">", from: i).map { $0 + 1 }) ?? s.count
                }
            } else if next == "/", i + 2 < s.count, isLetter(s[i + 2]) {
                flush()
                var j = i + 2
                var name = ""
                while j < s.count, s[j] != ">", !CharacterSet.whitespacesAndNewlines.contains(s[j]) {
                    name.unicodeScalars.append(s[j]); j += 1
                }
                i = (find(">", from: j).map { $0 + 1 }) ?? s.count
                name = name.lowercased()
                if name == "br" {
                    stack[stack.count - 1].append(HTMLNode(kind: .element, name: "br"))
                } else {
                    close(name)
                }
            } else if isLetter(next) {
                flush()
                guard let (name, attrs, selfClosing, end) = startTag(s, at: i + 1) else { buffer.append(c); i += 1; continue }
                i = end
                // Implied end tags.
                if closesParagraph.contains(name) { closeOpen(["p"], within: ["div", "li", "td", "th", "blockquote", "section", "article", "body"]) }
                if name == "li" { closeOpen(["li"], within: ["ul", "ol"]) }
                if name == "dt" || name == "dd" { closeOpen(["dt", "dd"], within: ["dl"]) }
                if name == "tr" { closeOpen(["tr", "td", "th"], within: ["table", "thead", "tbody", "tfoot"]) }
                if name == "td" || name == "th" { closeOpen(["td", "th"], within: ["tr", "table"]) }
                if ["thead", "tbody", "tfoot"].contains(name) { closeOpen(["thead", "tbody", "tfoot", "tr", "td", "th"], within: ["table"]) }
                if name == "option" { closeOpen(["option"], within: ["select"]) }
                if isHeading(name), let last = stack.last?.name, isHeading(last) { close(last) }

                let node = HTMLNode(kind: .element, name: name, attributes: attrs)
                stack[stack.count - 1].append(node)
                if rawText.contains(name) && !selfClosing {
                    let close = find("</" + name, from: i) ?? s.count
                    if name == "textarea" || name == "xmp" {
                        node.append(HTMLNode(kind: .text, text: decodeEntities(String(String.UnicodeScalarView(s[i..<close])))))
                    }
                    i = (find(">", from: close).map { $0 + 1 }) ?? s.count
                } else if !selfClosing && !voidElements.contains(name) {
                    stack.append(node)
                }
            } else {
                buffer.append(c)
                i += 1
            }
        }
        flush()
        return root
    }

    /// Parses `name attr="v" …>` starting at the tag name; returns the index after `>`.
    private static func startTag(_ s: [Unicode.Scalar], at start: Int) -> (String, [String: String], Bool, Int)? {
        var i = start
        let ws = CharacterSet.whitespacesAndNewlines
        var name = ""
        while i < s.count, s[i] != ">", s[i] != "/", !ws.contains(s[i]) { name.unicodeScalars.append(s[i]); i += 1 }
        var attrs: [String: String] = [:]
        var selfClosing = false
        while i < s.count {
            while i < s.count, ws.contains(s[i]) { i += 1 }
            guard i < s.count else { break }
            if s[i] == ">" { return (name.lowercased(), attrs, selfClosing, i + 1) }
            if s[i] == "/" { selfClosing = true; i += 1; continue }
            var key = ""
            while i < s.count, s[i] != "=", s[i] != ">", s[i] != "/", !ws.contains(s[i]) { key.unicodeScalars.append(s[i]); i += 1 }
            while i < s.count, ws.contains(s[i]) { i += 1 }
            var value = ""
            if i < s.count, s[i] == "=" {
                i += 1
                while i < s.count, ws.contains(s[i]) { i += 1 }
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let q = s[i]
                    i += 1
                    while i < s.count, s[i] != q { value.unicodeScalars.append(s[i]); i += 1 }
                    i += 1
                } else {
                    while i < s.count, s[i] != ">", !ws.contains(s[i]) { value.unicodeScalars.append(s[i]); i += 1 }
                }
            }
            if !key.isEmpty { attrs[key.lowercased()] = decodeEntities(value) }
            selfClosing = false
        }
        return name.isEmpty ? nil : (name.lowercased(), attrs, selfClosing, s.count)
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ensp": "\u{2002}",
        "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "shy": "\u{00AD}",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«",
        "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·", "times": "×", "divide": "÷",
        "plusmn": "±", "deg": "°", "micro": "µ", "para": "¶", "sect": "§", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "curren": "¤", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹",
        "sup2": "²", "sup3": "³", "iexcl": "¡", "iquest": "¿", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hArr": "⇔", "le": "≤", "ge": "≥", "ne": "≠",
        "asymp": "≈", "infin": "∞", "check": "✓", "dagger": "†", "Dagger": "‡", "prime": "′", "Prime": "″",
        "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´", "cedil": "¸", "uml": "¨",
        "szlig": "ß", "aelig": "æ", "AElig": "Æ", "oslash": "ø", "Oslash": "Ø", "aring": "å", "Aring": "Å",
        "ccedil": "ç", "Ccedil": "Ç", "ntilde": "ñ", "Ntilde": "Ñ", "eth": "ð", "thorn": "þ", "oelig": "œ",
    ]

    /// Decodes named (with `;`), decimal and hex character references.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let semi = s[i...].prefix(34).firstIndex(of: ";") else {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            let name = String(s[s.index(after: i)..<semi])
            var decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if let named = entities[name] ?? entities[name.lowercased()], !name.isEmpty {
                decoded = named
            } else if let scalar = accented(name) {
                decoded = scalar
            }
            if let decoded {
                out += decoded
                i = s.index(after: semi)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    /// `eacute`, `Uuml`, `ocirc`… for the Latin letters.
    private static func accented(_ name: String) -> String? {
        let marks: [String: String] = ["acute": "\u{0301}", "grave": "\u{0300}", "circ": "\u{0302}", "uml": "\u{0308}",
                                       "tilde": "\u{0303}", "ring": "\u{030A}", "cedil": "\u{0327}", "caron": "\u{030C}"]
        guard let first = name.first, first.isLetter, first.isASCII, name.count > 2 else { return nil }
        let rest = String(name.dropFirst())
        guard let mark = marks[rest] else { return nil }
        return (String(first) + mark).precomposedStringWithCanonicalMapping
    }
}
