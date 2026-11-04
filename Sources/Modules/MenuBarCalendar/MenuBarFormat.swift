import Foundation

/// One piece of the menu bar text. A format is a list of tokens joined by spaces; text that
/// starts with punctuation (`,` `.` `:` `;`) attaches to what comes before it.
enum MenuBarToken: Codable, Hashable, Sendable, Identifiable {
    case weekday(short: Bool)
    case date(MenuDateStyle)
    case dayOfMonth
    case month(short: Bool)
    case year
    case weekNumber
    case time(seconds: Bool)
    case timeZone
    case text(String)

    var id: String {
        switch self {
        case .weekday(let s): "weekday-\(s)"
        case .date(let d): "date-\(d.rawValue)"
        case .dayOfMonth: "day"
        case .month(let s): "month-\(s)"
        case .year: "year"
        case .weekNumber: "week"
        case .time(let s): "time-\(s)"
        case .timeZone: "zone"
        case .text(let t): "text-\(t)"
        }
    }

    /// "Wed 4 Nov 9:41".
    static let defaultFormat: [MenuBarToken] = [.weekday(short: true), .date(.dayMonth), .time(seconds: false)]

    /// Tokens offered by the format builder, in menu order.
    static let palette: [MenuBarToken] = [
        .weekday(short: true), .weekday(short: false), .date(.dayMonth), .date(.dayMonthYear), .date(.numeric),
        .dayOfMonth, .month(short: true), .month(short: false), .year, .weekNumber,
        .time(seconds: false), .time(seconds: true), .timeZone,
    ]

    /// Separators offered by the format builder.
    static let separators: [MenuBarToken] = [.text("·"), .text("|"), .text("–"), .text(","), .text("/")]

    /// Ready-made formats.
    static let presets: [[MenuBarToken]] = [
        defaultFormat,
        [.weekday(short: true), .date(.dayMonth), .text("·"), .time(seconds: false)],
        [.date(.dayMonthYear)],
        [.weekNumber, .text("·"), .time(seconds: false)],
        [.time(seconds: true), .timeZone],
        [.date(.numeric), .time(seconds: false)],
    ]

    /// The builder's name for this token.
    var title: String {
        switch self {
        case .weekday(let short): short ? String(localized: "Weekday, short", comment: "Menu bar format token, e.g. Wed")
            : String(localized: "Weekday", comment: "Menu bar format token, e.g. Wednesday")
        case .date(let style): style.title
        case .dayOfMonth: String(localized: "Day", comment: "Menu bar format token: day of the month, e.g. 4")
        case .month(let short): short ? String(localized: "Month, short", comment: "Menu bar format token, e.g. Nov")
            : String(localized: "Month", comment: "Menu bar format token, e.g. November")
        case .year: String(localized: "Year", comment: "Menu bar format token")
        case .weekNumber: String(localized: "Week number", comment: "Menu bar format token, e.g. W45")
        case .time(let seconds): seconds ? String(localized: "Time with seconds", comment: "Menu bar format token")
            : String(localized: "Time", comment: "Menu bar format token")
        case .timeZone: String(localized: "Time zone", comment: "Menu bar format token, e.g. CET")
        case .text(let t): t
        }
    }

    var isText: Bool { if case .text = self { true } else { false } }
}

enum MenuDateStyle: String, Codable, Hashable, Sendable {
    /// "4 Nov" or "Nov 4", in the region's order.
    case dayMonth
    /// "4 Nov 2026" or "Nov 4, 2026".
    case dayMonthYear
    /// "04/11/2026" or "11/04/2026".
    case numeric

    var title: String {
        switch self {
        case .dayMonth: String(localized: "Day and month", comment: "Menu bar format token, e.g. 4 Nov")
        case .dayMonthYear: String(localized: "Date with year", comment: "Menu bar format token, e.g. 4 Nov 2026")
        case .numeric: String(localized: "Numeric date", comment: "Menu bar format token, e.g. 04/11/2026")
        }
    }
}

/// Renders menu bar formats. Locale, time zone and calendar are explicit so tests are stable.
struct MenuBarFormatter {
    var locale: Locale
    var timeZone: TimeZone
    var weekNumbering: WeekNumbering = .iso8601
    var calendar: Calendar

    init(locale: Locale = .current, timeZone: TimeZone = .current, hourCycle: HourCycle = .system,
         weekNumbering: WeekNumbering = .iso8601, calendar: Calendar = .current) {
        self.locale = hourCycle.apply(to: locale)
        self.timeZone = timeZone
        self.weekNumbering = weekNumbering
        var cal = calendar
        cal.locale = locale
        cal.timeZone = timeZone
        self.calendar = cal
    }

    private var style: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
    }

    func string(_ token: MenuBarToken, date: Date) -> String {
        switch token {
        case .weekday(let short): date.formatted(style.weekday(short ? .abbreviated : .wide))
        case .date(.dayMonth): date.formatted(style.day().month(.abbreviated))
        case .date(.dayMonthYear): date.formatted(style.day().month(.abbreviated).year())
        case .date(.numeric): date.formatted(style.day(.twoDigits).month(.twoDigits).year())
        case .dayOfMonth: date.formatted(style.day())
        case .month(let short): date.formatted(style.month(short ? .abbreviated : .wide))
        case .year: date.formatted(style.year())
        case .weekNumber:
            String(localized: "W\(WeekMath.weekNumber(of: date, numbering: weekNumbering, calendar: calendar))",
                   comment: "Week number in the menu bar, e.g. W45; keep it short")
        case .time(let seconds):
            seconds ? date.formatted(style.hour().minute().second()) : date.formatted(style.hour().minute())
        case .timeZone: timeZone.abbreviation(for: date) ?? timeZone.identifier
        case .text(let t): t
        }
    }

    /// The whole menu bar text for `tokens`.
    func string(_ tokens: [MenuBarToken], date: Date) -> String {
        var out = ""
        for token in tokens {
            let piece = string(token, date: date).trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let attaches = token.isText && piece.first.map { ",.:;".contains($0) } == true
            if !out.isEmpty && !attaches { out += " " }
            out += piece
        }
        return out
    }

    /// How often the text changes: every second when it shows seconds, else every minute.
    static func refreshInterval(_ tokens: [MenuBarToken]) -> TimeInterval {
        tokens.contains(.time(seconds: true)) ? 1 : 60
    }
}

/// Week numbers and month grids.
enum WeekMath {
    /// The week of the year `date` falls in.
    static func weekNumber(of date: Date, numbering: WeekNumbering, calendar: Calendar) -> Int {
        switch numbering {
        case .iso8601:
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = calendar.timeZone
            return iso.component(.weekOfYear, from: date)
        case .regional:
            return calendar.component(.weekOfYear, from: date)
        }
    }

    /// One day cell of a month grid.
    struct Day: Hashable, Sendable {
        let date: Date
        let day: Int
        let inMonth: Bool
        let isWeekend: Bool
    }

    struct Week: Hashable, Sendable {
        let number: Int
        let days: [Day]
    }

    /// Six weeks covering `month` (any date in it), starting on `firstWeekday` (1 = Sunday).
    /// Six rows keep the panel the same height every month.
    static func monthGrid(for month: Date, firstWeekday: Int, numbering: WeekNumbering, calendar: Calendar) -> [Week] {
        var cal = calendar
        cal.firstWeekday = firstWeekday
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let first = interval.start
        let targetMonth = cal.component(.month, from: first)
        let weekday = cal.component(.weekday, from: first)
        let lead = (weekday - firstWeekday + 7) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -lead, to: first) else { return [] }
        var weeks: [Week] = []
        for row in 0..<6 {
            var days: [Day] = []
            for col in 0..<7 {
                guard let d = cal.date(byAdding: .day, value: row * 7 + col, to: gridStart) else { continue }
                let c = cal.dateComponents([.day, .month, .weekday], from: d)
                days.append(Day(date: d, day: c.day ?? 1, inMonth: c.month == targetMonth,
                                isWeekend: cal.isDateInWeekend(d)))
            }
            // ISO weeks run Monday to Sunday; the row's Thursday decides which one most of it belongs to.
            let reference: Date
            switch numbering {
            case .iso8601:
                reference = days.first { cal.component(.weekday, from: $0.date) == 5 }?.date ?? days[0].date
            case .regional:
                reference = days[0].date
            }
            var numberingCal = cal
            numberingCal.firstWeekday = firstWeekday
            weeks.append(Week(number: weekNumber(of: reference, numbering: numbering, calendar: numberingCal), days: days))
        }
        return weeks
    }

    /// Short weekday headers in grid order ("M", "T", …) for `firstWeekday`.
    static func weekdayHeaders(firstWeekday: Int, calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(firstWeekday - 1 + $0) % 7] }
    }
}
