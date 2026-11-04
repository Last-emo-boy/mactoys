import Foundation
import MacToysCore
import Testing
@testable import MenuBarCalendar

@Suite struct MenuBarCalendarTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let newYork = TimeZone(identifier: "America/New_York")!

    static func gregorian(_ zone: TimeZone = utc, locale: String = "en_GB") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        c.locale = Locale(identifier: locale)
        return c
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0, zone: TimeZone = utc) -> Date {
        gregorian(zone).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: Menu bar format

    func formatter(_ locale: String, zone: TimeZone = utc, hourCycle: HourCycle = .system) -> MenuBarFormatter {
        MenuBarFormatter(locale: Locale(identifier: locale), timeZone: zone, hourCycle: hourCycle,
                         weekNumbering: .iso8601, calendar: Self.gregorian(zone, locale: locale))
    }

    @Test func defaultFormatInBritishEnglish() {
        let f = formatter("en_GB")
        let d = Self.date(2026, 11, 4, 9, 41, 7)
        #expect(f.string(MenuBarToken.defaultFormat, date: d) == "Wed 4 Nov 09:41")
    }

    @Test func eachTokenRenders() {
        let f = formatter("en_GB")
        let d = Self.date(2026, 11, 4, 21, 41, 7)
        #expect(f.string(.weekday(short: true), date: d) == "Wed")
        #expect(f.string(.weekday(short: false), date: d) == "Wednesday")
        #expect(f.string(.date(.dayMonth), date: d) == "4 Nov")
        #expect(f.string(.date(.dayMonthYear), date: d) == "4 Nov 2026")
        #expect(f.string(.date(.numeric), date: d) == "04/11/2026")
        #expect(f.string(.dayOfMonth, date: d) == "4")
        #expect(f.string(.month(short: true), date: d) == "Nov")
        #expect(f.string(.month(short: false), date: d) == "November")
        #expect(f.string(.year, date: d) == "2026")
        #expect(f.string(.weekNumber, date: d) == "W45")
        #expect(f.string(.time(seconds: false), date: d) == "21:41")
        #expect(f.string(.time(seconds: true), date: d) == "21:41:07")
        #expect(f.string(.text("Hello"), date: d) == "Hello")
    }

    @Test func americanOrderAndTwelveHourClock() {
        let f = formatter("en_US")
        let d = Self.date(2026, 11, 4, 21, 41)
        #expect(f.string(.date(.dayMonth), date: d) == "Nov 4")
        #expect(f.string(.date(.numeric), date: d) == "11/04/2026")
        // US English puts a narrow no-break space before PM.
        #expect(f.string(.time(seconds: false), date: d) == "9:41\u{202F}PM")
        #expect(formatter("en_US", hourCycle: .twentyFour).string(.time(seconds: false), date: d) == "21:41")
        #expect(formatter("en_GB", hourCycle: .twelve).string(.time(seconds: false), date: d).hasPrefix("9:41"))
    }

    @Test func punctuationAttachesToWhatCameBefore() {
        let f = formatter("en_GB")
        let d = Self.date(2026, 11, 4, 9, 41)
        #expect(f.string([.weekday(short: true), .text(","), .date(.dayMonth)], date: d) == "Wed, 4 Nov")
        #expect(f.string([.weekNumber, .text("·"), .time(seconds: false)], date: d) == "W45 · 09:41")
        #expect(f.string([.text("  "), .year], date: d) == "2026")
        #expect(f.string([], date: d) == "")
    }

    @Test func timeZoneTokenFollowsDaylightSaving() {
        let f = formatter("en_US", zone: Self.newYork)
        // US daylight saving time ends on Sunday 1 November 2026.
        #expect(f.string(.timeZone, date: Self.date(2026, 10, 30, 12, zone: Self.newYork)) == "EDT")
        #expect(f.string(.timeZone, date: Self.date(2026, 11, 4, 12, zone: Self.newYork)) == "EST")
    }

    @Test func refreshEverySecondOnlyWithSeconds() {
        #expect(MenuBarFormatter.refreshInterval(MenuBarToken.defaultFormat) == 60)
        #expect(MenuBarFormatter.refreshInterval([.date(.dayMonth), .time(seconds: true)]) == 1)
    }

    @Test func formatsSurviveSaving() throws {
        var s = CalendarSettings()
        s.tokens = [.weekday(short: false), .text(","), .date(.numeric), .time(seconds: true), .timeZone]
        s.shortcut = Shortcut(2, [.control, .option, .command])
        let back = try JSONDecoder().decode(CalendarSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(CalendarSettings().shortcut == nil)
    }

    // MARK: Week numbers

    @Test func isoWeekNumbersAcrossYearBoundaries() {
        let cal = Self.gregorian()
        func week(_ y: Int, _ m: Int, _ d: Int) -> Int { WeekMath.weekNumber(of: Self.date(y, m, d), numbering: .iso8601, calendar: cal) }
        #expect(week(2026, 1, 1) == 1)     // Thursday: week 1
        #expect(week(2025, 12, 29) == 1)   // Monday of that week, still 2025
        #expect(week(2026, 11, 4) == 45)
        #expect(week(2026, 12, 28) == 53)  // 2026 starts on a Thursday: 53 weeks
        #expect(week(2027, 1, 1) == 53)    // Friday 1 January belongs to 2026's last week
        #expect(week(2027, 1, 3) == 53)
        #expect(week(2027, 1, 4) == 1)
        #expect(week(2021, 1, 3) == 53)    // Sunday 3 January 2021 is in 2020's week 53
        #expect(week(2024, 12, 30) == 1)   // Monday 30 December 2024 starts 2025's week 1
    }

    @Test func regionalWeekNumbersInTheUS() {
        var us = Calendar(identifier: .gregorian)
        us.locale = Locale(identifier: "en_US")
        us.timeZone = Self.utc
        us.firstWeekday = 1
        us.minimumDaysInFirstWeek = 1
        #expect(WeekMath.weekNumber(of: Self.date(2026, 1, 1), numbering: .regional, calendar: us) == 1)
        #expect(WeekMath.weekNumber(of: Self.date(2025, 12, 28), numbering: .regional, calendar: us) == 1)
        #expect(WeekMath.weekNumber(of: Self.date(2026, 1, 4), numbering: .regional, calendar: us) == 2)
    }

    // MARK: Month grid

    @Test func monthGridForEachFirstWeekday() {
        let cal = Self.gregorian()
        let november = Self.date(2026, 11, 15)
        // 1 November 2026 is a Sunday.
        let expectations: [(Int, Int, Int)] = [(1, 11, 1), (2, 10, 26), (7, 10, 31), (3, 10, 27)]
        for (firstWeekday, startMonth, startDay) in expectations {
            let weeks = WeekMath.monthGrid(for: november, firstWeekday: firstWeekday, numbering: .iso8601, calendar: cal)
            #expect(weeks.count == 6)
            #expect(weeks.allSatisfy { $0.days.count == 7 })
            let first = weeks[0].days[0]
            let c = cal.dateComponents([.month, .day, .weekday], from: first.date)
            #expect(c.month == startMonth && c.day == startDay, "first weekday \(firstWeekday)")
            #expect(c.weekday == firstWeekday)
            let all = weeks.flatMap(\.days)
            for (a, b) in zip(all, all.dropFirst()) {
                #expect(cal.dateComponents([.day], from: a.date, to: b.date).day == 1)
            }
            #expect(all.filter(\.inMonth).count == 30)
            #expect(weeks[0].days.contains { $0.inMonth && $0.day == 1 })
        }
    }

    @Test func gridWeekNumbersFollowISOWeeks() {
        let cal = Self.gregorian()
        let monday = WeekMath.monthGrid(for: Self.date(2026, 11, 4), firstWeekday: 2, numbering: .iso8601, calendar: cal)
        #expect(monday.map(\.number) == [44, 45, 46, 47, 48, 49])
        // Sunday-first rows: most of the row (Monday to Saturday) is in the next ISO week.
        let sunday = WeekMath.monthGrid(for: Self.date(2026, 11, 4), firstWeekday: 1, numbering: .iso8601, calendar: cal)
        #expect(sunday.map(\.number) == [45, 46, 47, 48, 49, 50])
        // January 2027 begins in 2026's week 53.
        let january = WeekMath.monthGrid(for: Self.date(2027, 1, 10), firstWeekday: 2, numbering: .iso8601, calendar: cal)
        #expect(january.first?.number == 53)
        #expect(january[1].number == 1)
    }

    @Test func weekdayHeadersStartOnTheFirstWeekday() {
        let cal = Self.gregorian(locale: "en_US")
        #expect(WeekMath.weekdayHeaders(firstWeekday: 2, calendar: cal) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(WeekMath.weekdayHeaders(firstWeekday: 1, calendar: cal).first == "S")
        #expect(WeekMath.weekdayHeaders(firstWeekday: 7, calendar: cal) == ["S", "S", "M", "T", "W", "T", "F"])
    }

    // MARK: Video links

    @Test func recognizesCallServices() {
        let cases: [(String, VideoService?)] = [
            ("https://us02web.zoom.us/j/84213377610?pwd=Qx7abc", .zoom),
            ("https://zoom.us/my/jonas.berg", .zoom),
            ("https://zoom.us/pricing", nil),
            ("https://meet.google.com/rtx-kqpd-hzw", .meet),
            ("https://meet.google.com/", nil),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmQx%40thread.v2/0?context=%7b%7d", .teams),
            ("https://teams.live.com/meet/9387612345", .teams),
            ("https://teams.microsoft.com/l/channel/19%3a123", nil),
            ("https://acme.webex.com/meet/jonas.berg", .webex),
            ("https://acme.webex.com/acme/j.php?MTID=m123", .webex),
            ("https://facetime.apple.com/join#v=1&p=AbCdEf&k=XyZ", .facetime),
            ("https://www.apple.com/facetime/", nil),
            ("zoommtg://zoom.us/join?action=join&confno=123", .zoom),
            ("msteams:/l/meetup-join/19%3ameeting", .teams),
        ]
        for (string, service) in cases {
            let url = URL(string: string)!
            #expect(VideoLinks.classify(url)?.service == service, "\(string)")
        }
    }

    @Test func findsLinksInNotesAndHTML() {
        let notes = """
        Hi all, agenda below.
        ──────────
        Join Zoom Meeting
        https://acme.zoom.us/j/91877001234?pwd=bW9vbg.
        Meeting ID: 918 7700 1234
        """
        #expect(VideoLinks.find(url: nil, location: nil, notes: notes)?.url.absoluteString == "https://acme.zoom.us/j/91877001234?pwd=bW9vbg")
        let html = #"<p>Please join: <a href="https://meet.google.com/abc-defg-hij?authuser=0&amp;hs=1">Join with Google Meet</a></p>"#
        #expect(VideoLinks.find(url: nil, location: nil, notes: html)?.service == .meet)
        let parenthesized = "(Teams link: https://teams.live.com/meet/9387612345)"
        #expect(VideoLinks.find(url: nil, location: nil, notes: parenthesized)?.url.absoluteString == "https://teams.live.com/meet/9387612345")
        #expect(VideoLinks.find(url: nil, location: "Room 4B", notes: "Bring snacks. See https://example.com/menu") == nil)
    }

    @Test func unwrapsMailSecurityRedirects() {
        let wrapped = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_abc%2540thread.v2%2F0&data=05%7C01"
        let link = VideoLinks.find(url: nil, location: nil, notes: "Click here \(wrapped) to join")
        #expect(link?.service == .teams)
        #expect(link?.url.host() == "teams.microsoft.com")
        let google = URL(string: "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&sa=D")!
        #expect(VideoLinks.classify(google)?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func eventURLComesFirstThenLocationThenNotes() {
        let url = URL(string: "https://acme.webex.com/meet/jonas")!
        let link = VideoLinks.find(url: url, location: "https://meet.google.com/abc-defg-hij",
                                   notes: "https://acme.zoom.us/j/123")
        #expect(link?.service == .webex)
        #expect(VideoLinks.find(url: URL(string: "https://example.com")!, location: "https://meet.google.com/abc-defg-hij",
                                notes: "https://acme.zoom.us/j/123")?.service == .meet)
        #expect(VideoLinks.find(url: nil, location: "Corner Café", notes: "zoommtg://acme.zoom.us/join?confno=123")?.service == .zoom)
    }

    @Test func zoomLinksCanOpenTheApp() {
        let web = URL(string: "https://acme.zoom.us/j/84213377610?pwd=Qx7abc")!
        let native = VideoLinks.zoomAppURL(for: web)
        #expect(native?.absoluteString == "zoommtg://acme.zoom.us/join?action=join&confno=84213377610&pwd=Qx7abc")
        let link = VideoLink(service: .zoom, url: web)
        #expect(link.joinURL(zoomAppInstalled: false) == web)
        #expect(link.joinURL(zoomAppInstalled: true) == native)
        #expect(VideoLinks.zoomAppURL(for: URL(string: "https://zoom.us/my/room")!) == nil)
    }

    // MARK: World clocks

    @Test func offsetsAcrossDaylightSavingChanges() {
        let london = TimeZone(identifier: "Europe/London")!
        // 1 March: both on standard time.
        #expect(ClockReading(date: Self.date(2026, 3, 1, 12), zone: Self.newYork, reference: london).offset == -5 * 3600)
        // 15 March: New York already on daylight time, London not yet.
        #expect(ClockReading(date: Self.date(2026, 3, 15, 12), zone: Self.newYork, reference: london).offset == -4 * 3600)
        // 1 April: both on daylight time again.
        #expect(ClockReading(date: Self.date(2026, 4, 1, 12), zone: Self.newYork, reference: london).offset == -5 * 3600)
        // Southern hemisphere: Sydney is +11 in January and +10 in July from UTC.
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        #expect(ClockReading(date: Self.date(2026, 1, 15), zone: sydney, reference: Self.utc).offset == 11 * 3600)
        #expect(ClockReading(date: Self.date(2026, 7, 15), zone: sydney, reference: Self.utc).offset == 10 * 3600)
    }

    @Test func dayDifferenceAndDaylight() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let d = Self.date(2026, 11, 4, 20, 0) // 12:00 in Los Angeles, 05:00 next day in Tokyo
        let r = ClockReading(date: d, zone: tokyo, reference: la)
        #expect(r.offset == 17 * 3600)
        #expect(r.dayDifference == 1)
        #expect(r.hour == 5)
        #expect(r.daylight == .night)
        #expect(r.dayText == "Tomorrow")
        let back = ClockReading(date: d, zone: la, reference: tokyo)
        #expect(back.dayDifference == -1)
        #expect(back.daylight == .day)
        #expect(ClockReading(date: d, zone: la, reference: la).offsetText() == "Same time")
        #expect(ClockReading(date: Self.date(2026, 6, 1, 7), zone: Self.utc, reference: Self.utc).daylight == .sunrise)
        #expect(ClockReading(date: Self.date(2026, 6, 1, 19), zone: Self.utc, reference: Self.utc).daylight == .sunset)
    }

    @Test func offsetTextShowsHalfAndQuarterHours() {
        let en = Locale(identifier: "en_US")
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
        let r = ClockReading(date: Self.date(2026, 11, 4), zone: kathmandu, reference: Self.utc)
        #expect(r.offset == 5 * 3600 + 45 * 60)
        #expect(r.offsetText(locale: en) == "+5h 45m")
        #expect(ClockReading(date: Self.date(2026, 11, 4), zone: Self.newYork, reference: Self.utc).offsetText(locale: en) == "−5h")
    }

    @Test func citySearch() {
        let en = Locale(identifier: "en_US")
        #expect(WorldClockSearch.search("tok", locale: en).first?.timeZoneID == "Asia/Tokyo")
        #expect(WorldClockSearch.search("sao paulo", locale: en).first?.name == "São Paulo")
        #expect(WorldClockSearch.search("PST", locale: en).first?.timeZoneID == "America/Los_Angeles")
        #expect(WorldClockSearch.search("utc", locale: en).first?.timeZoneID == "UTC")
        #expect(WorldClockSearch.search("Ulaanbaatar", locale: en).first?.timeZoneID == "Asia/Ulaanbaatar")
        #expect(WorldClockSearch.search("   ", locale: en).isEmpty)
        #expect(WorldClockSearch.search("a", locale: en, limit: 5).count == 5)
        #expect(WorldClockSearch.cities.count > 120)
        #expect(Set(WorldClockSearch.cities.map(\.id)).count == WorldClockSearch.cities.count)
    }

    // MARK: Agenda and reminders

    func event(_ id: String, _ start: Date, minutes: Int, allDay: Bool = false, link: Bool = true) -> AgendaEvent {
        AgendaEvent(eventID: id, title: id, start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)), isAllDay: allDay,
                    color: .accent, calendarID: "work", calendarTitle: "Work",
                    videoLink: link ? VideoLink(service: .zoom, url: URL(string: "https://zoom.us/j/1")!) : nil)
    }

    @Test func remindersAreDueWithinTheLeadTime() {
        let ten = Self.date(2026, 11, 4, 10, 0)
        let standup = event("standup", ten, minutes: 15)
        let lunch = event("lunch", Self.date(2026, 11, 4, 12, 30), minutes: 60, link: false)
        let birthday = event("birthday", Self.date(2026, 11, 4, 0), minutes: 1440, allDay: true)
        let all = [standup, lunch, birthday]
        #expect(Agenda.dueReminders(all, now: ten.addingTimeInterval(-181), lead: 3, onlyVideoCalls: true, shown: []).isEmpty)
        #expect(Agenda.dueReminders(all, now: ten.addingTimeInterval(-180), lead: 3, onlyVideoCalls: true, shown: []) == [standup])
        #expect(Agenda.dueReminders(all, now: ten.addingTimeInterval(60), lead: 3, onlyVideoCalls: true, shown: []) == [standup])
        #expect(Agenda.dueReminders(all, now: ten.addingTimeInterval(121), lead: 3, onlyVideoCalls: true, shown: []).isEmpty)
        #expect(Agenda.dueReminders(all, now: ten.addingTimeInterval(-60), lead: 3, onlyVideoCalls: true, shown: [standup.id]).isEmpty)
        // Without the video filter the lunch counts too, at its own time; all-day events never do.
        let noon = Self.date(2026, 11, 4, 12, 29)
        #expect(Agenda.dueReminders(all, now: noon, lead: 2, onlyVideoCalls: false, shown: []) == [lunch])
        #expect(Agenda.dueReminders(all, now: noon, lead: 2, onlyVideoCalls: true, shown: []).isEmpty)
    }

    @Test func agendaOrdersAllDayFirstAndSpansDays() {
        let cal = Self.gregorian()
        let offsite = event("offsite", Self.date(2026, 11, 9, 0), minutes: 2 * 1440, allDay: true, link: false)
        let morning = event("morning", Self.date(2026, 11, 10, 9), minutes: 30)
        let early = event("early", Self.date(2026, 11, 10, 8), minutes: 30)
        let all = [morning, offsite, early]
        #expect(Agenda.events(all, on: Self.date(2026, 11, 10), calendar: cal).map(\.eventID) == ["offsite", "early", "morning"])
        #expect(Agenda.events(all, on: Self.date(2026, 11, 11), calendar: cal).isEmpty)
        let days = Agenda.byDay(all, calendar: cal)
        #expect(days[cal.startOfDay(for: Self.date(2026, 11, 9))]?.map(\.eventID) == ["offsite"])
        #expect(days[cal.startOfDay(for: Self.date(2026, 11, 10))]?.count == 3)
        #expect(days[cal.startOfDay(for: Self.date(2026, 11, 11))] == nil)
    }

    @Test func nextCallPrefersTheOneHappeningNow() {
        let now = Self.date(2026, 11, 4, 10, 5)
        let current = event("current", Self.date(2026, 11, 4, 10), minutes: 30)
        let soon = event("soon", Self.date(2026, 11, 4, 10, 30), minutes: 30)
        let noLink = event("nolink", Self.date(2026, 11, 4, 10, 10), minutes: 30, link: false)
        #expect(Agenda.nextCall([soon, current, noLink], now: now)?.eventID == "current")
        #expect(Agenda.nextCall([soon, noLink], now: now)?.eventID == "soon")
        #expect(Agenda.nextCall([event("old", Self.date(2026, 11, 4, 8), minutes: 30)], now: now) == nil)
    }

    @Test func eventTimesInTheAgenda() {
        let cal = Self.gregorian()
        let en = Locale(identifier: "en_GB")
        let e = event("e", Self.date(2026, 11, 4, 9, 30), minutes: 30)
        #expect(e.timeText(on: Self.date(2026, 11, 4), calendar: cal, locale: en) == "09:30 – 10:00")
        let overnight = event("night", Self.date(2026, 11, 4, 22), minutes: 240)
        #expect(overnight.timeText(on: Self.date(2026, 11, 4), calendar: cal, locale: en) == "From 22:00")
        #expect(overnight.timeText(on: Self.date(2026, 11, 5), calendar: cal, locale: en) == "Until 02:00")
        #expect(event("all", Self.date(2026, 11, 4, 0), minutes: 1440, allDay: true).timeText(on: Self.date(2026, 11, 4), calendar: cal) == "All day")
    }
}
