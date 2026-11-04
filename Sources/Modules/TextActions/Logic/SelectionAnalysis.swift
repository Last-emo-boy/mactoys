import Foundation

/// What a selection contains, detected once per selection.
public struct SelectionAnalysis: Sendable {
    public let text: String
    public let trimmed: String
    /// Web and app links (not `mailto:`), in order of appearance.
    public let links: [URL]
    /// The selection is exactly one link.
    public let wholeLink: URL?
    public let emails: [String]
    public let phoneNumbers: [String]
    public let addresses: [String]
    /// An absolute path (tilde expanded) when the selection looks like one.
    public let pathCandidate: String?
    /// The value when the selection is an arithmetic expression.
    public let calculation: Double?
    /// Re-indented and minified JSON when the selection is a JSON object or array.
    public let prettyJSON: String?
    public let minifiedJSON: String?
    public let isSingleLine: Bool
    /// One word: letters (and inner apostrophes or hyphens), no spaces.
    public let isSingleWord: Bool
    /// A short phrase worth looking up: up to three words and 48 characters.
    public let isShortPhrase: Bool
    public let hasLetters: Bool
    /// Letters that have an upper and a lower case.
    public let hasCasedLetters: Bool

    /// Data detectors only look at this much text.
    static let detectionLimit = 20_000
    static let jsonLimit = 2_000_000

    public init(_ text: String) {
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trimmed = trimmed
        isSingleLine = !trimmed.contains(where: \.isNewline)
        hasLetters = trimmed.contains(where: \.isLetter)
        hasCasedLetters = trimmed.contains { $0.isUppercase || $0.isLowercase }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        isSingleWord = words.count == 1 && trimmed.count <= 48 && trimmed.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            && trimmed.first?.isLetter == true
        isShortPhrase = (1...3).contains(words.count) && trimmed.count <= 48 && isSingleLine && hasLetters
            && !trimmed.contains(where: { $0.isNumber || "/@:{}<>=".contains($0) })

        var links: [URL] = [], emails: [String] = [], phones: [String] = [], addresses: [String] = []
        var wholeLink: URL?
        if !trimmed.isEmpty, trimmed.utf16.count <= Self.detectionLimit {
            let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address]
            if let detector = try? NSDataDetector(types: types.rawValue) {
                let ns = trimmed as NSString
                let full = NSRange(location: 0, length: ns.length)
                for match in detector.matches(in: trimmed, options: [], range: full) {
                    switch match.resultType {
                    case .link:
                        guard let url = match.url else { continue }
                        if url.scheme?.lowercased() == "mailto" {
                            let address = String(url.absoluteString.dropFirst("mailto:".count))
                            emails.append(address.removingPercentEncoding ?? address)
                        } else if Self.isOpenable(url) {
                            links.append(url)
                            if match.range == full { wholeLink = url }
                        }
                    case .phoneNumber:
                        if let number = match.phoneNumber, number.filter(\.isNumber).count >= 6 { phones.append(number) }
                    case .address:
                        addresses.append(ns.substring(with: match.range))
                    default:
                        break
                    }
                }
            }
        }
        self.links = links
        self.wholeLink = wholeLink
        self.emails = emails
        self.phoneNumbers = phones
        self.addresses = addresses
        pathCandidate = Self.path(from: trimmed)
        calculation = ArithmeticEvaluator.evaluateIfExpression(trimmed)
        if trimmed.utf8.count <= Self.jsonLimit, JSONFormatter.isContainer(trimmed) {
            prettyJSON = JSONFormatter.pretty(trimmed)
            minifiedJSON = JSONFormatter.minify(trimmed)
        } else {
            prettyJSON = nil
            minifiedJSON = nil
        }
    }

    /// File URLs are revealed, not opened as links.
    private static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme != "file" && scheme != "tel"
    }

    /// `/Users/me/file.txt`, `~/Documents`, `file:///tmp/x` → an absolute path.
    static func path(from text: String) -> String? {
        guard !text.isEmpty, text.count <= 1024, !text.contains(where: \.isNewline) else { return nil }
        var candidate = text
        if candidate.count >= 2, let first = candidate.first, let last = candidate.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        if candidate.hasPrefix("file://"), let url = URL(string: candidate), url.isFileURL {
            return url.path
        }
        if candidate == "~" || candidate.hasPrefix("~/") {
            return (candidate as NSString).expandingTildeInPath
        }
        if candidate.hasPrefix("/"), candidate.count > 1 || candidate == "/" {
            // Shell-escaped spaces ("My\ File.txt") are common in copied paths.
            return candidate.replacingOccurrences(of: "\\ ", with: " ")
        }
        return nil
    }
}

/// Facts about a selection that need the system (files, dictionaries, the spell checker,
/// the clipboard), gathered before deciding which actions to show.
public struct SelectionContext: Equatable, Sendable {
    public var isEditable = false
    public var clipboardHasText = false
    /// A link on the clipboard, for Markdown Link.
    public var clipboardURL: URL?
    /// `pathCandidate` exists on disk.
    public var pathExists = false
    /// The dictionary has an entry for the selection.
    public var hasDefinition = false
    /// The single word is misspelled and has suggestions.
    public var isMisspelled = false
    /// The text is already in the language Translate would produce.
    public var isInTargetLanguage = false

    public init(isEditable: Bool = false, clipboardHasText: Bool = false, clipboardURL: URL? = nil, pathExists: Bool = false,
                hasDefinition: Bool = false, isMisspelled: Bool = false, isInTargetLanguage: Bool = false) {
        self.isEditable = isEditable
        self.clipboardHasText = clipboardHasText
        self.clipboardURL = clipboardURL
        self.pathExists = pathExists
        self.hasDefinition = hasDefinition
        self.isMisspelled = isMisspelled
        self.isInTargetLanguage = isInTargetLanguage
    }
}

/// Which actions fit a selection.
public enum ActionRelevance {
    public static let searchLimit = 500
    public static let translateLimit = 5_000
    public static let transformLimit = 200_000

    public static func applies(_ action: BuiltInAction, _ a: SelectionAnalysis, _ c: SelectionContext) -> Bool {
        let hasText = !a.trimmed.isEmpty
        switch action {
        case .copy: return hasText
        case .cut: return hasText && c.isEditable
        case .paste: return c.isEditable && c.clipboardHasText
        case .openLink: return !a.links.isEmpty
        case .email: return !a.emails.isEmpty
        case .map: return !a.addresses.isEmpty
        case .call: return !a.phoneNumbers.isEmpty && a.calculation == nil
        case .revealPath: return a.pathCandidate != nil && c.pathExists
        case .spelling: return a.isSingleWord && c.isMisspelled
        case .search: return hasText && a.trimmed.count <= searchLimit
        case .lookUp: return a.isShortPhrase && c.hasDefinition && a.wholeLink == nil
        case .translate: return a.hasLetters && a.trimmed.count <= translateLimit && !c.isInTargetLanguage
            && a.wholeLink == nil && a.pathCandidate == nil && a.prettyJSON == nil
        case .calculate: return a.calculation != nil
        case .formatJSON: return a.prettyJSON.map { $0 != a.trimmed } ?? false
        case .minifyJSON: return a.minifiedJSON.map { $0 != a.trimmed && a.trimmed.contains(where: \.isNewline) } ?? false
        case .markdownLink:
            return MarkdownLink.make(selection: a.trimmed, wholeLink: a.wholeLink,
                                     clipboardURL: a.trimmed.count <= 200 && a.wholeLink == nil ? c.clipboardURL : nil) != nil
        case .changeCase: return a.hasCasedLetters && a.text.utf16.count <= transformLimit
        case .count: return hasText
        case .speak: return hasText && (a.hasLetters || a.trimmed.contains(where: \.isNumber))
        }
    }

    public static func applies(_ custom: CustomAction, _ a: SelectionAnalysis, _ c: SelectionContext) -> Bool {
        guard custom.isComplete, !a.trimmed.isEmpty else { return false }
        switch custom.condition {
        case .any: return true
        case .link: return !a.links.isEmpty
        case .email: return !a.emails.isEmpty
        case .path: return a.pathCandidate != nil && c.pathExists
        case .number: return a.calculation != nil || Double(a.trimmed.replacingOccurrences(of: ",", with: "")) != nil
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: custom.pattern) else { return false }
            let ns = a.text as NSString
            return regex.firstMatch(in: a.text, range: NSRange(location: 0, length: ns.length)) != nil
        }
    }
}
