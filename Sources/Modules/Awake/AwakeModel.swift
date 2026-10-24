import Foundation

/// What Awake asks of the Mac.
enum AwakeMode: String, Codable, CaseIterable, Sendable {
    /// Follow the system's Energy settings; Awake holds nothing.
    case off
    /// Stay awake until Awake is turned off.
    case indefinite
    /// Stay awake for a time interval, then return to `off`.
    case timed
    /// Stay awake until a date and time, then return to `off`.
    case until

    var title: String {
        switch self {
        case .off: "Off (follow system)"
        case .indefinite: "Keep awake indefinitely"
        case .timed: "Keep awake for a time interval"
        case .until: "Keep awake until a date and time"
        }
    }
}

/// A named keep-awake duration offered in the menu (PowerToys `customTrayTimes`).
struct AwakePreset: Codable, Equatable, Hashable, Sendable, Identifiable {
    var name: String
    var seconds: Int
    var id: String { "\(name)|\(seconds)" }

    init(name: String, seconds: Int) {
        self.name = name
        self.seconds = seconds
    }
}

struct AwakeSettings: Codable, Equatable {
    var mode: AwakeMode = .off
    /// Also keep the displays on while awake.
    var keepScreenOn = true
    /// Release the display assertion while the screen is locked (the system one stays).
    var allowDisplaySleepWhenLocked = true
    /// The interval used by "Keep awake for a time interval" in Settings.
    var intervalHours = 1
    var intervalMinutes = 0
    /// Length and end of the running timed session.
    var timedSeconds = 3600
    var timedExpiresAt: Date?
    /// Target of `until` mode.
    var untilDate = AwakeSchedule.defaultUntil(now: Date())
    /// Mode restored by the on/off switch.
    var lastActiveMode: AwakeMode = .indefinite
    var showMenuBarIcon = true
    /// Extra durations for the menu, after the built-in ones.
    var customPresets: [AwakePreset] = []
    /// Set from the command line (`--pid`): Awake turns off when this process exits.
    var boundProcess: Int32?
}

/// Pure keep-awake timing rules, shared by the module, its menu and the CLI.
enum AwakeSchedule {
    static let builtInPresets = [
        AwakePreset(name: "30 minutes", seconds: 30 * 60),
        AwakePreset(name: "1 hour", seconds: 3600),
        AwakePreset(name: "2 hours", seconds: 2 * 3600),
    ]

    /// Tonight at 23:30 (or tomorrow when that has passed): a sensible first "until" target.
    static func defaultUntil(now: Date, calendar: Calendar = .current) -> Date {
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = 23
        c.minute = 30
        let tonight = calendar.date(from: c) ?? now.addingTimeInterval(3600)
        return tonight > now ? tonight : calendar.date(byAdding: .day, value: 1, to: tonight) ?? tonight
    }

    static func intervalSeconds(hours: Int, minutes: Int) -> Int {
        max(0, hours) * 3600 + max(0, minutes) * 60
    }

    /// When the current mode ends by itself, or nil for `off` and `indefinite`.
    static func expiry(of s: AwakeSettings) -> Date? {
        switch s.mode {
        case .off, .indefinite: nil
        case .timed: s.timedExpiresAt
        case .until: s.untilDate
        }
    }

    static func isExpired(_ s: AwakeSettings, now: Date) -> Bool {
        if s.mode == .timed && s.timedExpiresAt == nil { return true }
        guard let end = expiry(of: s) else { return false }
        return end <= now
    }

    /// Seconds left in a timed or until session.
    static func remaining(_ s: AwakeSettings, now: Date) -> TimeInterval? {
        expiry(of: s).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// The state to resume after a relaunch: sessions that ended meanwhile fall back to `off`.
    static func restored(_ s: AwakeSettings, now: Date) -> AwakeSettings {
        guard isExpired(s, now: now) else { return s }
        var copy = s
        copy.mode = .off
        copy.timedExpiresAt = nil
        return copy
    }

    /// Starts a timed session of `seconds` from `now`.
    static func startTimed(_ s: inout AwakeSettings, seconds: Int, now: Date) {
        s.mode = .timed
        s.timedSeconds = max(60, seconds)
        s.timedExpiresAt = now.addingTimeInterval(TimeInterval(s.timedSeconds))
        s.lastActiveMode = .timed
    }

    /// Starts `until` mode; a target in the past rolls forward to the same time of day next.
    static func startUntil(_ s: inout AwakeSettings, date: Date, now: Date, calendar: Calendar = .current) {
        s.mode = .until
        s.untilDate = date > now ? date : nextOccurrence(ofTimeOf: date, after: now, calendar: calendar)
        s.lastActiveMode = .until
    }

    /// The next moment after `now` with the same hour and minute as `date`.
    static func nextOccurrence(ofTimeOf date: Date, after now: Date, calendar: Calendar = .current) -> Date {
        let hm = calendar.dateComponents([.hour, .minute], from: date)
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = hm.hour
        c.minute = hm.minute
        c.second = 0
        let today = calendar.date(from: c) ?? now
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today) ?? today
    }

    /// The mode the on/off switch turns on: the last one used, with a fresh timer.
    static func toggledOn(_ s: AwakeSettings, now: Date) -> AwakeSettings {
        var copy = s
        switch s.lastActiveMode {
        case .timed:
            startTimed(&copy, seconds: s.timedSeconds, now: now)
        case .until where s.untilDate > now:
            copy.mode = .until
        default:
            copy.mode = .indefinite
            copy.lastActiveMode = .indefinite
        }
        return copy
    }

    // MARK: - Text

    /// "30 min", "1 h", "1 h 30 min", "2 d 3 h".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(max(total, 0)) s" }
        let minutes = (total + 59) / 60
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return h > 0 ? "\(d) d \(h) h" : "\(d) d" }
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return "\(m) min"
    }

    /// "23:30", or "Sat 23:30" when not today, or a full date beyond a week.
    static func formatUntil(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("HHmm")
        } else if date.timeIntervalSince(now) < 6 * 86400 {
            f.setLocalizedDateFormatFromTemplate("EEEHHmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        }
        return f.string(from: date)
    }

    /// The second line of the menu bar switch: "Indefinitely · screen stays on".
    static func describe(_ s: AwakeSettings, now: Date, locked: Bool = false) -> String {
        let screen: String
        if !s.keepScreenOn { screen = "screen may sleep" }
        else if locked && s.allowDisplaySleepWhenLocked { screen = "screen may sleep while locked" }
        else { screen = "screen stays on" }
        if let pid = s.boundProcess, s.mode != .off { return "While process \(pid) runs · \(screen)" }
        switch s.mode {
        case .off: return "Off · following system"
        case .indefinite: return "Indefinitely · \(screen)"
        case .timed: return "\(formatDuration(remaining(s, now: now) ?? 0)) left · \(screen)"
        case .until: return "Until \(formatUntil(s.untilDate, now: now)) · \(screen)"
        }
    }

    // MARK: - Parsing (CLI and URL parameters)

    /// Parses "90" (minutes), "45m", "2h", "1h30m", "1:30", "3600s", "1h 15m".
    static func parseDuration(_ text: String) -> Int? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if let minutes = Int(s) { return minutes > 0 ? minutes * 60 : nil }
        let colon = s.split(separator: ":", omittingEmptySubsequences: false)
        if colon.count == 2 || colon.count == 3 {
            let v = colon.compactMap { Int($0) }
            guard v.count == colon.count, v.allSatisfy({ $0 >= 0 }) else { return nil }
            let seconds = colon.count == 2 ? v[0] * 3600 + v[1] * 60 : v[0] * 3600 + v[1] * 60 + v[2]
            return seconds > 0 ? seconds : nil
        }
        var total = 0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Int(number) else { return nil }
            switch ch {
            case "d": total += n * 86400
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return total
    }

    /// Parses "17:00", "17:00:00", "2026-10-25 17:00", "2026-10-25T17:00:00+02:00", "4/13/2027 17:00:00".
    /// A bare time means its next occurrence.
    static func parseDate(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        if let iso = ISO8601DateFormatter().date(from: s) { return iso }
        let posix = Locale(identifier: "en_US_POSIX")
        for format in ["HH:mm", "HH:mm:ss", "H:mm", "H:mm:ss"] {
            let f = DateFormatter()
            f.locale = posix
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            if let t = f.date(from: s) { return nextOccurrence(ofTimeOf: t, after: now, calendar: calendar) }
        }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss",
                       "M/d/yyyy HH:mm", "M/d/yyyy HH:mm:ss", "M/d/yyyy H:mm", "M/d/yyyy H:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = posix
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// The Awake menu, as data: built once and rendered both as an `NSMenu` and in the preview scene.
enum AwakeMenuEntry: Equatable {
    case header(String)
    case item(title: String, checked: Bool, badge: String?, action: AwakeMenuAction)
    case separator
}

enum AwakeMenuAction: Equatable {
    case off, indefinite, timed(Int), until, toggleScreen, toggleLockedSleep, settings
}

enum AwakeMenu {
    static func entries(_ s: AwakeSettings, now: Date) -> [AwakeMenuEntry] {
        var out: [AwakeMenuEntry] = [.header("Awake")]
        out.append(.item(title: "Off (follow system)", checked: s.mode == .off, badge: nil, action: .off))
        out.append(.item(title: "Keep awake indefinitely", checked: s.mode == .indefinite, badge: nil, action: .indefinite))
        var presets = AwakeSchedule.builtInPresets + s.customPresets
        let custom = AwakeSchedule.intervalSeconds(hours: s.intervalHours, minutes: s.intervalMinutes)
        if custom >= 60 && !presets.contains(where: { $0.seconds == custom }) {
            presets.append(AwakePreset(name: AwakeSchedule.formatDuration(TimeInterval(custom)), seconds: custom))
        }
        if s.mode == .timed && !presets.contains(where: { $0.seconds == s.timedSeconds }) {
            presets.append(AwakePreset(name: AwakeSchedule.formatDuration(TimeInterval(s.timedSeconds)), seconds: s.timedSeconds))
        }
        for p in presets {
            let checked = s.mode == .timed && s.timedSeconds == p.seconds
            let badge = checked ? AwakeSchedule.remaining(s, now: now).map { AwakeSchedule.formatDuration($0) } : nil
            out.append(.item(title: "Keep awake for \(p.name)", checked: checked, badge: badge, action: .timed(p.seconds)))
        }
        let untilTarget = s.untilDate > now || s.mode == .until
            ? s.untilDate : AwakeSchedule.nextOccurrence(ofTimeOf: s.untilDate, after: now)
        out.append(.item(title: "Keep awake until…", checked: s.mode == .until,
                         badge: AwakeSchedule.formatUntil(untilTarget, now: now), action: .until))
        out.append(.separator)
        out.append(.item(title: "Keep screen on", checked: s.keepScreenOn, badge: nil, action: .toggleScreen))
        out.append(.item(title: "Allow display sleep when locked", checked: s.allowDisplaySleepWhenLocked,
                         badge: nil, action: .toggleLockedSleep))
        out.append(.separator)
        out.append(.item(title: "Awake settings…", checked: false, badge: nil, action: .settings))
        return out
    }
}
