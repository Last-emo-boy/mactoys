import Foundation

/// Pretty printers that keep the document as written (key order, number spelling).
public enum SourceFormatter {
    /// Re-indents JSON (2 spaces) without parsing it into dictionaries. Returns nil when the input
    /// is not valid JSON (JSONC comments are allowed and kept).
    public static func prettyJSON(_ text: String) -> String? {
        guard isValidJSON(text) else { return nil }
        let src = Array(text.utf8)
        var out = [UInt8]()
        out.reserveCapacity(src.count * 2)
        var depth = 0
        var inString = false
        var escaped = false
        var pendingOpen: UInt8 = 0          // just opened { or [: an immediate close stays on one line
        var i = 0
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), slash = UInt8(ascii: "/"), star = UInt8(ascii: "*")
        func newline() {
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }
        while i < src.count {
            let c = src[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == backslash { escaped = true } else if c == quote { inString = false }
                i += 1
                continue
            }
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1; continue }
            if pendingOpen != 0 {
                let open = pendingOpen
                pendingOpen = 0
                if (open == UInt8(ascii: "{") && c == UInt8(ascii: "}")) || (open == UInt8(ascii: "[") && c == UInt8(ascii: "]")) {
                    depth -= 1
                    out.append(c)
                    i += 1
                    continue
                }
                newline()
            }
            switch c {
            case quote:
                inString = true
                out.append(c)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                out.append(c)
                depth += 1
                pendingOpen = c
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth = max(0, depth - 1)
                newline()
                out.append(c)
            case UInt8(ascii: ","):
                out.append(c)
                newline()
            case UInt8(ascii: ":"):
                out.append(c)
                out.append(0x20)
            case slash where i + 1 < src.count && (src[i + 1] == slash || src[i + 1] == star):
                let block = src[i + 1] == star
                var j = i + 2
                while j < src.count {
                    if block ? (src[j] == star && j + 1 < src.count && src[j + 1] == slash) : src[j] == 0x0A { break }
                    j += 1
                }
                let end = block ? min(src.count, j + 2) : j
                out.append(contentsOf: src[i..<end])
                if !block { newline() }
                i = end
                continue
            default:
                out.append(c)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// JSON check (JSON5/JSONC extensions such as comments and trailing commas tolerated).
    public static func isValidJSON(_ text: String) -> Bool {
        let data = Data(text.utf8)
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil { return true }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed])) != nil
    }

    /// Indented XML via `XMLDocument` (external entities never loaded). Nil when not well-formed.
    public static func prettyXML(_ text: String) -> String? {
        guard let doc = try? XMLDocument(data: Data(text.utf8), options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA])
        else { return nil }
        return doc.xmlString(options: [.nodePrettyPrint, .nodePreserveCDATA, .nodeCompactEmptyElement])
    }
}
