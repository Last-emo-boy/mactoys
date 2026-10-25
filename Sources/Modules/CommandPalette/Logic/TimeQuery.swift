import Foundation

/// What a Time & Date query asks for.
enum TimeQuery: Equatable {
    enum Focus: String, Equatable { case all, time, date, unix, iso, week, utc }

    /// The current moment, highlighting one format.
    case now(Focus)
    /// The current time in another zone (`time in London`, `tokyo time`).
    case zone(TimeZone, label: String)
    /// A parsed moment (`unix 1792852868`, `2026-10-24 10:30`).
    case instant(Date)
    /// The calendar week of a date (`week::2026-10-24`).
    case week(Date)
    /// The Unix timestamp of a date (`unix::2026-10-24 10:30`).
    case unixOf(Date)

    /// Parses a query. Global (unscoped) queries must start with a complete keyword, as in PowerToys;
    /// scoped queries (`)` keyword, the Time & Date page) also accept bare dates, numbers and places.
    static func parse(_ raw: String, scoped: Bool) -> TimeQuery? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()
        if lower.isEmpty { return scoped ? .now(.all) : nil }

        if let sep = lower.range(of: "::") {
            let key = lower[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = String(text[sep.upperBound...])
            guard let date = DateParsing.parse(value) else { return nil }
            switch key {
            case "week", "calendar week", "cw": return .week(date)
            case "unix", "unix epoch", "epoch", "timestamp": return .unixOf(date)
            default: return scoped ? .instant(date) : nil
            }
        }

        let words = lower.split(separator: " ").map(String.init)
        let first = words[0]
        let rest = words.dropFirst().joined(separator: " ")
        let restOriginal = text.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""

        switch first {
        case "time", "clock", "now":
            if rest.isEmpty { return .now(.time) }
            var place = rest
            if place.hasPrefix("in ") { place.removeFirst(3) }
            if place.hasPrefix("at ") { place.removeFirst(3) }
            if let (tz, label) = TimeZoneLookup.find(place) { return .zone(tz, label: label) }
            return nil
        case "date", "today":
            return rest.isEmpty ? .now(.date) : nil
        case "unix", "epoch", "timestamp":
            if rest.isEmpty { return .now(.unix) }
            if let d = unixDate(rest, minDigits: 1) { return .instant(d) }
            if let d = DateParsing.parse(restOriginal) { return .unixOf(d) }
            return nil
        case "iso", "iso8601":
            return rest.isEmpty ? .now(.iso) : nil
        case "week", "cw":
            if rest.isEmpty { return .now(.week) }
            return DateParsing.parse(restOriginal).map { .week($0) }
        case "calendar" where rest == "week":
            return .now(.week)
        case "utc", "gmt":
            if rest.isEmpty, let utc = TimeZone(identifier: "UTC") { return .zone(utc, label: "UTC") }
        default:
            break
        }

        // "<place> time"
        if words.count >= 2, words.last == "time" {
            let place = words.dropLast().joined(separator: " ")
            if let (tz, label) = TimeZoneLookup.find(place) { return .zone(tz, label: label) }
        }
        if let (tz, label) = TimeZoneLookup.offsetZone(lower) { return .zone(tz, label: label) }

        guard scoped else { return nil }
        if let d = unixDate(lower) { return .instant(d) }
        if let d = DateParsing.parse(text) { return .instant(d) }
        if let (tz, label) = TimeZoneLookup.find(lower) { return .zone(tz, label: label) }
        return nil
    }

    /// A whole number of `minDigits`…13 digits as a Unix timestamp; 12+ digits are milliseconds.
    static func unixDate(_ s: String, minDigits: Int = 9) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard (minDigits...13).contains(t.count), t.allSatisfy(\.isNumber), let n = Double(t) else { return nil }
        return Date(timeIntervalSince1970: t.count >= 12 ? n / 1000 : n)
    }
}

/// Lenient date parsing for user input.
enum DateParsing {
    private static let posix = Locale(identifier: "en_US_POSIX")

    private static let patterns = [
        "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm",
        "yyyy/MM/dd", "dd.MM.yyyy HH:mm", "dd.MM.yyyy", "d MMM yyyy HH:mm", "d MMM yyyy", "d MMMM yyyy",
        "MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy", "MMMM d yyyy", "EEE, d MMM yyyy HH:mm:ss Z",
    ]

    static func parse(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.contains(where: \.isNumber) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = posix
        f.timeZone = timeZone
        f.isLenient = false
        for p in patterns {
            f.dateFormat = p
            if let d = f.date(from: s) { return d }
        }
        // The user's own short and medium formats (e.g. 10/24/2026 or 24/10/2026).
        let local = DateFormatter()
        local.timeZone = timeZone
        for (ds, ts) in [(DateFormatter.Style.short, DateFormatter.Style.short), (.short, .none),
                         (.medium, .none), (.medium, .short), (.long, .none)] {
            local.dateStyle = ds
            local.timeStyle = ts
            if let d = local.date(from: s) { return d }
        }
        return nil
    }
}

/// Finds a time zone by city, country, abbreviation or UTC offset.
enum TimeZoneLookup {
    /// Common places that are not the city of a time zone identifier.
    static let aliases: [String: String] = [
        "san francisco": "America/Los_Angeles", "seattle": "America/Los_Angeles", "silicon valley": "America/Los_Angeles",
        "california": "America/Los_Angeles", "las vegas": "America/Los_Angeles", "portland": "America/Los_Angeles",
        "washington": "America/New_York", "boston": "America/New_York", "miami": "America/New_York",
        "atlanta": "America/New_York", "philadelphia": "America/New_York", "dallas": "America/Chicago",
        "houston": "America/Chicago", "austin": "America/Chicago", "san diego": "America/Los_Angeles",
        "beijing": "Asia/Shanghai", "china": "Asia/Shanghai", "shenzhen": "Asia/Shanghai", "guangzhou": "Asia/Shanghai",
        "hangzhou": "Asia/Shanghai", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata",
        "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "india": "Asia/Kolkata", "japan": "Asia/Tokyo",
        "osaka": "Asia/Tokyo", "kyoto": "Asia/Tokyo", "korea": "Asia/Seoul", "uk": "Europe/London",
        "england": "Europe/London", "britain": "Europe/London", "germany": "Europe/Berlin", "munich": "Europe/Berlin",
        "frankfurt": "Europe/Berlin", "hamburg": "Europe/Berlin", "france": "Europe/Paris", "spain": "Europe/Madrid",
        "barcelona": "Europe/Madrid", "italy": "Europe/Rome", "milan": "Europe/Rome", "netherlands": "Europe/Amsterdam",
        "switzerland": "Europe/Zurich", "geneva": "Europe/Zurich", "sweden": "Europe/Stockholm",
        "norway": "Europe/Oslo", "finland": "Europe/Helsinki", "poland": "Europe/Warsaw", "russia": "Europe/Moscow",
        "turkey": "Europe/Istanbul", "israel": "Asia/Jerusalem", "tel aviv": "Asia/Jerusalem", "uae": "Asia/Dubai",
        "abu dhabi": "Asia/Dubai", "saudi arabia": "Asia/Riyadh", "egypt": "Africa/Cairo", "kenya": "Africa/Nairobi",
        "nigeria": "Africa/Lagos", "south africa": "Africa/Johannesburg", "cape town": "Africa/Johannesburg",
        "brazil": "America/Sao_Paulo", "rio de janeiro": "America/Sao_Paulo", "rio": "America/Sao_Paulo",
        "argentina": "America/Argentina/Buenos_Aires", "buenos aires": "America/Argentina/Buenos_Aires",
        "mexico": "America/Mexico_City", "canada": "America/Toronto", "ottawa": "America/Toronto",
        "montreal": "America/Toronto", "australia": "Australia/Sydney", "canberra": "Australia/Sydney",
        "new zealand": "Pacific/Auckland", "wellington": "Pacific/Auckland", "thailand": "Asia/Bangkok",
        "vietnam": "Asia/Ho_Chi_Minh", "hanoi": "Asia/Bangkok", "saigon": "Asia/Ho_Chi_Minh",
        "indonesia": "Asia/Jakarta", "philippines": "Asia/Manila", "malaysia": "Asia/Kuala_Lumpur",
        "taiwan": "Asia/Taipei", "hong kong": "Asia/Hong_Kong", "hawaii": "Pacific/Honolulu", "alaska": "America/Anchorage",
        "pacific": "America/Los_Angeles", "eastern": "America/New_York", "central": "America/Chicago",
        "mountain": "America/Denver", "ireland": "Europe/Dublin", "portugal": "Europe/Lisbon", "greece": "Europe/Athens",
        "ukraine": "Europe/Kyiv", "kiev": "Europe/Kyiv", "pakistan": "Asia/Karachi", "bangladesh": "Asia/Dhaka",
        "nepal": "Asia/Kathmandu", "iran": "Asia/Tehran", "iceland": "Atlantic/Reykjavik",
    ]

    /// The display name of a zone: "Asia/Shanghai" → "Shanghai".
    static func city(of tz: TimeZone) -> String {
        let id = tz.identifier
        if id == "UTC" || id == "GMT" { return id }
        return (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ")
    }

    static func find(_ raw: String) -> (TimeZone, String)? {
        let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard name.count >= 2 else { return nil }
        if name == "utc" || name == "gmt" || name == "z" || name == "zulu",
           let utc = TimeZone(identifier: "UTC") { return (utc, "UTC") }
        if let z = offsetZone(name) { return z }
        if let id = aliases[name], let tz = TimeZone(identifier: id) { return (tz, raw.trimmingCharacters(in: .whitespaces).capitalized) }
        let ids = TimeZone.knownTimeZoneIdentifiers
        for id in ids {
            let cityName = (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ").lowercased()
            if cityName == name || id.lowercased() == name, let tz = TimeZone(identifier: id) { return (tz, city(of: tz)) }
        }
        if name.count <= 5, name.allSatisfy(\.isLetter),
           let mapped = TimeZone.abbreviationDictionary[name.uppercased()], let tz = TimeZone(identifier: mapped) {
            return (tz, name.uppercased())
        }
        if name.count >= 4 {
            for id in ids {
                let cityName = (id.split(separator: "/").last.map(String.init) ?? id).replacingOccurrences(of: "_", with: " ").lowercased()
                if cityName.hasPrefix(name), let tz = TimeZone(identifier: id) { return (tz, city(of: tz)) }
            }
        }
        return nil
    }

    /// `utc+8`, `gmt-5:30`, `+0530`.
    static func offsetZone(_ raw: String) -> (TimeZone, String)? {
        var s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        for prefix in ["utc", "gmt"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let body = s.dropFirst()
        var hours = 0, minutes = 0
        if let colon = body.firstIndex(of: ":") {
            guard let h = Int(body[..<colon]), let m = Int(body[body.index(after: colon)...]) else { return nil }
            (hours, minutes) = (h, m)
        } else if body.count == 4, let v = Int(body) {
            (hours, minutes) = (v / 100, v % 100)
        } else if let h = Int(body) {
            hours = h
        } else {
            return nil
        }
        guard hours <= 14, minutes < 60 else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        guard let tz = TimeZone(secondsFromGMT: seconds) else { return nil }
        return (tz, TimeFormats.offsetLabel(seconds))
    }
}

/// Builds the displayed formats of a moment.
enum TimeFormats {
    struct Row: Equatable, Hashable {
        /// Stable name of the format (`Unix`, `Week`, a custom format's name); `label` is what is shown.
        let id: String
        let label: String
        let value: String

        init(id: String, label: String? = nil, value: String) {
            self.id = id
            self.label = label ?? id
            self.value = value
        }
    }

    /// One custom format: `Name=pattern` or `Name=UTC:pattern`.
    struct Custom: Equatable {
        let name: String
        let pattern: String
        let utc: Bool

        /// Parses the settings text, one `Name=pattern` per line.
        static func parse(_ text: String) -> [Custom] {
            text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let eq = line.firstIndex(of: "=") else { return nil }
                let name = line[..<eq].trimmingCharacters(in: .whitespaces)
                var pattern = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                var utc = false
                if pattern.uppercased().hasPrefix("UTC:") { utc = true; pattern.removeFirst(4) }
                guard !name.isEmpty, !pattern.isEmpty else { return nil }
                return Custom(name: name, pattern: pattern, utc: utc)
            }
        }
    }

    static let iso8601Calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.minimumDaysInFirstWeek = 4
        c.firstWeekday = 2
        return c
    }()

    /// ISO 8601 week and the number of weeks in that week-year: (43, 53).
    static func isoWeek(_ date: Date, in zone: TimeZone) -> (week: Int, of: Int, year: Int) {
        var cal = iso8601Calendar
        cal.timeZone = zone
        let week = cal.component(.weekOfYear, from: date)
        let year = cal.component(.yearForWeekOfYear, from: date)
        // A year has 53 ISO weeks when Dec 28 falls in week 53.
        var comps = DateComponents()
        comps.year = year
        comps.month = 12
        comps.day = 28
        let dec28 = cal.date(from: comps).map { cal.component(.weekOfYear, from: $0) } ?? 52
        return (week, dec28, year)
    }

    static func iso8601(_ date: Date, zone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = zone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func unix(_ date: Date) -> String { String(Int64(date.timeIntervalSince1970.rounded(.down))) }

    /// `UTC+8`, `UTC−5:30`, `UTC+0`.
    static func offsetLabel(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "−" : "+"
        let a = Swift.abs(seconds)
        let h = a / 3600, m = (a % 3600) / 60
        return m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
    }

    /// "8 hours behind", "5 hr, 30 min ahead", "same time".
    static func difference(_ other: TimeZone, from local: TimeZone, at date: Date, locale: Locale = .current) -> String {
        let delta = other.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)
        if delta == 0 { return String(localized: "same time", comment: "Time zone difference: the other zone shows the same time") }
        let a = Swift.abs(delta)
        // Whole hours read "8 hours"; with minutes the abbreviated form keeps it short: "5 hr, 30 min".
        let width: Duration.UnitsFormatStyle.UnitWidth = a % 3600 == 0 ? .wide : .abbreviated
        let amount = Duration.seconds(a).formatted(.units(allowed: [.hours, .minutes], width: width).locale(locale))
        return delta < 0
            ? String(localized: "\(amount) behind", comment: "Time zone difference; %@ is a duration such as “8 hours”")
            : String(localized: "\(amount) ahead", comment: "Time zone difference; %@ is a duration such as “8 hours”")
    }

    static func formatter(_ pattern: String? = nil, date: DateFormatter.Style = .none, time: DateFormatter.Style = .none,
                          zone: TimeZone, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        if let pattern { f.dateFormat = pattern } else { f.dateStyle = date; f.timeStyle = time }
        return f
    }

    /// The table shown in the detail pane and as copyable rows.
    static func rows(for date: Date, zone: TimeZone, locale: Locale, custom: [Custom] = []) -> [Row] {
        let utc = TimeZone(identifier: "UTC") ?? zone
        let week = isoWeek(date, in: zone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let dayOfYear = cal.ordinality(of: .day, in: .year, for: date) ?? 0
        let daysInYear = cal.range(of: .day, in: .year, for: date)?.count ?? 365
        // Standard names (ISO 8601, Unix, UTC, RFC 2822) are shown as they are.
        var rows = [
            Row(id: "ISO 8601", value: iso8601(date, zone: zone)),
            Row(id: "Unix", value: unix(date)),
            Row(id: "Week", label: String(localized: "Week", comment: "Time format row: the ISO calendar week"),
                value: String(localized: "\(week.week) of \(week.of)", comment: "A number out of a total: “43 of 53” (ISO week of the weeks in the year), “297 of 365” (day of the days in the year)")),
            Row(id: "UTC", value: formatter("HH:mm:ss", zone: utc, locale: Locale(identifier: "en_US_POSIX")).string(from: date)),
            Row(id: "Unix (ms)", value: String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
            Row(id: "Day of year", label: String(localized: "Day of year", comment: "Time format row: the day's number in the year"),
                value: String(localized: "\(dayOfYear) of \(daysInYear)", comment: "A number out of a total: “43 of 53” (ISO week of the weeks in the year), “297 of 365” (day of the days in the year)")),
            Row(id: "RFC 2822", value: formatter("EEE, dd MMM yyyy HH:mm:ss Z", zone: zone,
                                                 locale: Locale(identifier: "en_US_POSIX")).string(from: date)),
            Row(id: "Time zone", label: String(localized: "Time zone", comment: "Time format row: the time zone and its UTC offset"),
                value: "\(zone.identifier) · \(offsetLabel(zone.secondsFromGMT(for: date)))"),
        ]
        for c in custom {
            rows.append(Row(id: c.name,
                            value: format(date, pattern: c.pattern, zone: c.utc ? utc : zone, locale: locale)))
        }
        return rows
    }

    /// Unicode date pattern plus the PowerToys tokens UXT (Unix seconds), UMS (Unix ms), WOY (ISO week),
    /// DOW (ISO day of week) and DIM (days in month).
    static func format(_ date: Date, pattern: String, zone: TimeZone, locale: Locale) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let iso = isoWeek(date, in: zone)
        let weekday = (cal.component(.weekday, from: date) + 5) % 7 + 1
        let tokens: [(String, String)] = [
            ("UXT", unix(date)), ("UMS", String(Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))),
            ("WOY", String(iso.week)), ("DOW", String(weekday)),
            ("DIM", String(cal.range(of: .day, in: .month, for: date)?.count ?? 30)),
        ]
        // Tokens become private-use placeholders (literal to DateFormatter), then their values.
        var p = pattern
        for (i, t) in tokens.enumerated() { p = p.replacingOccurrences(of: t.0, with: String(placeholder(i))) }
        var out = formatter(p, zone: zone, locale: locale).string(from: date)
        for (i, t) in tokens.enumerated() { out = out.replacingOccurrences(of: String(placeholder(i)), with: t.1) }
        return out
    }

    private static func placeholder(_ i: Int) -> Character {
        Character(UnicodeScalar(0xE000 + i) ?? "_")
    }
}
