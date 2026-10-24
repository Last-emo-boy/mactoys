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
    public static let help: [(token: String, meaning: String)] = [
        ("$YYYY", "Year, four digits"), ("$YY", "Year, last two digits"), ("$Y", "Year, last digit"),
        ("$MMMM", "Month name"), ("$MMM", "Abbreviated month name"), ("$MM", "Month, two digits"),
        ("$M", "Month"), ("$DDDD", "Weekday name"), ("$DDD", "Abbreviated weekday name"),
        ("$DD", "Day, two digits"), ("$D", "Day"), ("$hh", "Hours, two digits (24-hour)"), ("$h", "Hours"),
        ("$mm", "Minutes, two digits"), ("$m", "Minutes"), ("$ss", "Seconds, two digits"), ("$s", "Seconds"),
        ("$fff", "Milliseconds, three digits"), ("$ff", "Milliseconds, first two digits"),
        ("$f", "Milliseconds, first digit"),
    ]

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
