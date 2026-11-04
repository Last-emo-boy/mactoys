import Foundation

/// URL templates with a `{text}` placeholder.
public enum URLTemplate {
    public static let placeholder = "{text}"

    /// Characters left as they are in an encoded selection (RFC 3986 unreserved).
    private static let unreserved: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    /// The selection percent-encoded for any part of a URL: spaces, `&`, `/`, `?`, `#` and
    /// non-ASCII text are all encoded.
    public static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// The template with every `{text}` replaced by the encoded selection; nil when the result
    /// is not a URL with a scheme.
    public static func expand(_ template: String, text: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let filled = trimmed.replacingOccurrences(of: placeholder, with: encode(text))
        guard let url = URL(string: filled), let scheme = url.scheme, !scheme.isEmpty else { return nil }
        return url
    }

    /// Whether a template produces a URL (checked with sample text).
    public static func isValid(_ template: String) -> Bool {
        expand(template, text: "sample") != nil
    }
}

/// Case conversions offered by Change Case.
public enum CaseTransform: String, CaseIterable, Sendable {
    case upper, lower, title, sentence, camel, snake, kebab

    /// Localized name (captions, accessibility).
    public var title: String {
        switch self {
        case .upper: String(localized: "Uppercase", comment: "Change Case option: ALL CAPITALS")
        case .lower: String(localized: "Lowercase", comment: "Change Case option: all small letters")
        case .title: String(localized: "Title Case", comment: "Change Case option: Capitalize Important Words")
        case .sentence: String(localized: "Sentence case", comment: "Change Case option: capitalize the first word of each sentence")
        case .camel: String(localized: "Camel case", comment: "Change Case option for code identifiers: camelCase")
        case .snake: String(localized: "Snake case", comment: "Change Case option for code identifiers: snake_case")
        case .kebab: String(localized: "Kebab case", comment: "Change Case option for code identifiers: kebab-case")
        }
    }

    /// A sample of the style, shown on the button (not translated: it demonstrates the result).
    public var sample: String {
        switch self {
        case .upper: "ABC"
        case .lower: "abc"
        case .title: "Abc Def"
        case .sentence: "Abc def."
        case .camel: "camelCase"
        case .snake: "snake_case"
        case .kebab: "kebab-case"
        }
    }

    /// Whether the sample is shown in a code font.
    public var isIdentifierStyle: Bool { self == .camel || self == .snake || self == .kebab }

    public func apply(_ text: String) -> String {
        switch self {
        case .upper: text.uppercased()
        case .lower: text.lowercased()
        case .title: Self.titleCase(text)
        case .sentence: Self.sentenceCase(text)
        case .camel, .snake, .kebab: Self.perLine(text) { self.identifier(Self.identifierWords($0)) }
        }
    }

    // MARK: Prose

    /// English minor words kept lower-case inside a title.
    static let minorWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "en", "for", "from", "if", "in", "into",
                                          "nor", "of", "on", "or", "per", "so", "the", "to", "up", "via", "vs", "vs.", "with", "yet"]

    /// Capitalizes words, keeps minor words lower-case except first, last and after a colon,
    /// and leaves words with inner capitals (`iPhone`, `macOS`) alone. All-caps input is lowered first.
    static func titleCase(_ text: String) -> String {
        let source = isAllCaps(text) ? text.lowercased() : text
        let words = tokens(source)
        let wordIndices = words.indices.filter { words[$0].isWord }
        var out = ""
        var afterColon = false
        for (i, token) in words.enumerated() {
            guard token.isWord else {
                out += token.text
                if token.text.contains(":") || token.text.contains("—") { afterColon = true }
                continue
            }
            let first = i == wordIndices.first, last = i == wordIndices.last
            let lower = token.text.lowercased()
            if hasInnerCapital(token.text) {
                out += token.text
            } else if !first && !last && !afterColon && minorWords.contains(lower) {
                out += lower
            } else {
                out += capitalizeFirst(token.text)
            }
            afterColon = false
        }
        return out
    }

    /// Lower-cases everything, then capitalizes the first letter of each sentence and line.
    static func sentenceCase(_ text: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in text.lowercased() {
            if capitalizeNext, ch.isLetter {
                out += String(ch).uppercased()
                capitalizeNext = false
                continue
            }
            out.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "。" || ch == "！" || ch == "？" || ch.isNewline {
                capitalizeNext = true
            } else if ch.isNumber {
                capitalizeNext = false
            }
        }
        return out
    }

    private struct Token {
        var text: String
        var isWord: Bool
    }

    /// Words (letters, digits, inner apostrophes and hyphens) and the separators between them.
    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var inWord = false
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            let joiner = (ch == "'" || ch == "’") && inWord && i + 1 < chars.count && chars[i + 1].isLetter
            let wordChar = ch.isLetter || ch.isNumber || joiner
            if wordChar != inWord, !current.isEmpty {
                result.append(Token(text: current, isWord: inWord))
                current = ""
            }
            inWord = wordChar
            current.append(ch)
        }
        if !current.isEmpty { result.append(Token(text: current, isWord: inWord)) }
        return result
    }

    private static func isAllCaps(_ text: String) -> Bool {
        let letters = text.filter { $0.isLetter && ($0.isUppercase || $0.isLowercase) }
        return letters.count > 1 && letters.allSatisfy(\.isUppercase)
    }

    private static func hasInnerCapital(_ word: String) -> Bool {
        word.dropFirst().contains { $0.isUppercase }
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }

    // MARK: Identifiers

    /// Applies `transform` to each line, keeping blank lines and leading indentation.
    private static func perLine(_ text: String, _ transform: (String) -> String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let body = line.dropFirst(indent.count)
            return body.trimmingCharacters(in: .whitespaces).isEmpty ? String(line) : indent + transform(String(body))
        }
        .joined(separator: "\n")
    }

    /// Splits on anything that isn't a letter or digit and at case boundaries:
    /// `"HTTPServer error-code"` → `["HTTP", "Server", "error", "code"]`.
    static func identifierWords(_ text: String) -> [String] {
        var words: [String] = []
        var current: [Character] = []
        let chars = Array(text)
        func flush() {
            if !current.isEmpty { words.append(String(current)) }
            current = []
        }
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber else { flush(); continue }
            if let prev = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = (prev.isLowercase || prev.isNumber) && ch.isUppercase
                let acronymEnd = prev.isUppercase && ch.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnd { flush() }
            }
            current.append(ch)
        }
        flush()
        return words
    }

    private func identifier(_ words: [String]) -> String {
        let lower = words.map { $0.lowercased() }
        switch self {
        case .camel:
            guard let first = lower.first else { return "" }
            return first + lower.dropFirst().map(Self.capitalizeFirst).joined()
        case .snake: return lower.joined(separator: "_")
        case .kebab: return lower.joined(separator: "-")
        default: return words.joined(separator: " ")
        }
    }
}

/// Character, word and line counts. Chinese and Japanese characters count as one word each,
/// as word processors do; other scripts count runs of letters and digits.
public struct TextStats: Equatable, Sendable {
    public var characters: Int
    public var charactersExcludingSpaces: Int
    public var words: Int
    public var lines: Int
    /// CJK characters, counted for reading time at a different pace.
    public var cjkCharacters: Int

    public init(_ text: String) {
        var chars = 0, nonSpace = 0, words = 0, cjk = 0
        var inWord = false
        var pendingJoiner = false
        var previousWasDigit = false
        for ch in text {
            chars += 1
            if !ch.isWhitespace { nonSpace += 1 }
            if Self.isCJK(ch) {
                words += 1
                cjk += 1
                inWord = false
                pendingJoiner = false
                previousWasDigit = false
                continue
            }
            let alnum = ch.isLetter || ch.isNumber || Self.isMark(ch)
            if alnum {
                if !inWord && !pendingJoiner { words += 1 }
                inWord = true
                pendingJoiner = false
                previousWasDigit = ch.isNumber
            } else if inWord, Self.isJoiner(ch, afterDigit: previousWasDigit) {
                // "don't", "e-mail", "file_name", "3.14": keep counting one word if a letter or digit follows.
                pendingJoiner = true
                inWord = false
            } else {
                inWord = false
                pendingJoiner = false
                previousWasDigit = false
            }
        }
        characters = chars
        charactersExcludingSpaces = nonSpace
        self.words = words
        cjkCharacters = cjk
        if text.isEmpty {
            lines = 0
        } else {
            var count = 1
            for ch in text where ch.isNewline { count += 1 }
            if text.last?.isNewline == true { count -= 1 }
            lines = count
        }
    }

    /// Reading time at about 230 words a minute (400 characters a minute for CJK text).
    public var readingTime: Duration {
        let minutes = Double(words - cjkCharacters) / 230 + Double(cjkCharacters) / 400
        return .seconds(max(1, Int((minutes * 60).rounded())))
    }

    static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,      // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,      // CJK ideographs
             0x20000...0x2FA1F, 0x3005, 0x3007:
            return true
        default:
            return false
        }
    }

    private static func isMark(_ ch: Character) -> Bool {
        ch.unicodeScalars.first.map { $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .spacingMark } ?? false
    }

    private static func isJoiner(_ ch: Character, afterDigit: Bool) -> Bool {
        switch ch {
        case "'", "’", "-", "_", "‐": true
        case ".", ",": afterDigit
        default: false
        }
    }
}

/// Builds Markdown links.
public enum MarkdownLink {
    /// `[text](url)` for text while a link is on the clipboard, or `[example.com/page](url)` when
    /// the selection itself is a link. Nil when neither applies.
    public static func make(selection: String, wholeLink: URL?, clipboardURL: URL?) -> String? {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = wholeLink {
            return "[\(escape(display(url)))](\(url.absoluteString))"
        }
        guard let url = clipboardURL, !text.isEmpty, !text.contains("\n") else { return nil }
        return "[\(escape(text))](\(url.absoluteString))"
    }

    /// Host and path without scheme, `www.` and trailing slash.
    static func display(_ url: URL) -> String {
        var s = url.absoluteString
        if let scheme = url.scheme, s.hasPrefix(scheme + "://") { s.removeFirst(scheme.count + 3) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
