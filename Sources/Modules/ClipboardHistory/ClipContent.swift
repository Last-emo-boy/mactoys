import AppKit
import MacToysCore
import SwiftUI

/// What an entry is to the user — finer than `ClipItem.Kind`: links, colors and code are text
/// underneath, but each gets its own preview and filter.
public enum ClipContentType: String, CaseIterable, Codable, Sendable, Identifiable {
    case text, link, color, code, richText, image, file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .text: String(localized: "Text", comment: "Clipboard entry type")
        case .link: String(localized: "Link", comment: "Clipboard entry type: a URL")
        case .color: String(localized: "Color", comment: "Clipboard entry type: a color value such as #FF5F4A")
        case .code: String(localized: "Code", comment: "Clipboard entry type: source code or a shell command")
        case .richText: String(localized: "Rich text", comment: "Clipboard entry type: formatted text")
        case .image: String(localized: "Image", comment: "Clipboard entry type")
        case .file: String(localized: "File", comment: "Clipboard entry type: one or more files")
        }
    }

    /// Plural title for the type filter ("Links", "Images").
    public var filterTitle: String {
        switch self {
        case .text: String(localized: "Text", comment: "Clipboard type filter: plain text entries")
        case .link: String(localized: "Links", comment: "Clipboard type filter")
        case .color: String(localized: "Colors", comment: "Clipboard type filter")
        case .code: String(localized: "Code", comment: "Clipboard type filter: code and shell commands")
        case .richText: String(localized: "Rich text", comment: "Clipboard type filter: formatted text")
        case .image: String(localized: "Images", comment: "Clipboard type filter")
        case .file: String(localized: "Files", comment: "Clipboard type filter")
        }
    }

    public var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .color: "paintpalette.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .richText: "doc.richtext.fill"
        case .image: "photo.fill"
        case .file: "doc.fill"
        }
    }

    public var tint: Tint {
        switch self {
        case .text: .graphite
        case .link: .blue
        case .color: .pink
        case .code: .mint
        case .richText: .orange
        case .image: .indigo
        case .file: .cyan
        }
    }

    /// Classifies an entry from its content.
    public static func of(_ item: ClipItem) -> ClipContentType {
        switch item.kind {
        case .files: return .file
        case .image: return item.image == nil ? classify(text: item.text ?? "", rich: false) : .image
        case .html, .richText: return classify(text: item.text ?? "", rich: true)
        case .text: return classify(text: item.text ?? "", rich: false)
        }
    }

    static func classify(text: String, rich: Bool) -> ClipContentType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ClipText.link(in: trimmed) != nil { return .link }
        if ColorValue.parse(trimmed) != nil { return .color }
        if ClipText.looksLikeCode(trimmed) { return .code }
        return rich ? .richText : .text
    }
}

/// Text helpers shared by the list, the preview and search.
public enum ClipText {
    /// The URL when the whole text is one web, mail or file link.
    public static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4096, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http", "https", "ftp", "ssh", "file": return url.host() != nil || scheme == "file" ? url : nil
        case "mailto", "tel", "sms", "facetime": return trimmed.count > scheme.count + 1 ? url : nil
        default:
            // Custom app schemes ("x-apple.systempreferences:…", "obsidian://…") need a host or a path.
            return url.host() != nil ? url : nil
        }
    }

    /// "github.com" for a link (without "www.").
    public static func host(of url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else {
            return url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The text on one line: each run of spaces and line breaks becomes one space.
    public static func oneLine(_ text: String, limit: Int = 300) -> String {
        var out = ""
        var count = 0
        var space = false
        for ch in text {
            if ch.isWhitespace {
                space = count > 0
                continue
            }
            if count >= limit { return out + "…" }
            if space {
                out.append(" ")
                count += 1
                space = false
            }
            out.append(ch)
            count += 1
        }
        return out
    }

    /// Number of lines, counting line feeds (cheap on long texts: it scans bytes).
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for byte in text.utf8 where byte == 10 { count += 1 }
        return text.utf8.last == 10 ? count - 1 : count
    }

    /// The first non-empty line, trimmed, at most `limit` characters.
    public static func firstLine(_ text: String, limit: Int = 300) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }

    /// Words that start a statement or a shell command. Matched case-sensitively: prose capitalizes
    /// its first word ("Open the file"), code and commands don't ("open file.txt").
    private static let leadingKeywords: Set<String> = [
        "func", "def", "class", "struct", "enum", "protocol", "extension", "interface", "let", "var", "const", "import",
        "return", "public", "private", "fileprivate", "internal", "static", "async", "await", "fn", "pub", "use", "package",
        "#include", "#import", "#define", "using", "namespace", "export", "from", "guard", "defer", "switch", "case",
        "elif", "else", "if", "for", "while", "try", "catch", "throw", "print", "console.log",
        "git", "swift", "npm", "npx", "yarn", "pnpm", "brew", "cd", "ls", "sudo", "ssh", "scp", "curl", "wget", "docker",
        "kubectl", "python", "python3", "pip", "pip3", "xcodebuild", "xcrun", "make", "cargo", "go", "echo",
        "mkdir", "rm", "cp", "mv", "chmod", "grep", "rg", "cat", "open", "defaults", "launchctl", "node", "ruby",
        "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "WITH",
    ]

    private static let operators = ["=>", "->", "::", "==", "!=", "&&", "||", ":=", "+=", "-=", "();", "){", "</", "/>", "${", "$(", " | "]

    /// Whether text reads as source code or a shell command rather than prose.
    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty, text.count < 200_000 else { return false }
        if lines.count == 1 {
            let line = lines[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{"), line.hasSuffix("}") { return true }
            // Prose: words that end like a sentence.
            if line.hasSuffix("."), !line.contains("("), !line.contains("=") { return false }
            return signals(in: line) >= 2
        }
        let codeLines = lines.filter { signals(in: $0) >= 1 }.count
        let indented = lines.dropFirst().filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        let ratio = Double(codeLines) / Double(lines.count)
        return ratio >= 0.6 || (ratio >= 0.4 && indented * 3 >= lines.count)
    }

    /// Counts code-like features of one line.
    static func signals(in rawLine: String) -> Int {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let words = line.split(separator: " ")
        var n = 0
        let first = words.first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "({")) } ?? ""
        if leadingKeywords.contains(first) || line.hasPrefix("$ ") || line.hasPrefix("//") { n += 1 }
        if let last = line.last, ";{}".contains(last) { n += 1 }
        if line.hasPrefix("}") || (line.hasPrefix("<") && line.hasSuffix(">")) { n += 1 }
        if operators.contains(where: { line.contains($0) }) { n += 1 }
        // Command-line options: "--target", "-p".
        if words.dropFirst().contains(where: { $0.hasPrefix("--") || ($0.hasPrefix("-") && (2...3).contains($0.count)) }) { n += 1 }
        // A call: identifier immediately followed by parentheses.
        if line.range(of: #"[A-Za-z_][A-Za-z0-9_\.]*\([^)]*\)"#, options: .regularExpression) != nil { n += 1 }
        if line.contains(" = ") || (line.contains("\": ") && line.hasSuffix(",")) { n += 1 }
        return n
    }
}

/// Parses color values in the formats people copy: hex, `rgb()`/`rgba()` and `hsl()`/`hsla()`.
public enum ColorValue {
    public static func parse(_ text: String) -> RGBA? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 64 else { return nil }
        if s.hasPrefix("#") {
            let hex = s.dropFirst()
            guard [3, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            return RGBA(hex: String(hex))
        }
        let lower = s.lowercased()
        if lower.hasPrefix("0x"), s.count == 8, s.dropFirst(2).allSatisfy(\.isHexDigit) {
            return RGBA(hex: String(s.dropFirst(2)))
        }
        for prefix in ["rgba(", "rgb(", "hsla(", "hsl("] where lower.hasPrefix(prefix) && lower.hasSuffix(")") {
            let body = lower.dropFirst(prefix.count).dropLast()
            let parts = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count == 3 || parts.count == 4 else { return nil }
            let alpha = parts.count == 4 ? fraction(parts[3]) : 1
            guard let alpha else { return nil }
            if prefix.hasPrefix("rgb") {
                guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
                return RGBA(red: r, green: g, blue: b, alpha: alpha)
            }
            guard let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                  let sat = percent(parts[1]), let light = percent(parts[2]) else { return nil }
            let (r, g, b) = hslToRGB(h: h, s: sat, l: light)
            return RGBA(red: r, green: g, blue: b, alpha: alpha)
        }
        return nil
    }

    /// 0…255 or a percentage, as 0…1.
    private static func channel(_ s: String) -> Double? {
        if s.hasSuffix("%") { return percent(s) }
        guard let v = Double(s), (0...255).contains(v) else { return nil }
        return v / 255
    }

    private static func percent(_ s: String) -> Double? {
        guard s.hasSuffix("%"), let v = Double(s.dropLast()), (0...100).contains(v) else { return nil }
        return v / 100
    }

    /// 0…1 or a percentage.
    private static func fraction(_ s: String) -> Double? {
        if s.hasSuffix("%") { return percent(s) }
        guard let v = Double(s), (0...1).contains(v) else { return nil }
        return v
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (f(hue + 1 / 3), f(hue), f(hue - 1 / 3))
    }

    /// `rgb(255, 95, 74)`.
    public static func rgbString(_ c: RGBA) -> String {
        let r = Int((c.red * 255).rounded()), g = Int((c.green * 255).rounded()), b = Int((c.blue * 255).rounded())
        return c.alpha < 0.999 ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", c.alpha)))" : "rgb(\(r), \(g), \(b))"
    }

    /// `hsl(7, 100%, 65%)`.
    public static func hslString(_ c: RGBA) -> String {
        let maxV = max(c.red, c.green, c.blue), minV = min(c.red, c.green, c.blue)
        let l = (maxV + minV) / 2
        var h = 0.0, s = 0.0
        if maxV != minV {
            let d = maxV - minV
            s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
            switch maxV {
            case c.red: h = (c.green - c.blue) / d + (c.green < c.blue ? 6 : 0)
            case c.green: h = (c.blue - c.red) / d + 2
            default: h = (c.red - c.green) / d + 4
            }
            h *= 60
        }
        return "hsl(\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

extension ClipItem {
    /// The user's name, or the content's own one-line summary.
    var displayTitle: String {
        if let name, !name.isEmpty { return name }
        switch kind {
        case .image: return String(localized: "Image", comment: "Clipboard entry type")
        case .files:
            return files.count == 1 ? files[0].lastPathComponent
                : String(localized: "\(files.count) files", comment: "A clipboard entry holding several files")
        default:
            let line = ClipText.oneLine(text ?? "")
            return line.isEmpty ? String(localized: "(empty)", comment: "A clipboard entry without text") : line
        }
    }

    /// Whether the entry has text that can be edited or merged.
    var hasText: Bool {
        switch kind {
        case .files: false
        case .image: image == nil && !(text ?? "").isEmpty
        default: !(text ?? "").isEmpty
        }
    }

    /// The text to paste for "Paste as plain text": file paths for files.
    var plainText: String? {
        switch kind {
        case .files: files.map(\.path).joined(separator: "\n")
        default: text
        }
    }

    /// Key that identifies the source app in filters: its bundle id, or its name for older entries.
    var appKey: String? { sourceBundleID ?? sourceApp }

    /// Same content (ignoring id, date, name and pin), for de-duplicating pinboards.
    func hasSameContent(as other: ClipItem) -> Bool {
        kind == other.kind && text == other.text && image == other.image && files == other.files
    }
}
