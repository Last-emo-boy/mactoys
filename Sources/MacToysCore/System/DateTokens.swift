import Foundation

/// The PowerToys date and time variables shared by PowerRename and New+:
/// `$YYYY $YY $Y $MMMM $MMM $MM $M $DDDD $DDD $DD $D $hh $h $mm $m $ss $s $fff $ff $f`.
/// Tokens are case-sensitive (`$MM` is the month, `$mm` the minutes) and the longest one wins.
public enum DateTokens {
    /// Every token name without the `$`, longest first.
    public static let names: [String] = [
        "YYYY", "MMMM", "DDDD",
        "MMM", "DDD", "fff",
        "YY", "MM", "DD", "hh", "mm", "ss", "ff",
        "Y", "M", "D", "h", "m", "s", "f",
    ]

    /// Short descriptions for pickers and tooltips, in display order.
    public static var help: [(token: String, meaning: String)] {
        [
        ("$YYYY", String(localized: "Year, four digits", comment: "Meaning of the date token $YYYY in file names")), ("$YY", String(localized: "Year, last two digits", comment: "Meaning of the date token $YY in file names")), ("$Y", String(localized: "Year, last digit", comment: "Meaning of the date token $Y in file names")),
        ("$MMMM", String(localized: "Month name", comment: "Meaning of the date token $MMMM in file names")), ("$MMM", String(localized: "Abbreviated month name", comment: "Meaning of the date token $MMM in file names")), ("$MM", String(localized: "Month, two digits", comment: "Meaning of the date token $MM in file names")),
        ("$M", String(localized: "Month", comment: "Meaning of the date token $M in file names")), ("$DDDD", String(localized: "Weekday name", comment: "Meaning of the date token $DDDD in file names")), ("$DDD", String(localized: "Abbreviated weekday name", comment: "Meaning of the date token $DDD in file names")),
        ("$DD", String(localized: "Day, two digits", comment: "Meaning of the date token $DD in file names")), ("$D", String(localized: "Day", comment: "Meaning of the date token $D in file names")), ("$hh", String(localized: "Hours, two digits (24-hour)", comment: "Meaning of the date token $hh in file names")), ("$h", String(localized: "Hours", comment: "Meaning of the date token $h in file names")),
        ("$mm", String(localized: "Minutes, two digits", comment: "Meaning of the date token $mm in file names")), ("$m", String(localized: "Minutes", comment: "Meaning of the date token $m in file names")), ("$ss", String(localized: "Seconds, two digits", comment: "Meaning of the date token $ss in file names")), ("$s", String(localized: "Seconds", comment: "Meaning of the date token $s in file names")),
        ("$fff", String(localized: "Milliseconds, three digits", comment: "Meaning of the date token $fff in file names")), ("$ff", String(localized: "Milliseconds, first two digits", comment: "Meaning of the date token $ff in file names")),
        ("$f", String(localized: "Milliseconds, first digit", comment: "Meaning of the date token $f in file names")),
        ]
    }

    /// The longest token name that `text` starts with (the text right after a `$`), if any.
    public static func match<S: StringProtocol>(_ text: S) -> String? {
        names.first { text.hasPrefix($0) }
    }

    /// The value of one token (name without `$`) for `date`.
    public static func value(of token: String, date: Date, calendar: Calendar = .current,
                             locale: Locale = .current) -> String {
        var cal = calendar
        cal.locale = locale
        let c = cal.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second, .nanosecond], from: date)
        let year = c.year ?? 0, month = c.month ?? 1, day = c.day ?? 1, weekday = c.weekday ?? 1
        // Dates are doubles: 7 ms can come back as 6.999999 ms, so round to the microsecond first.
        let ms = min(999, ((c.nanosecond ?? 0) + 500) / 1000 / 1000)
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        switch token {
        case "YYYY": return pad(year, 4)
        case "YY": return pad(year % 100, 2)
        case "Y": return String(year % 10)
        case "MMMM": return cal.standaloneMonthSymbols[(month - 1) % 12]
        case "MMM": return cal.shortStandaloneMonthSymbols[(month - 1) % 12]
        case "MM": return pad(month, 2)
        case "M": return String(month)
        case "DDDD": return cal.weekdaySymbols[(weekday - 1) % 7]
        case "DDD": return cal.shortWeekdaySymbols[(weekday - 1) % 7]
        case "DD": return pad(day, 2)
        case "D": return String(day)
        case "hh": return pad(c.hour ?? 0, 2)
        case "h": return String(c.hour ?? 0)
        case "mm": return pad(c.minute ?? 0, 2)
        case "m": return String(c.minute ?? 0)
        case "ss": return pad(c.second ?? 0, 2)
        case "s": return String(c.second ?? 0)
        case "fff": return pad(ms, 3)
        case "ff": return pad(ms / 10, 2)
        case "f": return String(ms / 100)
        default: return "$" + token
        }
    }

    /// Replaces every date token in `text`. A `$` that starts no token is kept as is.
    public static func expand(_ text: String, date: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            let next = text.index(after: i)
            if ch == "$", let token = match(text[next...]) {
                out += value(of: token, date: date, calendar: calendar, locale: locale)
                i = text.index(next, offsetBy: token.count)
            } else {
                out.append(ch)
                i = next
            }
        }
        return out
    }
}
