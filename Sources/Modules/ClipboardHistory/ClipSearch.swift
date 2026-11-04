import Foundation
import MacToysCore

/// Which entries the panel shows, besides the search text.
struct ClipFilter: Equatable {
    /// Recency windows for the date filter.
    enum DateRange: String, CaseIterable, Identifiable {
        case any, today, yesterday, week, month

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: String(localized: "Any date", comment: "Clipboard date filter: no restriction")
            case .today: String(localized: "Today", comment: "Clipboard date filter")
            case .yesterday: String(localized: "Yesterday", comment: "Clipboard date filter")
            case .week: String(localized: "Last 7 days", comment: "Clipboard date filter")
            case .month: String(localized: "Last 30 days", comment: "Clipboard date filter")
            }
        }

        func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
            switch self {
            case .any: true
            case .today: calendar.isDate(date, inSameDayAs: now)
            case .yesterday:
                calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
            case .week: now.timeIntervalSince(date) <= 7 * 86_400
            case .month: now.timeIntervalSince(date) <= 30 * 86_400
            }
        }
    }

    var type: ClipContentType?
    var pinnedOnly = false
    /// `ClipItem.appKey` of the source app.
    var app: String?
    var date: DateRange = .any

    var isActive: Bool { type != nil || pinnedOnly || app != nil || date != .any }

    func matches(_ item: ClipItem, now: Date, calendar: Calendar) -> Bool {
        if let type, ClipContentType.of(item) != type { return false }
        if pinnedOnly, !item.pinned { return false }
        if let app, item.appKey != app { return false }
        return date.contains(item.date, now: now, calendar: calendar)
    }
}

/// Search over clipboard entries and snippets.
///
/// Every word of the query has to appear somewhere (name, text, link host, file names, or at a word start
/// of the source app or type); a word at the start of the name or text counts most, then at the start of
/// any word, then anywhere. A word that appears nowhere may still match the title as a close subsequence
/// ("gthb" → "github"), weakly.
/// Results are ordered by score, then newest first.
enum ClipSearch {
    static func results(_ items: [ClipItem], query: String, filter: ClipFilter = ClipFilter(),
                        now: Date = Date(), calendar: Calendar = .current) -> [ClipItem] {
        let filtered = items.filter { filter.matches($0, now: now, calendar: calendar) }
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else { return filtered }
        let scored = filtered.compactMap { item in score(item, tokens: tokens).map { (item, $0) } }
        return scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.date > b.0.date
        }.map(\.0)
    }

    static func tokens(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Nil when some query word matches nowhere.
    static func score(_ item: ClipItem, tokens: [String]) -> Double? {
        // (text, weight, lowest match quality that counts)
        var fields: [(String, Double, Double)] = []
        if let name = item.name, !name.isEmpty { fields.append((name, 3, 1)) }
        switch item.kind {
        case .files:
            fields.append((item.files.map(\.lastPathComponent).joined(separator: " "), 2, 1))
            fields.append((item.files.map(\.path).joined(separator: " "), 0.5, 1))
        case .image:
            if let text = item.text { fields.append((String(text.prefix(2000)), 1, 1)) }
        default:
            let text = item.text ?? ""
            if let url = ClipText.link(in: text) { fields.append((ClipText.host(of: url), 2, 1)) }
            fields.append((String(text.prefix(4000)), 1, 1))
        }
        // "view" shouldn't find everything copied in Preview.
        if let app = item.sourceApp { fields.append((app, 0.5, 2)) }
        fields.append((ClipContentType.of(item).filterTitle, 0.25, 2))

        var total = 0.0
        for token in tokens {
            var best = 0.0
            for (field, weight, minimum) in fields {
                let q = quality(of: token, in: field)
                if q >= minimum { best = max(best, weight * q) }
            }
            if best == 0, isSubsequence(token, of: item.displayTitle) { best = 0.3 }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    /// 4 whole field, 3 start of the field, 2 start of a word, 1 anywhere, 0 not found.
    static func quality(of token: String, in field: String) -> Double {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        guard let range = field.range(of: token, options: options) else { return 0 }
        if range.lowerBound == field.startIndex {
            return range.upperBound == field.endIndex ? 4 : 3
        }
        var search = range
        while true {
            let before = field[field.index(before: search.lowerBound)]
            if !before.isLetter && !before.isNumber { return 2 }
            guard search.upperBound < field.endIndex,
                  let next = field.range(of: token, options: options, range: search.upperBound..<field.endIndex) else { break }
            search = next
        }
        return 1
    }

    /// Case- and diacritic-insensitive subsequence test within the first 200 characters of `text`. The
    /// letters have to lie close together (within twice the token's length, plus two), so a long URL
    /// doesn't match every word whose letters it happens to contain in order.
    static func isSubsequence(_ token: String, of text: String) -> Bool {
        let needle = Array(token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        guard needle.count >= 3 else { return false }
        let hay = Array(text.prefix(200).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        let window = needle.count * 2 + 2
        for start in hay.indices where hay[start] == needle[0] {
            var i = 1, j = start + 1
            while i < needle.count, j < hay.count, j - start < window {
                if hay[j] == needle[i] { i += 1 }
                j += 1
            }
            if i == needle.count { return true }
        }
        return false
    }

    /// Snippets matching a query: an exact abbreviation first, then abbreviation prefixes, names and text.
    static func snippets(_ snippets: [Snippet], query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return snippets }
        let tokens = Self.tokens(trimmed)
        let scored: [(Snippet, Double)] = snippets.compactMap { snippet in
            let abbreviation = snippet.abbreviation
            if !abbreviation.isEmpty, abbreviation.compare(trimmed, options: [.caseInsensitive]) == .orderedSame {
                return (snippet, 100)
            }
            var total = 0.0
            for token in tokens {
                let best = max(abbreviation.isEmpty ? 0 : 3 * quality(of: token, in: abbreviation),
                               2 * quality(of: token, in: snippet.name),
                               0.5 * quality(of: token, in: String(snippet.text.prefix(2000))))
                guard best > 0 else { return nil }
                total += best
            }
            return (snippet, total)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
            .map(\.0)
    }
}
