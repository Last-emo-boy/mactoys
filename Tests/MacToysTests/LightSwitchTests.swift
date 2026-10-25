import Foundation
import Testing
@testable import LightSwitch

@Suite struct LightSwitchTests {
    static func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    static func local(_ tz: String, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar(tz).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Asserts a computed time is within `tolerance` minutes of a published local time.
    static func near(_ date: Date?, _ expected: Date, tolerance: Double = 2) -> Bool {
        guard let date else { return false }
        return abs(date.timeIntervalSince(expected)) <= tolerance * 60
    }

    struct City: Sendable {
        let name: String, lat: Double, lon: Double, tz: String
        let y: Int, m: Int, d: Int
        let rise: (Int, Int), set: (Int, Int)
    }

    // Published sunrise/sunset (NOAA Solar Calculator / timeanddate.com), local time.
    static let cities: [City] = [
        City(name: "London", lat: 51.5074, lon: -0.1278, tz: "Europe/London", y: 2024, m: 6, d: 21, rise: (4, 43), set: (21, 21)),
        City(name: "New York", lat: 40.7128, lon: -74.0060, tz: "America/New_York", y: 2024, m: 12, d: 21, rise: (7, 17), set: (16, 32)),
        City(name: "Sydney", lat: -33.8688, lon: 151.2093, tz: "Australia/Sydney", y: 2024, m: 12, d: 21, rise: (5, 41), set: (20, 5)),
        City(name: "Tokyo", lat: 35.6762, lon: 139.6503, tz: "Asia/Tokyo", y: 2024, m: 3, d: 20, rise: (5, 45), set: (17, 53)),
        City(name: "San Francisco", lat: 37.7749, lon: -122.4194, tz: "America/Los_Angeles", y: 2024, m: 1, d: 1, rise: (7, 25), set: (17, 1)),
    ]

    @Test(arguments: cities.indices)
    func sunTimesMatchPublishedValues(_ index: Int) {
        let c = Self.cities[index]
        let t = SolarCalculator.sunTimes(year: c.y, month: c.m, day: c.d, latitude: c.lat, longitude: c.lon)
        #expect(Self.near(t.sunrise, Self.local(c.tz, c.y, c.m, c.d, c.rise.0, c.rise.1)), "\(c.name) sunrise \(String(describing: t.sunrise))")
        #expect(Self.near(t.sunset, Self.local(c.tz, c.y, c.m, c.d, c.set.0, c.set.1)), "\(c.name) sunset \(String(describing: t.sunset))")
        #expect(!t.isPolarDay && !t.isPolarNight)
    }

    @Test func polarDayAndNight() {
        let summer = SolarCalculator.sunTimes(year: 2024, month: 6, day: 21, latitude: 69.6492, longitude: 18.9553)
        #expect(summer.isPolarDay && summer.sunrise == nil && summer.sunset == nil)
        let winter = SolarCalculator.sunTimes(year: 2024, month: 12, day: 21, latitude: 69.6492, longitude: 18.9553)
        #expect(winter.isPolarNight && winter.sunrise == nil)
        let south = SolarCalculator.sunTimes(year: 2024, month: 6, day: 21, latitude: -77.85, longitude: 166.67)
        #expect(south.isPolarNight)
    }

    @Test func calendarDayFollowsTimeZone() {
        // 2024-03-20 in Tokyo: the sunrise falls on the previous UTC day, but on the right local day.
        let cal = Self.calendar("Asia/Tokyo")
        let noon = Self.local("Asia/Tokyo", 2024, 3, 20, 12, 0)
        let t = SolarCalculator.sunTimes(on: noon, latitude: 35.6762, longitude: 139.6503, calendar: cal)
        #expect(cal.isDate(t.sunrise!, inSameDayAs: noon))
        #expect(cal.isDate(t.sunset!, inSameDayAs: noon))
    }

    @Test func julianDay() {
        #expect(SolarCalculator.julianDay(year: 2000, month: 1, day: 1) == 2451544.5)
        #expect(SolarCalculator.julianDay(year: 1970, month: 1, day: 1) == 2440587.5)
    }

    @Test func fixedHoursPlan() {
        let cal = Self.calendar("Europe/Berlin")
        let source = ScheduleSource.fixed(light: TimeOfDay(7, 0), dark: TimeOfDay(20, 0))
        let evening = Self.local("Europe/Berlin", 2026, 10, 24, 21, 30)
        let plan = LightSwitchSchedule.plan(source, now: evening, calendar: cal)
        #expect(plan?.appearance == .dark)
        #expect(plan?.periodStart == Self.local("Europe/Berlin", 2026, 10, 24, 20, 0))
        #expect(plan?.nextChange == Self.local("Europe/Berlin", 2026, 10, 25, 7, 0))

        let morning = Self.local("Europe/Berlin", 2026, 10, 24, 6, 59)
        #expect(LightSwitchSchedule.plan(source, now: morning, calendar: cal)?.appearance == .dark)
        let atSeven = Self.local("Europe/Berlin", 2026, 10, 24, 7, 0)
        #expect(LightSwitchSchedule.plan(source, now: atSeven, calendar: cal)?.appearance == .light)
    }

    @Test func fixedHoursAcrossDSTChange() {
        // Berlin leaves summer time on 2026-10-25 at 03:00; 07:00 is still 07:00 local.
        let cal = Self.calendar("Europe/Berlin")
        let source = ScheduleSource.fixed(light: TimeOfDay(7, 0), dark: TimeOfDay(20, 0))
        let night = Self.local("Europe/Berlin", 2026, 10, 25, 1, 0)
        #expect(LightSwitchSchedule.plan(source, now: night, calendar: cal)?.nextChange
                == Self.local("Europe/Berlin", 2026, 10, 25, 7, 0))
    }

    @Test func invertedFixedHours() {
        let cal = Self.calendar("UTC")
        let source = ScheduleSource.fixed(light: TimeOfDay(22, 0), dark: TimeOfDay(6, 0))
        let noon = Self.local("UTC", 2026, 1, 10, 12, 0)
        #expect(LightSwitchSchedule.plan(source, now: noon, calendar: cal)?.appearance == .dark)
        let same = ScheduleSource.fixed(light: TimeOfDay(8, 0), dark: TimeOfDay(8, 0))
        #expect(LightSwitchSchedule.plan(same, now: noon, calendar: cal) == nil)
    }

    @Test func sunPlanWithOffsets() {
        let cal = Self.calendar("Europe/London")
        let source = ScheduleSource.sun(latitude: 51.5074, longitude: -0.1278, sunriseOffset: 30, sunsetOffset: -15)
        let lateEvening = Self.local("Europe/London", 2024, 6, 21, 21, 10)
        let plan = LightSwitchSchedule.plan(source, now: lateEvening, calendar: cal)
        // Sunset 21:21 − 15 min = 21:06, so it's already dark.
        #expect(plan?.appearance == .dark)
        #expect(Self.near(plan?.periodStart, Self.local("Europe/London", 2024, 6, 21, 21, 6)))
        // Next sunrise 04:43(ish) + 30 min.
        #expect(Self.near(plan?.nextChange, Self.local("Europe/London", 2024, 6, 22, 5, 13)))
    }

    @Test func polarDayPlanStaysLight() {
        let cal = Self.calendar("Europe/Oslo")
        let source = ScheduleSource.sun(latitude: 69.6492, longitude: 18.9553, sunriseOffset: 0, sunsetOffset: 0)
        let midnight = Self.local("Europe/Oslo", 2024, 6, 21, 0, 30)
        let plan = LightSwitchSchedule.plan(source, now: midnight, calendar: cal)
        #expect(plan?.appearance == .light)
        #expect(plan?.nextChange == nil)
        let winter = LightSwitchSchedule.plan(source, now: Self.local("Europe/Oslo", 2024, 12, 21, 12, 0), calendar: cal)
        #expect(winter?.appearance == .dark)
    }

    @Test func sourceFromSettings() {
        var s = LightSwitchSettings()
        s.scheduleMode = .off
        #expect(LightSwitchSchedule.source(for: s, nightShift: nil) == nil)
        s.scheduleMode = .sunsetToSunrise
        #expect(LightSwitchSchedule.source(for: s, nightShift: nil) == nil)   // no location yet
        s.latitude = 10
        s.longitude = 20
        s.sunsetOffset = 5
        #expect(LightSwitchSchedule.source(for: s, nightShift: nil) == .sun(latitude: 10, longitude: 20, sunriseOffset: 0, sunsetOffset: 5))
        s.scheduleMode = .followNightShift
        #expect(LightSwitchSchedule.source(for: s, nightShift: .custom(from: TimeOfDay(22, 0), to: TimeOfDay(7, 0)))
                == .fixed(light: TimeOfDay(7, 0), dark: TimeOfDay(22, 0)))
        #expect(LightSwitchSchedule.source(for: s, nightShift: .off) == nil)
        #expect(LightSwitchSchedule.source(for: s, nightShift: .sunsetToSunrise) == .sun(latitude: 10, longitude: 20, sunriseOffset: 0, sunsetOffset: 0))
    }

    @Test func decisionRespectsOverrideAndHandledPeriod() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = SchedulePlan(appearance: .dark, periodStart: now.addingTimeInterval(-600), nextChange: now.addingTimeInterval(3600))
        var s = LightSwitchSettings()
        #expect(LightSwitchSchedule.decide(plan: plan, settings: s, now: now, force: false) == .apply(.dark, periodStart: plan.periodStart))
        s.lastHandledPeriodStart = plan.periodStart
        #expect(LightSwitchSchedule.decide(plan: plan, settings: s, now: now, force: false) == .keep)
        #expect(LightSwitchSchedule.decide(plan: plan, settings: s, now: now, force: true) == .apply(.dark, periodStart: plan.periodStart))
        s.lastHandledPeriodStart = nil
        s.manualOverrideUntil = now.addingTimeInterval(3600)
        #expect(LightSwitchSchedule.decide(plan: plan, settings: s, now: now, force: false) == .keep)
        s.manualOverrideUntil = now.addingTimeInterval(-1)
        #expect(LightSwitchSchedule.decide(plan: plan, settings: s, now: now, force: false) == .apply(.dark, periodStart: plan.periodStart))
        #expect(LightSwitchSchedule.decide(plan: nil, settings: s, now: now, force: true) == .keep)
    }

    @Test func describesNextChange() {
        var cal = Self.calendar("UTC")
        cal.locale = Locale(identifier: "en_GB")  // 24-hour clock, whatever the machine's region
        let now = Self.local("UTC", 2026, 10, 24, 15, 0)
        let plan = SchedulePlan(appearance: .light, periodStart: now, nextChange: Self.local("UTC", 2026, 10, 24, 18, 2))
        let text = LightSwitchSchedule.describeNext(plan: plan, mode: .sunsetToSunrise, now: now, calendar: cal)
        #expect(text == "Dark at sunset · 18:02")
        cal.locale = Locale(identifier: "en_US")  // 12-hour clock; ICU puts a narrow no-break space before PM
        let us = LightSwitchSchedule.describeNext(plan: plan, mode: .sunsetToSunrise, now: now, calendar: cal)
        #expect(us.contains("6:02") && us.hasSuffix("PM"))
        #expect(LightSwitchSchedule.describeNext(plan: nil, mode: .off, now: now) == "Schedule off")
        #expect(LightSwitchSchedule.describeNext(plan: SchedulePlan(appearance: .light, periodStart: now, nextChange: nil),
                                                 mode: .sunsetToSunrise, now: now) == "Light all day")
    }

    @Test func timeOfDayWraps() {
        #expect(TimeOfDay(25, 0).minutes == 60)
        #expect(TimeOfDay(minutes: -30).minutes == 1410)
        let cal = Self.calendar("UTC")
        let d = TimeOfDay(7, 30).on(Self.local("UTC", 2026, 2, 3, 22, 0), calendar: cal)
        #expect(d == Self.local("UTC", 2026, 2, 3, 7, 30))
        #expect(TimeOfDay(of: d, calendar: cal) == TimeOfDay(7, 30))
    }

    @Test func scheduleModeCLINames() {
        for m in ScheduleMode.allCases { #expect(ScheduleMode(cliName: m.cliName) == m) }
        #expect(ScheduleMode(cliName: "Sunset-To-Sunrise") == .sunsetToSunrise)
        #expect(ScheduleMode(cliName: "nope") == nil)
    }
}
