import Foundation
import Testing
@testable import Awake

@Suite struct AwakeTests {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    let now = AwakeTests.date(2026, 10, 24, 22, 41)

    @Test func timedSessionExpiresAfterItsInterval() {
        var s = AwakeSettings()
        AwakeSchedule.startTimed(&s, seconds: 1800, now: now)
        #expect(s.mode == .timed)
        #expect(s.timedExpiresAt == now.addingTimeInterval(1800))
        #expect(!AwakeSchedule.isExpired(s, now: now.addingTimeInterval(1799)))
        #expect(AwakeSchedule.isExpired(s, now: now.addingTimeInterval(1800)))
        #expect(AwakeSchedule.remaining(s, now: now.addingTimeInterval(600)) == 1200)
        #expect(AwakeSchedule.remaining(s, now: now.addingTimeInterval(4000)) == 0)
    }

    @Test func timedWithoutExpiryCountsAsExpired() {
        var s = AwakeSettings()
        s.mode = .timed
        s.timedExpiresAt = nil
        #expect(AwakeSchedule.isExpired(s, now: now))
    }

    @Test func indefiniteAndOffNeverExpire() {
        var s = AwakeSettings()
        s.mode = .indefinite
        #expect(AwakeSchedule.expiry(of: s) == nil)
        #expect(!AwakeSchedule.isExpired(s, now: .distantFuture))
        s.mode = .off
        #expect(!AwakeSchedule.isExpired(s, now: .distantFuture))
    }

    @Test func relaunchDropsSessionsThatEnded() {
        var s = AwakeSettings()
        AwakeSchedule.startUntil(&s, date: now.addingTimeInterval(3600), now: now)
        #expect(AwakeSchedule.restored(s, now: now.addingTimeInterval(1800)).mode == .until)
        let later = AwakeSchedule.restored(s, now: now.addingTimeInterval(3601))
        #expect(later.mode == .off)
        #expect(later.untilDate == s.untilDate)

        var t = AwakeSettings()
        AwakeSchedule.startTimed(&t, seconds: 600, now: now)
        #expect(AwakeSchedule.restored(t, now: now.addingTimeInterval(300)) == t)
        let gone = AwakeSchedule.restored(t, now: now.addingTimeInterval(601))
        #expect(gone.mode == .off && gone.timedExpiresAt == nil)
    }

    @Test func untilInThePastRollsToNextOccurrence() {
        var s = AwakeSettings()
        let earlier = AwakeTests.date(2026, 10, 20, 7, 15)
        AwakeSchedule.startUntil(&s, date: earlier, now: now, calendar: AwakeTests.utc)
        #expect(s.untilDate == AwakeTests.date(2026, 10, 25, 7, 15))
        let tonight = AwakeTests.date(2026, 10, 1, 23, 30)
        #expect(AwakeSchedule.nextOccurrence(ofTimeOf: tonight, after: now, calendar: AwakeTests.utc)
                == AwakeTests.date(2026, 10, 24, 23, 30))
    }

    @Test func defaultUntilIsTonightOrTomorrow() {
        #expect(AwakeSchedule.defaultUntil(now: now, calendar: AwakeTests.utc) == AwakeTests.date(2026, 10, 24, 23, 30))
        let late = AwakeTests.date(2026, 10, 24, 23, 45)
        #expect(AwakeSchedule.defaultUntil(now: late, calendar: AwakeTests.utc) == AwakeTests.date(2026, 10, 25, 23, 30))
    }

    @Test func toggleRestoresLastModeWithFreshTimer() {
        var s = AwakeSettings()
        AwakeSchedule.startTimed(&s, seconds: 3600, now: now)
        s.mode = .off
        let on = AwakeSchedule.toggledOn(s, now: now.addingTimeInterval(7200))
        #expect(on.mode == .timed)
        #expect(on.timedExpiresAt == now.addingTimeInterval(7200 + 3600))

        var u = AwakeSettings()
        AwakeSchedule.startUntil(&u, date: now.addingTimeInterval(60), now: now)
        u.mode = .off
        #expect(AwakeSchedule.toggledOn(u, now: now).mode == .until)
        #expect(AwakeSchedule.toggledOn(u, now: now.addingTimeInterval(120)).mode == .indefinite)
    }

    @Test func parsesDurations() {
        #expect(AwakeSchedule.parseDuration("90") == 5400)
        #expect(AwakeSchedule.parseDuration("45m") == 2700)
        #expect(AwakeSchedule.parseDuration("2h") == 7200)
        #expect(AwakeSchedule.parseDuration("1h30m") == 5400)
        #expect(AwakeSchedule.parseDuration("1h 15m") == 4500)
        #expect(AwakeSchedule.parseDuration("1:30") == 5400)
        #expect(AwakeSchedule.parseDuration("0:00:45") == 45)
        #expect(AwakeSchedule.parseDuration("3600s") == 3600)
        #expect(AwakeSchedule.parseDuration("1d") == 86400)
        #expect(AwakeSchedule.parseDuration("") == nil)
        #expect(AwakeSchedule.parseDuration("0") == nil)
        #expect(AwakeSchedule.parseDuration("abc") == nil)
        #expect(AwakeSchedule.parseDuration("5x") == nil)
        #expect(AwakeSchedule.parseDuration("1:-5") == nil)
        #expect(AwakeSchedule.parseDuration("12") == 720)
    }

    @Test func parsesDates() {
        let cal = AwakeTests.utc
        #expect(AwakeSchedule.parseDate("23:30", now: now, calendar: cal) == AwakeTests.date(2026, 10, 24, 23, 30))
        #expect(AwakeSchedule.parseDate("17:00:00", now: now, calendar: cal) == AwakeTests.date(2026, 10, 25, 17, 0))
        #expect(AwakeSchedule.parseDate("2026-10-25 17:00", now: now, calendar: cal) == AwakeTests.date(2026, 10, 25, 17, 0))
        #expect(AwakeSchedule.parseDate("4/13/2027 17:00:00", now: now, calendar: cal) == AwakeTests.date(2027, 4, 13, 17, 0))
        #expect(AwakeSchedule.parseDate("2026-10-25T17:00:00Z", now: now, calendar: cal) == AwakeTests.date(2026, 10, 25, 17, 0))
        #expect(AwakeSchedule.parseDate("tomorrow-ish", now: now, calendar: cal) == nil)
    }

    @Test func formatsDurations() {
        #expect(AwakeSchedule.formatDuration(30) == "30 s")
        #expect(AwakeSchedule.formatDuration(1800) == "30 min")
        #expect(AwakeSchedule.formatDuration(1799) == "30 min")
        #expect(AwakeSchedule.formatDuration(3600) == "1 h")
        #expect(AwakeSchedule.formatDuration(5400) == "1 h 30 min")
        #expect(AwakeSchedule.formatDuration(86400 + 3 * 3600) == "1 d 3 h")
        let en = Locale(identifier: "en_US")
        #expect(AwakeSchedule.displayDuration(30, locale: en) == "30 sec")
        #expect(AwakeSchedule.displayDuration(1799, locale: en) == "30 min")
        #expect(AwakeSchedule.displayDuration(5400, locale: en) == "1 hr, 30 min")
        #expect(AwakeSchedule.displayDuration(86400 + 3 * 3600 + 120, locale: en) == "1 day, 3 hr")
    }

    @Test func describesState() {
        var s = AwakeSettings()
        #expect(AwakeSchedule.describe(s, now: now) == "Off · following system")
        s.mode = .indefinite
        s.keepScreenOn = true
        #expect(AwakeSchedule.describe(s, now: now) == "Indefinitely · screen stays on")
        #expect(AwakeSchedule.statusText(s, now: now) == "Indefinitely · screen stays on")
        s.allowDisplaySleepWhenLocked = true
        #expect(AwakeSchedule.describe(s, now: now, locked: true) == "Indefinitely · screen may sleep while locked")
        s.keepScreenOn = false
        AwakeSchedule.startTimed(&s, seconds: 4320, now: now)
        #expect(AwakeSchedule.describe(s, now: now) == "1 h 12 min left · screen may sleep")
    }

    @Test func menuChecksActivePreset() {
        var s = AwakeSettings()
        AwakeSchedule.startTimed(&s, seconds: 3600, now: now)
        let entries = AwakeMenu.entries(s, now: now.addingTimeInterval(600), locale: Locale(identifier: "en_US"))
        let checked = entries.compactMap { entry -> String? in
            if case let .item(title, true, _, _) = entry { return title }
            return nil
        }
        #expect(checked.contains("Keep awake for 1 hour"))
        #expect(!checked.contains("Keep awake indefinitely"))
        let hourBadge = entries.compactMap { entry -> String? in
            if case let .item("Keep awake for 1 hour", _, badge, _) = entry { return badge }
            return nil
        }
        #expect(hourBadge == ["50 min"])
    }

    @Test func menuOffersCustomIntervalOnce() {
        var s = AwakeSettings()
        s.intervalHours = 1
        s.intervalMinutes = 30
        s.customPresets = [AwakePreset(name: "8 hours", seconds: 28800)]
        let titles = AwakeMenu.entries(s, now: now, locale: Locale(identifier: "en_US")).compactMap { entry -> String? in
            if case let .item(title, _, _, .timed) = entry { return title }
            return nil
        }
        #expect(titles == ["Keep awake for 30 minutes", "Keep awake for 1 hour", "Keep awake for 2 hours",
                           "Keep awake for 8 hours", "Keep awake for 1 hr, 30 min"])
        s.intervalMinutes = 0
        #expect(AwakeMenu.entries(s, now: now).filter {
            if case .item(_, _, _, .timed) = $0 { return true } else { return false }
        }.count == 4)
    }

    @Test func cliParsesArguments() throws {
        let r = try AwakeCLI.parse(["for", "1h30m", "--screen", "off", "--json"], now: now)
        guard case .timed(let seconds)? = r.mode else { Issue.record("expected timed"); return }
        #expect(seconds == 5400)
        #expect(r.screen == false)
        #expect(r.json)
        let t = try AwakeCLI.parse(["--time-limit=36000", "--display-on=true"], now: now)
        guard case .timed(let limit)? = t.mode else { Issue.record("expected timed"); return }
        #expect(limit == 36000)
        #expect(t.screen == true)
        #expect(throws: AwakeCLI.Failure.self) { try AwakeCLI.parse(["for"], now: now) }
        #expect(throws: AwakeCLI.Failure.self) { try AwakeCLI.parse(["bogus"], now: now) }
        #expect(throws: AwakeCLI.Failure.self) { try AwakeCLI.parse(["until", "2020-01-01 10:00"], now: now) }
    }

    @Test func bindsToAProcess() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let r = try AwakeCLI.parse(["--pid", "\(me)"], now: now)
        #expect(r.pid == me && r.mode == nil)
        #expect(try AwakeCLI.parse(["--use-parent-pid"], now: now).pid == getppid())
        #expect(throws: AwakeCLI.Failure.self) { try AwakeCLI.parse(["--pid", "999999"], now: now) }
        #expect(throws: AwakeCLI.Failure.self) { try AwakeCLI.parse(["--pid", "x"], now: now) }
        var s = AwakeSettings()
        s.mode = .indefinite
        s.boundProcess = me
        #expect(AwakeSchedule.describe(s, now: now) == "While process \(me) runs · screen stays on")
    }

    @Test func settingsRoundTripThroughJSON() throws {
        var s = AwakeSettings()
        AwakeSchedule.startTimed(&s, seconds: 900, now: now)
        s.customPresets = [AwakePreset(name: "12 hours", seconds: 43200)]
        let back = try JSONDecoder().decode(AwakeSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
