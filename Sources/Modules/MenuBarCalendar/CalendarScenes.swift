import AppKit
import MacToysCore
import SwiftUI

/// Offscreen scenes with a realistic week of events, for snapshots and the README.
@MainActor
enum CalendarScenes {
    /// Wednesday 4 November 2026, 9:41 in this Mac's time zone.
    static var sampleNow: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 41)) ?? Date()
    }

    static var all: [PreviewScene] {
        [
            PreviewScene("panel", size: CGSize(width: 460, height: 900), wallpaper: false) {
                AnyView(desktop { dropped(sampleModule()) })
            },
            PreviewScene("no-access", size: CGSize(width: 460, height: 760), wallpaper: false) {
                let m = sampleModule()
                m.model.access = .notDetermined
                m.model.gridEvents = []
                m.model.eventsByDay = [:]
                m.model.upcoming = []
                return AnyView(desktop { dropped(m) })
            },
            PreviewScene("menubar", size: CGSize(width: 620, height: 400), wallpaper: false) {
                AnyView(desktop { menuBarStrings() })
            },
            PreviewScene("reminder", size: CGSize(width: 520, height: 230), wallpaper: false) {
                let e = sampleEvents()[2]
                return AnyView(desktop {
                    VStack(alignment: .trailing, spacing: 8) {
                        strip(MenuBarItemMock(style: .text, text: formatter().string(MenuBarToken.defaultFormat, date: sampleNow.addingTimeInterval(17 * 60)),
                                              day: 4))
                        MeetingBanner(event: e, now: e.start.addingTimeInterval(-120), join: {}, dismiss: {})
                            .frame(width: ReminderPresenter.bannerSize.width, height: ReminderPresenter.bannerSize.height)
                            .padding(.trailing, 4)
                    }
                })
            },
            PreviewScene("reminder-fullscreen", size: CGSize(width: 1000, height: 620), wallpaper: false) {
                let e = sampleEvents()[2]
                return AnyView(desktop {
                    MeetingFullScreen(event: e, now: e.start.addingTimeInterval(-60), join: {}, dismiss: {})
                })
            },
        ]
    }

    private static func formatter() -> MenuBarFormatter { MenuBarFormatter() }

    /// A module with throwaway settings and a model filled with sample events.
    static func sampleModule() -> MenuBarCalendarModule {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let m = MenuBarCalendarModule(store: SettingsStore(directory: dir))
        m.settings.value.worldClocks = [
            WorldClock(timeZoneID: "America/Los_Angeles", name: "San Francisco"),
            WorldClock(timeZoneID: "America/New_York", name: "New York"),
            WorldClock(timeZoneID: "Asia/Tokyo", name: "Tokyo"),
        ]
        let model = m.model
        model.now = sampleNow
        model.month = sampleNow
        model.selectedDay = Calendar.current.startOfDay(for: sampleNow)
        model.access = .granted
        let events = sampleEvents()
        model.gridEvents = events
        model.eventsByDay = Agenda.byDay(events, calendar: model.calendar)
        model.upcoming = events.filter { !$0.isAllDay }
        model.hasLoaded = true
        return m
    }

    static let work = (id: "work", title: "Work", color: RGBA(hex: "#0A84FF")!)
    static let personal = (id: "personal", title: "Personal", color: RGBA(hex: "#34C759")!)
    static let family = (id: "family", title: "Family", color: RGBA(hex: "#FF9F0A")!)
    static let holidays = (id: "holidays", title: "Holidays", color: RGBA(hex: "#FF3B30")!)

    static func sampleEvents() -> [AgendaEvent] {
        let cal = Calendar.current
        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m)) ?? sampleNow
        }
        func event(_ id: String, _ title: String, _ start: Date, minutes: Int, _ c: (id: String, title: String, color: RGBA),
                   location: String? = nil, link: String? = nil, allDay: Bool = false, people: Int = 0) -> AgendaEvent {
            let video = link.flatMap { URL(string: $0) }.flatMap(VideoLinks.classify)
            let s = allDay ? cal.startOfDay(for: start) : start
            let e = allDay ? cal.date(byAdding: .day, value: max(1, minutes / 1440), to: s) ?? s : start.addingTimeInterval(TimeInterval(minutes * 60))
            return AgendaEvent(eventID: id, title: title, start: s, end: e, isAllDay: allDay, location: location,
                               color: c.color, calendarID: c.id, calendarTitle: c.title, videoLink: video, attendees: people)
        }
        return [
            event("bday", "Maya’s birthday", at(4, 0), minutes: 1440, family, allDay: true),
            event("standup", "Team standup", at(4, 9, 30), minutes: 15, work, link: "https://acme.zoom.us/j/84213377610?pwd=Qx7", people: 8),
            event("review", "Design review: onboarding flow", at(4, 10), minutes: 60, work, location: "Room 4B",
                  link: "https://meet.google.com/rtx-kqpd-hzw", people: 6),
            event("lunch", "Lunch with Priya", at(4, 12, 30), minutes: 60, personal, location: "Corner Café"),
            event("oneonone", "1:1 with Jonas", at(4, 15), minutes: 30, work, link: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmQx@thread.v2/0"),
            event("yoga", "Yoga", at(4, 18, 30), minutes: 60, personal, location: "Studio Nord"),
            event("planning", "Sprint planning", at(2, 10), minutes: 90, work, link: "https://acme.zoom.us/j/91877001234"),
            event("dentist", "Dentist", at(6, 8, 15), minutes: 45, personal),
            event("offsite", "Team offsite", at(9, 0), minutes: 2880, work, location: "Lisbon", allDay: true),
            event("parents", "Call with Mom and Dad", at(8, 17), minutes: 30, family, link: "https://facetime.apple.com/join#v=1&p=AbCdEf&k=XyZ"),
            event("demo", "Customer demo", at(12, 14), minutes: 45, work, link: "https://acme.webex.com/meet/jonas.berg"),
            event("retro", "Retrospective", at(13, 16), minutes: 60, work, link: "https://acme.zoom.us/j/84213377610"),
            event("concert", "Concert", at(14, 20), minutes: 120, personal, location: "Philharmonie"),
            event("thanks", "Thanksgiving", at(26, 0), minutes: 1440, holidays, allDay: true),
            event("review2", "Quarterly review", at(19, 11), minutes: 60, work, link: "https://meet.google.com/abc-defg-hij"),
            event("market", "Farmers market", at(21, 9), minutes: 120, family),
        ]
    }

    // MARK: Composition

    static func desktop<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                        Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            .ignoresSafeArea()
    }

    /// The right end of a menu bar with `item` in it.
    private static func strip<V: View>(_ item: V) -> some View {
        HStack(spacing: 16) {
            Spacer()
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            item
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.black.opacity(0.18))
    }

    private static func dropped(_ m: MenuBarCalendarModule) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            strip(MenuBarItemMock(style: .text, text: formatter().string(MenuBarToken.defaultFormat, date: sampleNow), day: 4, highlighted: true))
            CalendarPanelView(module: m, model: m.model, fixedNow: sampleNow)
                .padding(.trailing, 8)
        }
    }

    /// Several formats as they look in the menu bar.
    private static func menuBarStrings() -> some View {
        let f = formatter()
        let rows: [(MenuBarStyle, [MenuBarToken])] = [
            (.text, MenuBarToken.defaultFormat),
            (.text, [.weekday(short: true), .date(.dayMonth), .text("·"), .time(seconds: false)]),
            (.iconAndText, [.weekNumber, .text("·"), .time(seconds: false)]),
            (.text, [.date(.dayMonthYear), .time(seconds: true), .timeZone]),
            (.text, [.weekday(short: false), .date(.numeric)]),
            (.icon, []),
        ]
        return VStack(spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                strip(MenuBarItemMock(style: row.0, text: f.string(row.1, date: sampleNow.addingTimeInterval(7)), day: 4))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 34)
    }
}
