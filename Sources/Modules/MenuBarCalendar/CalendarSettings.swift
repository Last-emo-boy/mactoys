import Foundation
import MacToysCore

/// What the menu bar item shows.
enum MenuBarStyle: String, Codable, CaseIterable, Sendable {
    case text, icon, iconAndText

    var title: String {
        switch self {
        case .text: String(localized: "Text", comment: "Menu Bar Calendar: show the date as text")
        case .icon: String(localized: "Icon with the day", comment: "Menu Bar Calendar: show a calendar icon with today's day number")
        case .iconAndText: String(localized: "Icon and text", comment: "Menu Bar Calendar: icon followed by the text")
        }
    }
}

/// 12- or 24-hour time.
enum HourCycle: String, Codable, CaseIterable, Sendable {
    case system, twelve, twentyFour

    var title: String {
        switch self {
        case .system: String(localized: "System setting", comment: "Clock: follow the system's 12/24-hour setting")
        case .twelve: String(localized: "12-hour", comment: "Clock style")
        case .twentyFour: String(localized: "24-hour", comment: "Clock style")
        }
    }

    /// `locale` with this hour cycle applied.
    func apply(to locale: Locale) -> Locale {
        guard self != .system else { return locale }
        var c = Locale.Components(locale: locale)
        c.hourCycle = self == .twelve ? .oneToTwelve : .zeroToTwentyThree
        return Locale(components: c)
    }
}

/// The first column of the month.
enum FirstWeekday: String, Codable, CaseIterable, Sendable {
    case system, sunday, monday, saturday

    var title: String {
        switch self {
        case .system: String(localized: "System setting", comment: "First day of the week: follow Language & Region")
        case .sunday: Calendar(identifier: .gregorian).weekdaySymbols[0]
        case .monday: Calendar(identifier: .gregorian).weekdaySymbols[1]
        case .saturday: Calendar(identifier: .gregorian).weekdaySymbols[6]
        }
    }

    /// `Calendar.firstWeekday` value (1 = Sunday).
    func value(for calendar: Calendar) -> Int {
        switch self {
        case .system: calendar.firstWeekday
        case .sunday: 1
        case .monday: 2
        case .saturday: 7
        }
    }
}

/// How weeks are numbered.
enum WeekNumbering: String, Codable, CaseIterable, Sendable {
    /// Weeks start on Monday; week 1 holds the first Thursday of the year.
    case iso8601
    /// The region's rule (for example the US: week 1 holds January 1).
    case regional

    var title: String {
        switch self {
        case .iso8601: String(localized: "ISO 8601", comment: "Week numbering standard name")
        case .regional: String(localized: "Regional", comment: "Week numbering: follow the region's rule")
        }
    }
}

/// When a meeting reminder appears.
enum ReminderStyle: String, Codable, CaseIterable, Sendable {
    /// A glass banner at the top right.
    case banner
    /// A large card in the middle of the screen over a dimmed desktop.
    case fullScreen

    var title: String {
        switch self {
        case .banner: String(localized: "Banner", comment: "Meeting reminder style")
        case .fullScreen: String(localized: "Full screen", comment: "Meeting reminder style: big card over the whole screen")
        }
    }
}

/// One clock in the world clocks list.
struct WorldClock: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// Time zone identifier, e.g. "Asia/Tokyo".
    var timeZoneID: String
    /// The name shown, e.g. "Tokyo".
    var name: String

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
}

struct CalendarSettings: Codable, Equatable {
    var style: MenuBarStyle = .text
    var tokens: [MenuBarToken] = MenuBarToken.defaultFormat
    var hourCycle: HourCycle = .system
    var firstWeekday: FirstWeekday = .system
    var showWeekNumbers = true
    var weekNumbering: WeekNumbering = .iso8601
    var showEventDots = true
    /// Calendars left out of the panel and reminders (`EKCalendar.calendarIdentifier`). New calendars are included.
    var excludedCalendars: [String] = []
    /// Minutes before a meeting to remind; nil turns reminders off.
    var reminderLead: Int? = 2
    var reminderStyle: ReminderStyle = .banner
    var remindOnlyVideoCalls = true
    var reminderSound = true
    var worldClocks: [WorldClock] = [
        WorldClock(timeZoneID: "America/Los_Angeles", name: "San Francisco"),
        WorldClock(timeZoneID: "Europe/London", name: "London"),
        WorldClock(timeZoneID: "Asia/Tokyo", name: "Tokyo"),
    ]
    var showWorldClocks = true
    @NullCodable var shortcut: Shortcut? = nil
}

extension CalendarSettings {
    /// Lead times offered for reminders, in minutes (0 = when it starts).
    static let leadOptions = [0, 1, 2, 5, 10, 15]

    static func leadTitle(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "When it starts", comment: "Meeting reminder lead time")
            : Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))
    }
}
