import AppKit
import MacToysCore
import Observation

/// What the panel shows: the month, the selected day's agenda, upcoming meetings and the clock.
@MainActor
@Observable
final class CalendarModel {
    var access: CalendarAccess = .current
    var calendars: [CalendarInfo] = []
    /// Any date in the month on screen.
    var month: Date
    /// Start of the selected day.
    var selectedDay: Date
    /// The time the panel shows; ticks every minute.
    var now: Date
    /// Events in the six weeks the grid shows.
    var gridEvents: [AgendaEvent] = []
    var eventsByDay: [Date: [AgendaEvent]] = [:]
    /// Timed events from now through the next day, for reminders and "join next call".
    var upcoming: [AgendaEvent] = []
    /// False until the first read finishes (the agenda shows a spinner instead of "No events").
    var hasLoaded = false

    @ObservationIgnored let loader = EventLoader()
    @ObservationIgnored private var generation = 0
    /// Set by the module from the settings.
    @ObservationIgnored var calendar: Calendar = .current
    @ObservationIgnored var excluded: Set<String> = []
    @ObservationIgnored var firstWeekday = Calendar.current.firstWeekday
    @ObservationIgnored var numbering: WeekNumbering = .iso8601

    init(now: Date = Date()) {
        self.now = now
        self.month = now
        self.selectedDay = Calendar.current.startOfDay(for: now)
    }

    var weeks: [WeekMath.Week] {
        WeekMath.monthGrid(for: month, firstWeekday: firstWeekday, numbering: numbering, calendar: calendar)
    }

    var agenda: [AgendaEvent] { Agenda.events(gridEvents, on: selectedDay, calendar: calendar) }

    var isShowingToday: Bool { calendar.isDate(selectedDay, inSameDayAs: now) }

    // MARK: Navigation

    func goToToday() {
        now = Date()
        select(now)
    }

    func select(_ day: Date) {
        let start = calendar.startOfDay(for: day)
        let monthChanged = !calendar.isDate(start, equalTo: month, toGranularity: .month)
        selectedDay = start
        if monthChanged {
            month = start
            reloadGrid()
        }
    }

    func moveSelection(days: Int) {
        if let d = calendar.date(byAdding: .day, value: days, to: selectedDay) { select(d) }
    }

    func moveMonth(_ delta: Int) {
        guard let m = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        month = m
        // Keep the same day of the month where it exists.
        let day = calendar.component(.day, from: selectedDay)
        var c = calendar.dateComponents([.year, .month], from: m)
        let range = calendar.range(of: .day, in: .month, for: m) ?? 1..<29
        c.day = min(day, range.upperBound - 1)
        selectedDay = calendar.date(from: c).map { calendar.startOfDay(for: $0) } ?? m
        reloadGrid()
    }

    // MARK: Loading

    /// Re-reads access, calendars, the grid's events and upcoming meetings.
    func reloadAll() {
        access = .current
        guard access == .granted else {
            calendars = []
            gridEvents = []
            eventsByDay = [:]
            upcoming = []
            hasLoaded = true
            return
        }
        loader.calendars { [weak self] list in self?.calendars = list }
        reloadGrid()
        reloadUpcoming()
    }

    func reloadGrid() {
        guard access == .granted, let first = weeks.first?.days.first?.date, let last = weeks.last?.days.last?.date,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        generation += 1
        let gen = generation
        let cal = calendar
        loader.events(in: DateInterval(start: first, end: end), excluding: excluded) { [weak self] events in
            guard let self, gen == self.generation else { return }
            self.gridEvents = events
            self.eventsByDay = Agenda.byDay(events, calendar: cal)
            self.hasLoaded = true
        }
    }

    func reloadUpcoming(completion: (() -> Void)? = nil) {
        guard access == .granted else { upcoming = []; completion?(); return }
        let start = Date().addingTimeInterval(-3 * 3600)
        loader.events(in: DateInterval(start: start, duration: 30 * 3600), excluding: excluded) { [weak self] events in
            self?.upcoming = events.filter { !$0.isAllDay }
            completion?()
        }
    }

    func requestAccess() {
        loader.requestAccess { [weak self] _ in
            PermissionCenter.shared.refresh()
            self?.reloadAll()
        }
    }
}
