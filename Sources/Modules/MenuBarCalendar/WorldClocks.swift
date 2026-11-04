import Foundation

/// A place to add as a world clock.
struct CityEntry: Hashable, Sendable, Identifiable {
    let name: String
    /// ISO 3166 region code, for the localized country name.
    let region: String
    let timeZoneID: String

    var id: String { "\(name)|\(timeZoneID)" }

    func countryName(locale: Locale = .current) -> String {
        locale.localizedString(forRegionCode: region) ?? region
    }
}

/// The built-in city table and time zone search (works offline, no location services).
enum WorldClockSearch {
    /// `City|Region|Time zone` — the cities people most often add, plus every zone's own city below.
    private static let table = """
    Honolulu|US|Pacific/Honolulu
    Anchorage|US|America/Anchorage
    San Francisco|US|America/Los_Angeles
    Los Angeles|US|America/Los_Angeles
    Seattle|US|America/Los_Angeles
    Vancouver|CA|America/Vancouver
    Las Vegas|US|America/Los_Angeles
    Phoenix|US|America/Phoenix
    Denver|US|America/Denver
    Salt Lake City|US|America/Denver
    Calgary|CA|America/Edmonton
    Dallas|US|America/Chicago
    Austin|US|America/Chicago
    Houston|US|America/Chicago
    Chicago|US|America/Chicago
    Minneapolis|US|America/Chicago
    Mexico City|MX|America/Mexico_City
    New York|US|America/New_York
    Boston|US|America/New_York
    Washington|US|America/New_York
    Atlanta|US|America/New_York
    Miami|US|America/New_York
    Toronto|CA|America/Toronto
    Montreal|CA|America/Toronto
    Havana|CU|America/Havana
    Bogotá|CO|America/Bogota
    Lima|PE|America/Lima
    Caracas|VE|America/Caracas
    Halifax|CA|America/Halifax
    Santiago|CL|America/Santiago
    São Paulo|BR|America/Sao_Paulo
    Rio de Janeiro|BR|America/Sao_Paulo
    Buenos Aires|AR|America/Argentina/Buenos_Aires
    Montevideo|UY|America/Montevideo
    St. John’s|CA|America/St_Johns
    Reykjavík|IS|Atlantic/Reykjavik
    Azores|PT|Atlantic/Azores
    London|GB|Europe/London
    Dublin|IE|Europe/Dublin
    Lisbon|PT|Europe/Lisbon
    Casablanca|MA|Africa/Casablanca
    Lagos|NG|Africa/Lagos
    Paris|FR|Europe/Paris
    Berlin|DE|Europe/Berlin
    Munich|DE|Europe/Berlin
    Frankfurt|DE|Europe/Berlin
    Hamburg|DE|Europe/Berlin
    Amsterdam|NL|Europe/Amsterdam
    Brussels|BE|Europe/Brussels
    Zurich|CH|Europe/Zurich
    Geneva|CH|Europe/Zurich
    Vienna|AT|Europe/Vienna
    Madrid|ES|Europe/Madrid
    Barcelona|ES|Europe/Madrid
    Rome|IT|Europe/Rome
    Milan|IT|Europe/Rome
    Copenhagen|DK|Europe/Copenhagen
    Oslo|NO|Europe/Oslo
    Stockholm|SE|Europe/Stockholm
    Prague|CZ|Europe/Prague
    Warsaw|PL|Europe/Warsaw
    Budapest|HU|Europe/Budapest
    Belgrade|RS|Europe/Belgrade
    Helsinki|FI|Europe/Helsinki
    Tallinn|EE|Europe/Tallinn
    Riga|LV|Europe/Riga
    Vilnius|LT|Europe/Vilnius
    Kyiv|UA|Europe/Kyiv
    Athens|GR|Europe/Athens
    Bucharest|RO|Europe/Bucharest
    Sofia|BG|Europe/Sofia
    Istanbul|TR|Europe/Istanbul
    Cairo|EG|Africa/Cairo
    Johannesburg|ZA|Africa/Johannesburg
    Cape Town|ZA|Africa/Johannesburg
    Nairobi|KE|Africa/Nairobi
    Tel Aviv|IL|Asia/Jerusalem
    Jerusalem|IL|Asia/Jerusalem
    Moscow|RU|Europe/Moscow
    Saint Petersburg|RU|Europe/Moscow
    Riyadh|SA|Asia/Riyadh
    Doha|QA|Asia/Qatar
    Tehran|IR|Asia/Tehran
    Dubai|AE|Asia/Dubai
    Abu Dhabi|AE|Asia/Dubai
    Baku|AZ|Asia/Baku
    Kabul|AF|Asia/Kabul
    Karachi|PK|Asia/Karachi
    Tashkent|UZ|Asia/Tashkent
    Mumbai|IN|Asia/Kolkata
    New Delhi|IN|Asia/Kolkata
    Bangalore|IN|Asia/Kolkata
    Chennai|IN|Asia/Kolkata
    Kolkata|IN|Asia/Kolkata
    Colombo|LK|Asia/Colombo
    Kathmandu|NP|Asia/Kathmandu
    Almaty|KZ|Asia/Almaty
    Dhaka|BD|Asia/Dhaka
    Yangon|MM|Asia/Yangon
    Bangkok|TH|Asia/Bangkok
    Ho Chi Minh City|VN|Asia/Ho_Chi_Minh
    Hanoi|VN|Asia/Ho_Chi_Minh
    Jakarta|ID|Asia/Jakarta
    Singapore|SG|Asia/Singapore
    Kuala Lumpur|MY|Asia/Kuala_Lumpur
    Manila|PH|Asia/Manila
    Hong Kong|HK|Asia/Hong_Kong
    Shanghai|CN|Asia/Shanghai
    Beijing|CN|Asia/Shanghai
    Shenzhen|CN|Asia/Shanghai
    Taipei|TW|Asia/Taipei
    Perth|AU|Australia/Perth
    Seoul|KR|Asia/Seoul
    Tokyo|JP|Asia/Tokyo
    Osaka|JP|Asia/Tokyo
    Darwin|AU|Australia/Darwin
    Adelaide|AU|Australia/Adelaide
    Brisbane|AU|Australia/Brisbane
    Sydney|AU|Australia/Sydney
    Melbourne|AU|Australia/Melbourne
    Hobart|AU|Australia/Hobart
    Nouméa|NC|Pacific/Noumea
    Auckland|NZ|Pacific/Auckland
    Wellington|NZ|Pacific/Auckland
    Fiji|FJ|Pacific/Fiji
    Chatham Islands|NZ|Pacific/Chatham
    Apia|WS|Pacific/Apia
    Kiritimati|KI|Pacific/Kiritimati
    """

    static let cities: [CityEntry] = table.split(separator: "\n").compactMap { line in
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "|").map(String.init)
        guard parts.count == 3, TimeZone(identifier: parts[2]) != nil else { return nil }
        return CityEntry(name: parts[0], region: parts[1], timeZoneID: parts[2])
    }

    /// Cities matching `query` by name, country, time zone name or abbreviation ("PST", "CET", "UTC").
    static func search(_ query: String, locale: Locale = .current, limit: Int = 12) -> [CityEntry] {
        let q = fold(query.trimmingCharacters(in: .whitespaces), locale: locale)
        guard !q.isEmpty else { return [] }
        var results: [(Int, CityEntry)] = []
        var seen = Set<String>()
        func add(_ e: CityEntry, _ rank: Int) {
            guard seen.insert(e.id).inserted else { return }
            results.append((rank, e))
        }
        // An abbreviation picks its zone's city first.
        let upper = query.trimmingCharacters(in: .whitespaces).uppercased()
        if let zoneID = TimeZone.abbreviationDictionary[upper] {
            let entry = cities.first { $0.timeZoneID == zoneID } ?? zoneEntry(zoneID)
            if let entry { add(entry, 0) }
        }
        if upper == "UTC" || upper == "GMT" || upper == "Z" { add(CityEntry(name: "UTC", region: "", timeZoneID: "UTC"), 0) }
        for c in cities {
            let name = fold(c.name, locale: locale)
            if name.hasPrefix(q) { add(c, 1) }
            else if name.contains(q) { add(c, 3) }
            else if fold(c.countryName(locale: locale), locale: locale).hasPrefix(q) || fold(c.region, locale: locale) == q { add(c, 4) }
        }
        // Any other zone by its own city name: "Asia/Ulaanbaatar" → "Ulaanbaatar".
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let e = zoneEntry(id) else { continue }
            let name = fold(e.name, locale: locale)
            if name.hasPrefix(q) { add(e, 2) } else if fold(id, locale: locale).contains(q) { add(e, 5) }
        }
        return results.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name < $1.1.name }.prefix(limit).map(\.1)
    }

    /// An entry named after a zone's city, for zones not in the table.
    static func zoneEntry(_ id: String) -> CityEntry? {
        guard TimeZone(identifier: id) != nil, let last = id.split(separator: "/").last, id.contains("/") else { return nil }
        return CityEntry(name: last.replacingOccurrences(of: "_", with: " "), region: "", timeZoneID: id)
    }

    private static func fold(_ s: String, locale: Locale) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .replacingOccurrences(of: "_", with: " ")
    }
}

/// Times in other zones relative to here.
struct ClockReading: Equatable, Sendable {
    /// Seconds the other zone is ahead of the reference zone (negative: behind), at this moment.
    let offset: Int
    /// -1 yesterday, 0 today, 1 tomorrow there, compared with the reference zone's date.
    let dayDifference: Int
    /// The hour of day there, 0…23.
    let hour: Int

    init(date: Date, zone: TimeZone, reference: TimeZone) {
        offset = zone.secondsFromGMT(for: date) - reference.secondsFromGMT(for: date)
        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        var here = Calendar(identifier: .gregorian)
        here.timeZone = reference
        let a = there.dateComponents([.year, .month, .day, .hour], from: date)
        let b = here.dateComponents([.year, .month, .day], from: date)
        hour = a.hour ?? 0
        let dayA = DateComponents(calendar: Calendar(identifier: .gregorian), year: a.year, month: a.month, day: a.day)
        let dayB = DateComponents(calendar: Calendar(identifier: .gregorian), year: b.year, month: b.month, day: b.day)
        if let da = dayA.date, let db = dayB.date {
            dayDifference = Calendar(identifier: .gregorian).dateComponents([.day], from: db, to: da).day ?? 0
        } else {
            dayDifference = 0
        }
    }

    enum Daylight { case night, sunrise, day, sunset }

    var daylight: Daylight {
        switch hour {
        case 6..<8: .sunrise
        case 8..<18: .day
        case 18..<20: .sunset
        default: .night
        }
    }

    var symbol: String {
        switch daylight {
        case .night: "moon.stars.fill"
        case .sunrise: "sunrise.fill"
        case .day: "sun.max.fill"
        case .sunset: "sunset.fill"
        }
    }

    /// "+9 h", "−5 h 30 min", or "Same time".
    func offsetText(locale: Locale = .current) -> String {
        guard offset != 0 else { return String(localized: "Same time", comment: "World clock: no time difference") }
        let sign = offset > 0 ? "+" : "−"
        let amount = Duration.seconds(abs(offset)).formatted(.units(allowed: [.hours, .minutes], width: .narrow).locale(locale))
        return sign + amount
    }

    /// "Tomorrow", "Yesterday" or nil for the same day.
    var dayText: String? {
        switch dayDifference {
        case 1: String(localized: "Tomorrow", comment: "World clock: the date there is tomorrow")
        case -1: String(localized: "Yesterday", comment: "World clock: the date there is yesterday")
        default: nil
        }
    }
}
