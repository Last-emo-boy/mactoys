import AppKit
import MacToysCore
import SwiftUI

/// The calendar panel under the menu bar item.
@MainActor
final class CalendarPanel: FloatingPanel {
    weak var module: MenuBarCalendarModule?
    private var pinnedTop: CGFloat?

    init(module: MenuBarCalendarModule) {
        self.module = module
        super.init(size: CGSize(width: CalendarPanelView.width, height: 480))
        isMovable = false
        isMovableByWindowBackground = false
        contentView = NSHostingView(rootView: CalendarPanelView(module: module, model: module.model)
            .fixedSize(horizontal: false, vertical: true))
    }

    func present(below button: NSStatusBarButton?) {
        let width = CalendarPanelView.width
        let height = max(200, contentView?.fittingSize.height ?? frame.height)
        let origin: CGPoint
        if let button, let window = button.window {
            let r = window.convertToScreen(button.convert(button.bounds, to: nil))
            let vf = (window.screen ?? NSScreen.main)?.visibleFrame ?? r
            let x = min(max(r.midX - width / 2, vf.minX + 8), vf.maxX - width - 8)
            pinnedTop = r.minY - 6
            origin = CGPoint(x: x, y: r.minY - 6 - height)
        } else {
            let vf = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
            pinnedTop = vf.maxY - 8
            origin = CGPoint(x: vf.maxX - width - 12, y: vf.maxY - 8 - height)
        }
        setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var r = frameRect
        if let top = pinnedTop { r.origin.y = top - r.height }
        super.setFrame(r, display: flag)
    }

    /// ← → days, ↑ ↓ weeks, ⌥← → months, T or Space today, J joins the next call.
    override func keyDown(with event: NSEvent) {
        guard let module else { super.keyDown(with: event); return }
        let model = module.model
        let option = event.modifierFlags.contains(.option)
        switch Int(event.keyCode) {
        case 123: option ? model.moveMonth(-1) : model.moveSelection(days: -1)
        case 124: option ? model.moveMonth(1) : model.moveSelection(days: 1)
        case 125: model.moveSelection(days: 7)
        case 126: model.moveSelection(days: -7)
        case 116: model.moveMonth(-1) // page up
        case 121: model.moveMonth(1)  // page down
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "t", " ": model.goToToday()
            case "j": module.joinNextCall()
            case "o": MenuBarCalendarModule.openCalendarApp()
            default: super.keyDown(with: event)
            }
        }
    }
}

/// Design: month with week numbers and event dots, the day's agenda with join buttons, world clocks.
struct CalendarPanelView: View {
    static let width: CGFloat = 340
    let module: MenuBarCalendarModule
    var model: CalendarModel
    @Bindable var settings: Persisted<CalendarSettings>
    /// Snapshots draw a fixed clock.
    var fixedNow: Date?

    init(module: MenuBarCalendarModule, model: CalendarModel, fixedNow: Date? = nil) {
        self.module = module
        self.model = model
        self.settings = module.settings
        self.fixedNow = fixedNow
    }

    var body: some View {
        GlassPanel(cornerRadius: 22) {
            VStack(alignment: .leading, spacing: 12) {
                header
                MonthGrid(module: module, model: model)
                Divider().opacity(0.5)
                AgendaSection(module: module, model: model)
                if settings.value.showWorldClocks && !settings.value.worldClocks.isEmpty {
                    Divider().opacity(0.5)
                    if let fixedNow {
                        WorldClockList(clocks: settings.value.worldClocks, now: fixedNow, locale: module.clockLocale)
                    } else {
                        TimelineView(.everyMinute) { context in
                            WorldClockList(clocks: settings.value.worldClocks, now: context.date, locale: module.clockLocale)
                        }
                    }
                }
                footer
            }
            .padding(14)
            .foregroundStyle(.white)
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.month.formatted(.dateTime.month(.wide).locale(module.locale)))
                .font(.system(size: 19, weight: .bold))
            Text(model.month.formatted(.dateTime.year().locale(module.locale)))
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                navButton("chevron.left", Text("Previous month")) { model.moveMonth(-1) }
                Button { model.goToToday() } label: {
                    Text("Today", comment: "Calendar button: go to today")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(.white.opacity(model.isShowingToday ? 0.06 : 0.14)))
                }
                .buttonStyle(.plain)
                .help(Text("Go to today (T)"))
                navButton("chevron.right", Text("Next month")) { model.moveMonth(1) }
            }
        }
    }

    private func navButton(_ symbol: String, _ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { MenuBarCalendarModule.openCalendarApp() } label: {
                Label("Open Calendar", systemImage: "calendar").font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            if Agenda.nextCall(model.upcoming, now: fixedNow ?? Date()) != nil {
                Keycaps(["J"], dark: true)
                Text("joins the next call").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button {
                module.closePanel()
                ModuleRegistry.shared.showSettings?(module.info.id)
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Menu Bar Calendar settings"))
        }
    }
}

/// The month: weekday header, optional week numbers, today, the selection and event dots.
private struct MonthGrid: View {
    let module: MenuBarCalendarModule
    var model: CalendarModel

    var body: some View {
        let s = module.settings.value
        let cal = model.calendar
        let headers = WeekMath.weekdayHeaders(firstWeekday: model.firstWeekday, calendar: cal)
        Grid(horizontalSpacing: 0, verticalSpacing: 2) {
            GridRow {
                if s.showWeekNumbers {
                    Text("W", comment: "Column header for week numbers; keep it one or two letters")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .frame(width: 26)
                }
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(verbatim: h).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 4)
            ForEach(model.weeks, id: \.self) { week in
                GridRow {
                    if s.showWeekNumbers {
                        Text(week.number, format: .number)
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 26)
                    }
                    ForEach(week.days, id: \.self) { day in
                        DayCell(day: day,
                                isToday: cal.isDate(day.date, inSameDayAs: model.now),
                                isSelected: cal.isDate(day.date, inSameDayAs: model.selectedDay),
                                events: s.showEventDots ? (model.eventsByDay[cal.startOfDay(for: day.date)] ?? []) : [],
                                locale: module.locale)
                            .onTapGesture { model.select(day.date) }
                    }
                }
            }
        }
    }
}

private struct DayCell: View {
    let day: WeekMath.Day
    let isToday: Bool
    let isSelected: Bool
    let events: [AgendaEvent]
    let locale: Locale

    var body: some View {
        VStack(spacing: 2) {
            Text(day.day, format: .number.locale(locale))
                .font(.system(size: 12.5, weight: isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? Color.white : day.inMonth ? (day.isWeekend ? Color.white.opacity(0.62) : Color.white) : Color.white.opacity(0.3))
                .frame(width: 26, height: 26)
                .background {
                    if isToday {
                        Circle().fill(Tint.red.color)
                    } else if isSelected {
                        Circle().fill(.white.opacity(0.16))
                    }
                }
                .overlay {
                    if isToday && isSelected { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5).padding(-2) }
                }
            HStack(spacing: 2) {
                ForEach(Array(dotColors.enumerated()), id: \.offset) { _, c in
                    Circle().fill(c).frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
            .opacity(day.inMonth ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: day.date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(locale))))
        .accessibilityValue(events.isEmpty ? Text("") : Text("\(events.count) events", comment: "Accessibility: number of events on a day"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Up to three dots, one per calendar.
    private var dotColors: [Color] {
        var seen: [String] = []
        var out: [Color] = []
        for e in events where !seen.contains(e.calendarID) {
            seen.append(e.calendarID)
            out.append(e.color.color)
            if out.count == 3 { break }
        }
        return out
    }
}

/// The selected day's events, or what to do when they can't be shown.
private struct AgendaSection: View {
    let module: MenuBarCalendarModule
    var model: CalendarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: model.selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(module.locale)))
                    .font(.system(size: 13, weight: .semibold))
                if model.isShowingToday {
                    Text("Today", comment: "Label next to today's date in the agenda")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Tint.red.color)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Tint.red.color.opacity(0.18)))
                }
                Spacer()
            }
            switch model.access {
            case .granted:
                let events = model.agenda
                if !model.hasLoaded {
                    HStack { ProgressView().controlSize(.small); Spacer() }.frame(height: 40)
                } else if events.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        Text("Nothing scheduled").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                    .frame(height: 34)
                } else {
                    let rows = CGFloat(min(events.count, 5))
                    ScrollView(.vertical) {
                        VStack(spacing: 4) {
                            ForEach(events) { e in EventRow(module: module, event: e, day: model.selectedDay, now: model.now) }
                        }
                    }
                    .scrollIndicators(events.count > 5 ? .automatic : .never)
                    .frame(height: rows * 46 + (rows - 1) * 4)
                }
            case .notDetermined, .denied:
                AccessCard(denied: model.access == .denied) {
                    if model.access == .denied { PermissionCenter.shared.openSettings(.calendar) } else { model.requestAccess() }
                }
            }
        }
    }
}

private struct EventRow: View {
    let module: MenuBarCalendarModule
    let event: AgendaEvent
    let day: Date
    let now: Date

    var body: some View {
        let cal = module.model.calendar
        let current = event.isHappening(at: now) && !event.isAllDay
        let past = event.end <= now
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.color.color)
                .frame(width: 4)
                .padding(.vertical, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(verbatim: event.timeText(on: day, calendar: cal, locale: module.clockLocale)).monospacedDigit()
                    if let location = event.location, !location.isEmpty, event.videoLink?.url.absoluteString != location {
                        Text(verbatim: "·")
                        Text(verbatim: location).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let link = event.videoLink, !past {
                Button { module.join(link) } label: {
                    Label("Join", systemImage: "video.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(current ? Tint.green.color : Color.white.opacity(0.14)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(Text("Join with \(link.service.name)", comment: "Button help; the placeholder is a video call service like Zoom"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(current ? 0.12 : 0.05)))
        .opacity(past ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { MenuBarCalendarModule.openCalendarApp() }
    }
}

private struct AccessCard: View {
    let denied: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar.badge.lock")
                .font(.system(size: 20))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Tint.red.color)
            VStack(alignment: .leading, spacing: 6) {
                Text("See your events here").font(.system(size: 12.5, weight: .semibold))
                Text("Allow access to your calendars to show events and remind you of meetings. The calendar and world clocks work without it.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    (denied ? Text("Open System Settings") : Text("Allow Calendar Access"))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(Tint.red.color))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// World clocks: day or night, name, difference from here, and the time there.
struct WorldClockList: View {
    let clocks: [WorldClock]
    let now: Date
    let locale: Locale

    var body: some View {
        VStack(spacing: 6) {
            ForEach(clocks) { clock in
                let zone = clock.timeZone
                let reading = ClockReading(date: now, zone: zone, reference: .current)
                HStack(spacing: 10) {
                    Image(systemName: reading.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 13))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: clock.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        Text(verbatim: [reading.dayText, reading.offsetText(locale: locale)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: now.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone)))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
