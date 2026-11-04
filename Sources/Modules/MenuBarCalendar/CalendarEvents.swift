import AppKit
@preconcurrency import EventKit
import MacToysCore

/// One event as the panel and reminders use it (a plain value, safe to pass between threads).
struct AgendaEvent: Identifiable, Hashable, Sendable {
    /// Unique per occurrence: recurring events share an identifier, so the start is part of it.
    let id: String
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let color: RGBA
    let calendarID: String
    let calendarTitle: String
    let videoLink: VideoLink?
    let attendees: Int

    init(eventID: String, title: String, start: Date, end: Date, isAllDay: Bool = false, location: String? = nil,
         color: RGBA, calendarID: String, calendarTitle: String, videoLink: VideoLink? = nil, attendees: Int = 0) {
        self.id = "\(eventID)@\(Int(start.timeIntervalSince1970))"
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.color = color
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.videoLink = videoLink
        self.attendees = attendees
    }

    func isHappening(at date: Date) -> Bool { start <= date && date < end }
}

/// A calendar the user can include or leave out.
struct CalendarInfo: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let color: RGBA
    let source: String
}

enum CalendarAccess: Equatable, Sendable {
    case granted, notDetermined, denied

    static var current: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}

/// Reads EventKit on its own queue and hands back plain values.
final class EventLoader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.w33d.mactoys.calendar.eventkit", qos: .userInitiated)
    private var store: EKEventStore?

    /// The store, created on first use (after access is granted, so it sees every calendar).
    private func currentStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    /// Requests full access; `completion` runs on the main actor.
    func requestAccess(completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            let store = self.currentStore()
            store.requestFullAccessToEvents { granted, error in
                if let error { Log.for("calendar").error("Calendar access: \(error.localizedDescription, privacy: .public)") }
                self.queue.async {
                    // A store made before access was granted keeps seeing nothing: start over.
                    if granted { self.store = nil }
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
                }
            }
        }
    }

    /// Drops the store so the next read sees calendars added or changed in another app.
    func reset() {
        queue.async { self.store?.reset() }
    }

    func calendars(completion: @escaping @MainActor ([CalendarInfo]) -> Void) {
        queue.async {
            guard CalendarAccess.current == .granted else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
                return
            }
            let list = self.currentStore().calendars(for: .event).map {
                CalendarInfo(id: $0.calendarIdentifier, title: $0.title, color: RGBA($0.color ?? .systemRed),
                             source: $0.source?.title ?? "")
            }.sorted { $0.source != $1.source ? $0.source < $1.source : $0.title < $1.title }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(list) } }
        }
    }

    /// Events overlapping `interval` in calendars not excluded, without ones you declined.
    func events(in interval: DateInterval, excluding: Set<String>, completion: @escaping @MainActor ([AgendaEvent]) -> Void) {
        queue.async {
            guard CalendarAccess.current == .granted else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion([]) } }
                return
            }
            let store = self.currentStore()
            let calendars = store.calendars(for: .event).filter { !excluding.contains($0.calendarIdentifier) }
            var result: [AgendaEvent] = []
            if !calendars.isEmpty {
                let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
                result = store.events(matching: predicate).compactMap(Self.agendaEvent)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    private static func agendaEvent(_ e: EKEvent) -> AgendaEvent? {
        if e.status == .canceled { return nil }
        if let me = e.attendees?.first(where: \.isCurrentUser), me.participantStatus == .declined { return nil }
        guard let start = e.startDate, let end = e.endDate else { return nil }
        let title = (e.title?.isEmpty == false ? e.title : nil) ?? String(localized: "New Event", comment: "Title of a calendar event that has none")
        return AgendaEvent(eventID: e.eventIdentifier ?? e.calendarItemIdentifier, title: title, start: start, end: end,
                           isAllDay: e.isAllDay, location: e.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                           color: RGBA(e.calendar.color ?? .systemRed), calendarID: e.calendar.calendarIdentifier,
                           calendarTitle: e.calendar.title,
                           videoLink: VideoLinks.find(url: e.url, location: e.location, notes: e.notes),
                           attendees: e.attendees?.count ?? 0)
    }
}

/// Pure rules for the agenda and meeting reminders.
enum Agenda {
    /// Events on `day` (any part of it), all-day ones first, then by start time.
    static func events(_ all: [AgendaEvent], on day: Date, calendar: Calendar) -> [AgendaEvent] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return all.filter { $0.start < interval.end && $0.end > interval.start || ($0.start == $0.end && interval.contains($0.start)) }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start != b.start ? a.start < b.start : a.title < b.title
            }
    }

    /// Start-of-day → events, for the month grid's dots (multi-day events mark every day).
    static func byDay(_ all: [AgendaEvent], calendar: Calendar) -> [Date: [AgendaEvent]] {
        var out: [Date: [AgendaEvent]] = [:]
        for e in all {
            var day = calendar.startOfDay(for: e.start)
            let last = e.end > e.start ? e.end.addingTimeInterval(-1) : e.start
            var guardCount = 0
            while day <= last && guardCount < 62 {
                out[day, default: []].append(e)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                guardCount += 1
            }
        }
        return out
    }

    /// Meetings whose reminder is due now: timed, starting within `lead` minutes (or started less than
    /// two minutes ago, so a Mac waking up late still shows it), and not shown before.
    static func dueReminders(_ events: [AgendaEvent], now: Date, lead: Int, onlyVideoCalls: Bool, shown: Set<String>) -> [AgendaEvent] {
        events.filter { e in
            guard !e.isAllDay, !shown.contains(e.id) else { return false }
            if onlyVideoCalls && e.videoLink == nil { return false }
            let remindAt = e.start.addingTimeInterval(TimeInterval(-lead * 60))
            return remindAt <= now && now < e.start.addingTimeInterval(120) && now < e.end
        }
        .sorted { $0.start < $1.start }
    }

    /// The next call to join: one happening now (latest started first), else the soonest one in the next 12 hours.
    static func nextCall(_ events: [AgendaEvent], now: Date) -> AgendaEvent? {
        let calls = events.filter { $0.videoLink != nil && !$0.isAllDay && $0.end > now }
        if let current = calls.filter({ $0.isHappening(at: now) }).max(by: { $0.start < $1.start }) { return current }
        return calls.filter { $0.start > now && $0.start.timeIntervalSince(now) < 12 * 3600 }.min { $0.start < $1.start }
    }
}

extension AgendaEvent {
    /// "09:30 – 10:00", "All day", or "Until 18:00" on later days of a multi-day event.
    func timeText(on day: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if isAllDay { return String(localized: "All day", comment: "Calendar event that lasts the whole day") }
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .hour().minute()
        let startsToday = calendar.isDate(start, inSameDayAs: day)
        let endsToday = calendar.isDate(end, inSameDayAs: day) || end == calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
        switch (startsToday, endsToday) {
        case (true, true): return "\(start.formatted(style)) – \(end.formatted(style))"
        case (true, false): return String(localized: "From \(start.formatted(style))", comment: "Multi-day event: starts at this time today")
        case (false, true): return String(localized: "Until \(end.formatted(style))", comment: "Multi-day event: ends at this time today")
        case (false, false): return String(localized: "All day", comment: "Calendar event that lasts the whole day")
        }
    }

    /// "in 5 min", "now", "started 3 min ago".
    func relativeStart(now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes > 0 {
            return String(localized: "calendar.starts-in",
                          defaultValue: "in \(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))",
                          comment: "A meeting starts in this much time; the placeholder is a duration such as '5 min'")
        }
        let ago = Int(now.timeIntervalSince(start) / 60)
        if ago < 1 { return String(localized: "now", comment: "A meeting is starting now") }
        return String(localized: "started \(Duration.seconds(ago * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) ago",
                      comment: "A meeting started this long ago")
    }
}
