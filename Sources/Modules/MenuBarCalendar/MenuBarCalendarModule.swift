import AppKit
@preconcurrency import EventKit
import MacToysCore
import SwiftUI

/// Menu Bar Calendar: a calendar, world clocks and your next meeting in the menu bar.
@MainActor
public final class MenuBarCalendarModule: ToyModule {
    public let info = ModuleInfo(
        id: "calendar", name: "Menu Bar Calendar",
        summary: "A calendar, world clocks and your next meeting in the menu bar.",
        symbol: "calendar", tint: .red, category: .systemTools,
        permissions: [.calendar], enabledByDefault: false,
        keywords: ["calendar", "date", "week number", "time zone", "world clock", "meeting", "events", "zoom", "clock", "menu bar"])

    let settings: Persisted<CalendarSettings>
    let model = CalendarModel()
    let log = Log.for("calendar")

    private var running = false
    private lazy var statusItem = CalendarStatusItem(module: self)
    private var panel: CalendarPanel?
    private let reminders = ReminderPresenter()
    private var tick: Timer?
    private var upcomingTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastShortcut: Shortcut??
    private var remindedIDs: Set<String> = []
    private var lastMinute = -1

    private static let hotkeyID = "calendar.open"

    public convenience init() {
        self.init(store: .shared)
        // Access granted or revoked in System Settings while running: show or hide events.
        PermissionCenter.shared.onChange { [weak self] granted in
            guard let self, self.running, granted.contains(.calendar) != (self.model.access == .granted) else { return }
            self.model.reloadAll()
        }
    }

    init(store: SettingsStore) {
        settings = Persisted("calendar", default: CalendarSettings(), store: store)
        settings.onChange { [weak self] _ in self?.settingsChanged() }
        reminders.onJoin = { [weak self] event in
            guard event.eventID != Self.exampleID else { return }
            if let link = event.videoLink { self?.join(link) }
        }
        applyCalendarSettings()
    }

    // MARK: - Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        statusItem.install()
        registerHotkey()
        let center = NotificationCenter.default
        observe(center, .EKEventStoreChanged) { $0.storeChanged() }
        observe(center, .NSSystemClockDidChange) { $0.clockChanged() }
        observe(center, .NSSystemTimeZoneDidChange) { $0.clockChanged() }
        observe(center, .NSCalendarDayChanged) { $0.clockChanged() }
        observe(center, NSLocale.currentLocaleDidChangeNotification) { $0.clockChanged() }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { $0.clockChanged() }
        observe(DistributedNotificationCenter.default(), SettingsStore.externalChangeNotification) { $0.settings.reload() }
        model.goToToday()
        model.reloadAll()
        updateMenuBar()
        scheduleTick()
        scheduleUpcomingRefresh()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        lastShortcut = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tick?.invalidate()
        tick = nil
        upcomingTimer?.invalidate()
        upcomingTimer = nil
        closePanel()
        reminders.dismissAll()
        statusItem.remove()
        settings.flush()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ body: @escaping @MainActor (MenuBarCalendarModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }

    private func settingsChanged() {
        applyCalendarSettings()
        guard running else { return }
        registerHotkey()
        updateMenuBar()
        scheduleTick()
        model.reloadAll()
    }

    /// Copies first weekday, week numbering and excluded calendars into the model.
    private func applyCalendarSettings() {
        let s = settings.value
        var cal = Calendar.autoupdatingCurrent
        cal.firstWeekday = s.firstWeekday.value(for: Calendar.current)
        model.calendar = cal
        model.firstWeekday = cal.firstWeekday
        model.numbering = s.weekNumbering
        model.excluded = Set(s.excludedCalendars)
    }

    private func registerHotkey() {
        let shortcut = settings.value.shortcut
        guard lastShortcut != .some(shortcut) else { return }
        lastShortcut = .some(shortcut)
        HotkeyCenter.shared.register(Self.hotkeyID, shortcut) { [weak self] in self?.togglePanel() }
    }

    // MARK: - Clock

    var locale: Locale { .autoupdatingCurrent }
    /// The locale with the chosen 12/24-hour clock.
    var clockLocale: Locale { settings.value.hourCycle.apply(to: .current) }

    var formatter: MenuBarFormatter {
        MenuBarFormatter(locale: .current, timeZone: .current, hourCycle: settings.value.hourCycle,
                         weekNumbering: settings.value.weekNumbering, calendar: model.calendar)
    }

    /// Fires on each minute (or second) boundary, so the menu bar changes when the clock does.
    private func scheduleTick() {
        tick?.invalidate()
        let interval = MenuBarFormatter.refreshInterval(settings.value.tokens)
        let now = Date().timeIntervalSinceReferenceDate
        let next = Date(timeIntervalSinceReferenceDate: (floor(now / interval) + 1) * interval + 0.02)
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.minuteWork()
                self.updateMenuBar()
                self.scheduleTick()
            }
        }
        t.tolerance = interval < 2 ? 0.05 : 0.3
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func updateMenuBar() {
        let now = Date()
        let s = settings.value
        let text = formatter.string(s.tokens, date: now)
        let day = model.calendar.component(.day, from: now)
        let spoken = now.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: clockLocale))
        statusItem.refresh(text: text.isEmpty && s.style == .text ? String(day) : text, day: day, style: s.style, accessibility: spoken)
    }

    /// Once a minute: keep the panel's "now" current and check reminders.
    private func minuteWork() {
        let now = Date()
        let minute = Int(now.timeIntervalSinceReferenceDate / 60)
        guard minute != lastMinute else { return }
        lastMinute = minute
        if !model.calendar.isDate(model.now, inSameDayAs: now) {
            let wasToday = model.isShowingToday
            model.now = now
            if wasToday { model.goToToday() }
        } else {
            model.now = now
        }
        checkReminders(now: now)
    }

    private func clockChanged() {
        applyCalendarSettings()
        lastMinute = -1
        minuteWork()
        updateMenuBar()
        scheduleTick()
        model.reloadAll()
    }

    // MARK: - Events and reminders

    private func storeChanged() {
        model.loader.reset()
        model.reloadAll()
    }

    /// Upcoming meetings are re-read every five minutes (and whenever the calendar database changes).
    private func scheduleUpcomingRefresh() {
        upcomingTimer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.model.reloadUpcoming { self.checkReminders(now: Date()) }
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        upcomingTimer = t
    }

    private func checkReminders(now: Date) {
        let s = settings.value
        guard let lead = s.reminderLead, model.access == .granted else { return }
        let due = Agenda.dueReminders(model.upcoming, now: now, lead: lead, onlyVideoCalls: s.remindOnlyVideoCalls, shown: remindedIDs)
        // The full-screen card is for the next meeting only; others become banners.
        for (i, e) in due.enumerated() {
            remindedIDs.insert(e.id)
            reminders.show(e, style: i == 0 ? s.reminderStyle : .banner, sound: s.reminderSound)
        }
        // Forget reminders of meetings long over.
        if remindedIDs.count > 200 {
            let live = Set(model.upcoming.map(\.id))
            remindedIDs = remindedIDs.intersection(live)
        }
    }

    func join(_ link: VideoLink) {
        let zoomInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") != nil
        let url = link.joinURL(zoomAppInstalled: zoomInstalled)
        closePanel()
        if !NSWorkspace.shared.open(url) {
            HUD.show("Couldn’t open the \(link.service.name) link", symbol: "exclamationmark.triangle")
        }
    }

    private static let exampleID = "mactoys.example"

    /// A sample reminder in the chosen style, from the settings page.
    func showExampleReminder() {
        let start = Date().addingTimeInterval(TimeInterval((settings.value.reminderLead ?? 2) * 60))
        let event = AgendaEvent(eventID: Self.exampleID, title: String(localized: "Example: Design review"),
                                start: start, end: start.addingTimeInterval(1800), location: nil, color: RGBA(Tint.blue.nsColor),
                                calendarID: "example", calendarTitle: String(localized: "Work", comment: "Example calendar name"),
                                videoLink: VideoLink(service: .zoom, url: URL(string: "https://zoom.us/j/0")!), attendees: 4)
        reminders.dismiss(event.id)
        reminders.show(event, style: settings.value.reminderStyle, sound: settings.value.reminderSound)
    }

    func joinNextCall() {
        guard let next = Agenda.nextCall(model.upcoming, now: Date()), let link = next.videoLink else {
            HUD.show("No call to join in the next hours", symbol: "video.slash")
            return
        }
        join(link)
    }

    // MARK: - Panel

    func togglePanel() {
        guard running else {
            ModuleRegistry.shared.showSettings?(info.id)
            return
        }
        if let panel, panel.isVisible { closePanel(); return }
        let p = panel ?? CalendarPanel(module: self)
        p.onClose = { [weak self] in self?.statusItem.setHighlighted(false) }
        panel = p
        model.now = Date()
        model.goToToday()
        model.reloadAll()
        p.present(below: statusItem.button)
        statusItem.setHighlighted(true)
    }

    func closePanel() {
        if panel?.isVisible == true { panel?.dismiss() }
    }

    /// "2026-11-04" in the local time zone.
    static var isoDay: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash)
    }

    static func openCalendarApp() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
            ?? URL(fileURLWithPath: "/System/Applications/Calendar.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Right-click menu: today's date, week number and time, ready to copy.
    func copyChoices(now: Date) -> [(String, String)] {
        let f = formatter
        let iso = now.formatted(Self.isoDay)
        return [
            (String(localized: "Date"), f.string([.weekday(short: false), .date(.dayMonthYear)], date: now)),
            (String(localized: "ISO 8601 date"), iso),
            (String(localized: "Week number"), f.string(.weekNumber, date: now)),
            (String(localized: "Time"), f.string(.time(seconds: false), date: now)),
        ]
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(CalendarSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "calendar.open", title: "Calendar", symbol: "calendar", tint: .red,
                     shortcut: settings.value.shortcut, perform: { [weak self] in self?.togglePanel() }),
         QuickAction(id: "calendar.join", title: "Join Next Call", symbol: "video.fill", tint: .green,
                     perform: { [weak self] in self?.joinNextCall() })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Open the calendar", settings.value.shortcut),
         ShortcutBinding("Join the next call (in the calendar)", keys: ["J"]),
         ShortcutBinding("Go to today (in the calendar)", keys: ["T"])]
    }

    /// `mactoys://calendar/<action>`: `open`/`show`/`toggle` (the panel), `today`, `join` (next call),
    /// `date?date=2026-12-24` (the panel at that day), `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        case "open", "show", "toggle":
            if command.action == "toggle" || panel?.isVisible != true { togglePanel() }
        case "today":
            if panel?.isVisible != true { togglePanel() }
            model.goToToday()
        case "date":
            guard let text = command.parameters["date"],
                  let date = try? Date(text, strategy: Self.isoDay) else { return false }
            if panel?.isVisible != true { togglePanel() }
            model.select(date)
        case "join":
            guard running else { return false }
            joinNextCall()
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] { CalendarScenes.all }
}
