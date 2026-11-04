import Foundation

/// Saved text that pastes from the panel, by name or by typing its abbreviation in the search field.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    /// Short trigger typed in the search field ("sig", ";addr"). Optional.
    public var abbreviation: String
    /// The template, with `{date}`-style placeholders.
    public var text: String

    public init(name: String, abbreviation: String = "", text: String) {
        self.name = name
        self.abbreviation = abbreviation
        self.text = text
    }
}

/// Fills a snippet's placeholders at paste time.
///
/// `{date}` `{time}` `{datetime}` in the user's locale, `{date:yyyy-MM-dd}` with any date pattern,
/// `{clipboard}` the current clipboard text, `{cursor}` where the insertion point goes after pasting.
/// Placeholder names are case-insensitive; anything else in braces is kept as typed.
public enum SnippetExpander {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// Characters between `{cursor}` and the end of the text: how far to move left after pasting.
        public var cursorOffset: Int?
    }

    public enum Placeholder: String, CaseIterable, Identifiable, Sendable {
        case date, time, datetime, clipboard, cursor

        public var id: String { rawValue }
        public var token: String { "{\(rawValue)}" }

        public var title: String {
            switch self {
            case .date: String(localized: "Date", comment: "Snippet placeholder button: inserts today's date")
            case .time: String(localized: "Time", comment: "Snippet placeholder button: inserts the current time")
            case .datetime: String(localized: "Date & time", comment: "Snippet placeholder button")
            case .clipboard: String(localized: "Clipboard", comment: "Snippet placeholder button: inserts the clipboard text")
            case .cursor: String(localized: "Cursor", comment: "Snippet placeholder button: where the text cursor ends up after pasting")
            }
        }

        public var help: String {
            switch self {
            case .date: String(localized: "Today's date. Use {date:yyyy-MM-dd} for a custom format.")
            case .time: String(localized: "The current time.")
            case .datetime: String(localized: "Today's date and the current time.")
            case .clipboard: String(localized: "The text on the clipboard when you paste.")
            case .cursor: String(localized: "Puts the text cursor here after pasting.")
            }
        }
    }

    public static func expand(_ template: String, date: Date = Date(), clipboard: String? = nil,
                              locale: Locale = .current, timeZone: TimeZone = .current) -> Result {
        var out = ""
        var cursorMark: Int?
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            // The nearest brace pair: in "{ return {date} }" the outer braces stay as typed.
            guard ch == "{", let close = template[template.index(after: i)...].firstIndex(where: { $0 == "{" || $0 == "}" }),
                  template[close] == "}" else {
                out.append(ch)
                i = template.index(after: i)
                continue
            }
            let body = template[template.index(after: i)..<close]
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let argument = parts.count > 1 ? String(parts[1]) : nil
            if let value = value(of: name, argument: argument, date: date, clipboard: clipboard, locale: locale, timeZone: timeZone) {
                out += value
            } else if name == Placeholder.cursor.rawValue, argument == nil {
                if cursorMark == nil { cursorMark = out.count }
            } else {
                out += template[i...close]
            }
            i = template.index(after: close)
        }
        return Result(text: out, cursorOffset: cursorMark.map { out.count - $0 })
    }

    private static func value(of name: String, argument: String?, date: Date, clipboard: String?,
                              locale: Locale, timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        func style(_ d: Date.FormatStyle.DateStyle, _ t: Date.FormatStyle.TimeStyle) -> String {
            date.formatted(Date.FormatStyle(date: d, time: t, locale: locale, calendar: calendar, timeZone: timeZone))
        }
        switch (name, argument) {
        case ("date", nil): return style(.long, .omitted)
        case ("time", nil): return style(.omitted, .shortened)
        case ("datetime", nil): return style(.abbreviated, .shortened)
        case ("date", let pattern?) where !pattern.isEmpty:
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: date)
        case ("clipboard", nil): return clipboard ?? ""
        default: return nil
        }
    }
}
