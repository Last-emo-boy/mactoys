import Foundation
import MacToysCore

/// Light or dark system appearance.
enum Appearance: String, Codable, Sendable, CaseIterable {
    case light, dark

    var opposite: Appearance { self == .light ? .dark : .light }
    /// "Light mode" / "Dark mode".
    var modeTitle: String { self == .light ? String(localized: "Light mode") : String(localized: "Dark mode") }
}

/// How Light Switch decides when to switch.
enum ScheduleMode: String, Codable, CaseIterable, Sendable {
    /// Manual only: the shortcut, the menu bar switch and the CLI still toggle.
    case off
    case fixedHours
    case sunsetToSunrise
    /// Dark while macOS Night Shift's schedule is on.
    case followNightShift

    var title: String {
        switch self {
        case .off: String(localized: "Off (manual only)", comment: "Light Switch schedule mode")
        case .fixedHours: String(localized: "Fixed hours", comment: "Light Switch schedule mode")
        case .sunsetToSunrise: String(localized: "Sunset to sunrise", comment: "Light Switch schedule mode")
        case .followNightShift: String(localized: "Follow Night Shift", comment: "Light Switch schedule mode")
        }
    }

    /// The name used by the command line: `fixed-hours`, `sunset-to-sunrise`, `follow-night-shift`.
    var cliName: String {
        switch self {
        case .off: "off"
        case .fixedHours: "fixed-hours"
        case .sunsetToSunrise: "sunset-to-sunrise"
        case .followNightShift: "follow-night-shift"
        }
    }

    init?(cliName: String) {
        guard let m = ScheduleMode.allCases.first(where: { $0.cliName == cliName.lowercased() }) else { return nil }
        self = m
    }
}

/// A wall-clock time as minutes after midnight.
struct TimeOfDay: Codable, Hashable, Sendable {
    var minutes: Int

    init(_ hour: Int, _ minute: Int) { minutes = ((hour * 60 + minute) % 1440 + 1440) % 1440 }
    init(minutes: Int) { self.minutes = (minutes % 1440 + 1440) % 1440 }

    var hour: Int { minutes / 60 }
    var minute: Int { minutes % 60 }

    /// This time on the calendar day of `day`.
    func on(_ day: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day)
        var c = calendar.dateComponents([.year, .month, .day], from: start)
        c.hour = hour
        c.minute = minute
        return calendar.date(from: c) ?? start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    init(of date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(c.hour ?? 0, c.minute ?? 0)
    }
}

struct LightSwitchSettings: Codable, Equatable {
    var scheduleMode: ScheduleMode = .fixedHours
    var lightTime = TimeOfDay(7, 0)
    var darkTime = TimeOfDay(20, 0)
    /// Minutes added to sunrise and sunset (negative switches earlier).
    var sunriseOffset = 0
    var sunsetOffset = 0
    var latitude: Double?
    var longitude: Double?
    var toggleShortcut: Shortcut? = Shortcut(2, [.control, .option, .shift])   // ⌃⌥⇧D
    var showHUD = true
    var changeWallpaper = false
    var lightWallpaper: String?
    var darkWallpaper: String?
    /// Power Display profile ids applied with each appearance.
    var lightDisplayProfile: Int?
    var darkDisplayProfile: Int?

    // Runtime state kept across launches.
    /// A manual switch holds until the next scheduled change.
    var manualOverrideUntil: Date?
    /// Start of the scheduled period Light Switch last enforced, so a relaunch doesn't undo manual changes.
    var lastHandledPeriodStart: Date?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Fields whose change makes the schedule apply again right away.
    struct ScheduleKey: Equatable {
        var mode: ScheduleMode
        var light: TimeOfDay, dark: TimeOfDay
        var sunriseOffset: Int, sunsetOffset: Int
        var latitude: Double?, longitude: Double?
    }

    var scheduleKey: ScheduleKey {
        ScheduleKey(mode: scheduleMode, light: lightTime, dark: darkTime, sunriseOffset: sunriseOffset,
                    sunsetOffset: sunsetOffset, latitude: latitude, longitude: longitude)
    }
}

/// What the schedule asks for at a moment.
struct SchedulePlan: Equatable {
    var appearance: Appearance
    /// When the current period began (the last transition at or before now).
    var periodStart: Date
    /// The next transition, if any is known within two days.
    var nextChange: Date?
}

/// A schedule expressed as the times of day that start light and dark.
enum ScheduleSource: Equatable {
    case fixed(light: TimeOfDay, dark: TimeOfDay)
    case sun(latitude: Double, longitude: Double, sunriseOffset: Int, sunsetOffset: Int)
}

enum LightSwitchSchedule {
    /// The source the settings describe, or nil when there's nothing to follow.
    static func source(for s: LightSwitchSettings, nightShift: NightShiftSchedule?) -> ScheduleSource? {
        switch s.scheduleMode {
        case .off:
            return nil
        case .fixedHours:
            return .fixed(light: s.lightTime, dark: s.darkTime)
        case .sunsetToSunrise:
            guard let lat = s.latitude, let lon = s.longitude else { return nil }
            return .sun(latitude: lat, longitude: lon, sunriseOffset: s.sunriseOffset, sunsetOffset: s.sunsetOffset)
        case .followNightShift:
            switch nightShift {
            case .custom(let from, let to)?: return .fixed(light: to, dark: from)
            case .sunsetToSunrise?:
                guard let lat = s.latitude, let lon = s.longitude else { return nil }
                return .sun(latitude: lat, longitude: lon, sunriseOffset: 0, sunsetOffset: 0)
            case .off?, nil: return nil
            }
        }
    }

    /// Every switch from the day before yesterday to the day after tomorrow, oldest first,
    /// with repeats of the same appearance removed.
    static func transitions(_ source: ScheduleSource, around now: Date, calendar: Calendar) -> [(Date, Appearance)] {
        var list: [(Date, Appearance)] = []
        for offset in -2...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            switch source {
            case let .fixed(light, dark):
                guard light != dark else { continue }
                list.append((light.on(day, calendar: calendar), .light))
                list.append((dark.on(day, calendar: calendar), .dark))
            case let .sun(lat, lon, riseOffset, setOffset):
                let t = SolarCalculator.sunTimes(on: day, latitude: lat, longitude: lon, calendar: calendar)
                if let rise = t.sunrise, let set = t.sunset {
                    list.append((rise.addingTimeInterval(TimeInterval(riseOffset * 60)), .light))
                    list.append((set.addingTimeInterval(TimeInterval(setOffset * 60)), .dark))
                } else {
                    list.append((calendar.startOfDay(for: day), t.isPolarNight ? .dark : .light))
                }
            }
        }
        list.sort { $0.0 < $1.0 }
        var collapsed: [(Date, Appearance)] = []
        for item in list where collapsed.last?.1 != item.1 { collapsed.append(item) }
        return collapsed
    }

    /// The appearance the schedule wants at `now`, or nil for no schedule.
    static func plan(_ source: ScheduleSource?, now: Date, calendar: Calendar = .current) -> SchedulePlan? {
        guard let source else { return nil }
        let list = transitions(source, around: now, calendar: calendar)
        guard let current = list.last(where: { $0.0 <= now }) else { return nil }
        let next = list.first(where: { $0.0 > now })
        return SchedulePlan(appearance: current.1, periodStart: current.0, nextChange: next?.0)
    }

    /// Decides what to do now. `force` is set at module start-up after the schedule changed.
    enum Decision: Equatable {
        /// Switch to this appearance and remember the period as handled.
        case apply(Appearance, periodStart: Date)
        /// Leave the appearance alone (manual override, or the period was already handled).
        case keep
    }

    static func decide(plan: SchedulePlan?, settings s: LightSwitchSettings, now: Date, force: Bool) -> Decision {
        guard let plan else { return .keep }
        if !force, let until = s.manualOverrideUntil, now < until { return .keep }
        if !force, s.lastHandledPeriodStart == plan.periodStart { return .keep }
        return .apply(plan.appearance, periodStart: plan.periodStart)
    }

    /// "Dark at sunset · 18:02", "Light at 07:00", "Schedule off" (localized, times in the user's format).
    static func describeNext(plan: SchedulePlan?, mode: ScheduleMode, now: Date, calendar: Calendar = .current) -> String {
        guard mode != .off else { return String(localized: "Schedule off", comment: "Light Switch: no schedule is set") }
        guard let plan else {
            return mode == .followNightShift ? String(localized: "Night Shift has no schedule")
                : String(localized: "Set a location for sunrise and sunset")
        }
        guard let next = plan.nextChange else {
            return plan.appearance == .dark ? String(localized: "Dark all day", comment: "Light Switch: dark appearance all day")
                : String(localized: "Light all day", comment: "Light Switch: light appearance all day")
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(next, inSameDayAs: now) ? "jmm" : "EEEjmm")
        let when = f.string(from: next)
        switch (plan.appearance.opposite, mode == .sunsetToSunrise) {
        case (.dark, true):
            return String(localized: "Dark at sunset · \(when)", comment: "Light Switch: next switch to dark mode; the placeholder is a time")
        case (.light, true):
            return String(localized: "Light at sunrise · \(when)", comment: "Light Switch: next switch to light mode; the placeholder is a time")
        case (.dark, false):
            return String(localized: "Dark at \(when)", comment: "Light Switch: next switch to dark mode; the placeholder is a time")
        case (.light, false):
            return String(localized: "Light at \(when)", comment: "Light Switch: next switch to light mode; the placeholder is a time")
        }
    }
}
