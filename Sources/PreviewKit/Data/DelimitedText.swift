import Foundation

/// CSV/TSV parsing (RFC 4180 quoting, delimiter detection) and table rendering.
public enum DelimitedText {
    /// Picks the delimiter that splits the first lines most consistently: comma, semicolon, tab or pipe.
    public static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true).prefix(20)
        var best: (Character, Int) = (",", -1)
        for d in [Character(","), ";", "\t", "|"] {
            let counts = sample.map { line -> Int in
                var inQuotes = false, n = 0
                for c in line { if c == "\"" { inQuotes.toggle() } else if c == d && !inQuotes { n += 1 } }
                return n
            }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = counts.filter { $0 == first }.count
            let score = consistent * 100 + first
            if score > best.1 { best = (d, score) }
        }
        return best.0
    }

    /// Rows of fields. Stops after `maxRows` rows (the second value reports whether more remained).
    public static func parse(_ text: String, delimiter: Character, maxRows: Int = .max) -> ([[String]], Bool) {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var afterQuote = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; afterQuote = true; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            if c == "\"" && field.isEmpty && !afterQuote { inQuotes = true; continue }
            if c == delimiter {
                row.append(field); field = ""; afterQuote = false
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""; afterQuote = false
                rows.append(row); row = []
                if rows.count >= maxRows {
                    let more = next() != nil
                    return (rows, more)
                }
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty || afterQuote { row.append(field); rows.append(row) }
        return (rows, false)
    }

    /// A themed page with a sticky header row and row numbers.
    public static func page(_ text: String, title: String, theme: PreviewTheme, delimiter: Character? = nil,
                            maxRows: Int = 5000, firstRowIsHeader: Bool = true) -> String {
        let d = delimiter ?? detectDelimiter(text)
        let (rows, more) = parse(text, delimiter: d, maxRows: maxRows + (firstRowIsHeader ? 1 : 0))
        let width = rows.map(\.count).max() ?? 0
        var html = "<div class=\"grid-wrap\"><table class=\"grid\">"
        var body = rows[...]
        if firstRowIsHeader, let header = rows.first {
            html += "<thead><tr><th class=\"n\"></th>"
            for i in 0..<width { html += "<th>\(HTML.escape(i < header.count ? header[i] : ""))</th>" }
            html += "</tr></thead>"
            body = rows.dropFirst()
        }
        html += "<tbody>"
        for (index, row) in body.enumerated() {
            html += "<tr><td class=\"n\">\(index + 1)</td>"
            for i in 0..<width {
                let v = i < row.count ? row[i] : ""
                let numeric = Double(v.trimmingCharacters(in: .whitespaces)) != nil
                html += numeric ? "<td class=\"num\">\(HTML.escape(v))</td>" : "<td title=\"\(HTML.escape(v))\">\(HTML.escape(v))</td>"
            }
            html += "</tr>"
        }
        html += "</tbody></table></div>"
        let separated = switch d {
        case "\t": String(localized: "Tab-separated", comment: "Table preview: how the columns of a CSV/TSV file are separated")
        case ",": String(localized: "Comma-separated", comment: "Table preview: how the columns of a CSV/TSV file are separated")
        case ";": String(localized: "Semicolon-separated", comment: "Table preview: how the columns of a CSV/TSV file are separated")
        default: String(localized: "Pipe-separated", comment: "Table preview: how the columns of a CSV/TSV file are separated")
        }
        var notice = [String(localized: "\(body.count) rows", comment: "Table preview: number of rows"),
                      String(localized: "\(width) columns", comment: "Table preview: number of columns"), separated]
        if more { notice.append(String(localized: "showing the first \(maxRows) rows", comment: "Table preview: only the first rows are listed")) }
        return HTML.document(title: title, body: "<div class=\"notice\">\(HTML.escape(notice.joined(separator: " · ")))</div>" + html, theme: theme,
                             extraCSS: Styles.code + Styles.table)
    }
}
