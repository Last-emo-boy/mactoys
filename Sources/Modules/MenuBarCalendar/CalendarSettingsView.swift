import AppKit
import MacToysCore
import SwiftUI

struct CalendarSettingsView: View {
    let module: MenuBarCalendarModule
    @Bindable var s: Persisted<CalendarSettings>
    var model: CalendarModel
    @State private var customText = ""
    @State private var citySearch = ""

    init(module: MenuBarCalendarModule) {
        self.module = module
        self.s = module.settings
        self.model = module.model
    }

    var body: some View {
        SettingsPage(module: module) {
            CalendarHero(module: module)
        } content: {
            menuBarSection
            calendarSection
            calendarsSection
            remindersSection
            clocksSection
            Section("Keyboard") {
                ShortcutRow("Open the calendar", subtitle: "Or click the date in the menu bar. Right-click it to copy the date, week number or time.",
                            shortcut: $s.value.shortcut)
                CalendarKeyRow(title: Text("Move by day or week"), keys: ["←", "→", "↑", "↓"])
                CalendarKeyRow(title: Text("Previous or next month"), keys: ["⌥", "←", "→"])
                CalendarKeyRow(title: Text("Go to today"), keys: ["T"])
                CalendarKeyRow(title: Text("Join the next call"), keys: ["J"])
                CalendarKeyRow(title: Text("Open the Calendar app"), keys: ["O"])
            }
        }
        .onAppear { model.reloadAll() }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        Section("Menu bar") {
            Picker(selection: $s.value.style) {
                ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Show", subtitle: "The macOS clock stays in the menu bar; turn it to analog or hide the date in Control Center settings if you like.")
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    RowLabel("Format", subtitle: "Click a piece to move or remove it. Dates follow your region’s order.")
                    Spacer()
                    Menu {
                        ForEach(Array(MenuBarToken.presets.enumerated()), id: \.offset) { _, preset in
                            Button {
                                s.value.tokens = preset
                            } label: {
                                Text(verbatim: module.formatter.string(preset, date: Date()))
                            }
                        }
                    } label: {
                        Text("Presets")
                    }
                    .fixedSize()
                }
                FormatPreview(module: module)
                FlowLayout(spacing: 6) {
                    ForEach(Array(s.value.tokens.enumerated()), id: \.offset) { index, token in
                        TokenChip(token: token, sample: module.formatter.string(token, date: Date()),
                                  canMoveLeft: index > 0, canMoveRight: index < s.value.tokens.count - 1,
                                  move: { delta in move(index, by: delta) },
                                  remove: { s.value.tokens.remove(at: index) })
                    }
                    addMenu
                }
                CustomTextAdder(text: $customText) { text in s.value.tokens.append(.text(text)) }
            }
            .disabled(s.value.style == .icon)
            Picker(selection: $s.value.hourCycle) {
                ForEach(HourCycle.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Clock", subtitle: "Also for the agenda and world clocks.")
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Section("Date and time") {
                ForEach(MenuBarToken.palette) { token in
                    Button {
                        s.value.tokens.append(token)
                    } label: {
                        Text("\(token.title) (\(module.formatter.string(token, date: Date())))",
                             comment: "Format builder menu item: a token name and its current value in parentheses")
                    }
                }
            }
            Section("Separators") {
                ForEach(MenuBarToken.separators) { token in
                    Button { s.value.tokens.append(token) } label: { Text(verbatim: token.title) }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .fixedSize()
        .help(Text("Add a piece to the menu bar text"))
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard s.value.tokens.indices.contains(index), s.value.tokens.indices.contains(target) else { return }
        s.value.tokens.swapAt(index, target)
    }

    // MARK: Calendar

    private var calendarSection: some View {
        Section("Calendar") {
            Picker(selection: $s.value.firstWeekday) {
                ForEach(FirstWeekday.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("First day of the week")
            }
            Toggle(isOn: $s.value.showWeekNumbers) {
                RowLabel("Show week numbers")
            }
            Picker(selection: $s.value.weekNumbering) {
                ForEach(WeekNumbering.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Week numbers", subtitle: "ISO 8601: weeks start on Monday and week 1 has the year’s first Thursday. Regional: your region’s rule.")
            }
            Toggle(isOn: $s.value.showEventDots) {
                RowLabel("Show dots for days with events")
            }
        }
    }

    @ViewBuilder private var calendarsSection: some View {
        Section {
            switch model.access {
            case .granted:
                if model.calendars.isEmpty {
                    Text("No calendars yet. Add accounts in the Calendar app or in System Settings › Internet Accounts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    let sources = Array(Set(model.calendars.map(\.source))).sorted()
                    ForEach(sources, id: \.self) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: source.isEmpty ? String(localized: "Other", comment: "Calendar account group without a name") : source)
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(model.calendars.filter { $0.source == source }) { c in
                                Toggle(isOn: included(c.id)) {
                                    HStack(spacing: 8) {
                                        Circle().fill(c.color.color).frame(width: 10, height: 10)
                                        Text(verbatim: c.title)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            case .notDetermined, .denied:
                InfoBar(.info, title: Text("Allow access to your calendars"),
                        message: Text("Events, dots and meeting reminders need it. The calendar and world clocks work without it."),
                        actionTitle: model.access == .denied ? Text("Open System Settings") : Text("Allow Access")) {
                    if model.access == .denied { PermissionCenter.shared.openSettings(.calendar) } else { model.requestAccess() }
                }
            }
        } header: {
            Text("Calendars to show")
        } footer: {
            if model.access == .granted {
                Text("Declined and canceled events are left out. New calendars are shown until you turn them off.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func included(_ id: String) -> Binding<Bool> {
        Binding(get: { !s.value.excludedCalendars.contains(id) },
                set: { on in
                    if on { s.value.excludedCalendars.removeAll { $0 == id } }
                    else if !s.value.excludedCalendars.contains(id) { s.value.excludedCalendars.append(id) }
                })
    }

    // MARK: Reminders

    private var remindersSection: some View {
        Section("Meeting reminders") {
            Picker(selection: $s.value.reminderLead) {
                Text("Off", comment: "Meeting reminders: none").tag(Int?.none)
                Divider()
                ForEach(CalendarSettings.leadOptions, id: \.self) { m in
                    Text(m == 0 ? CalendarSettings.leadTitle(0)
                         : String(localized: "\(CalendarSettings.leadTitle(m)) before", comment: "Reminder lead time, e.g. '2 minutes before'"))
                        .tag(Optional(m))
                }
            } label: {
                RowLabel("Remind me", subtitle: "A reminder with a Join button, so you’re never late to a call.")
            }
            Group {
                Picker(selection: $s.value.reminderStyle) {
                    ForEach(ReminderStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Style", subtitle: "Full screen dims the desktop and shows the next meeting in a large card; press Return to join or Esc to dismiss.")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $s.value.remindOnlyVideoCalls) {
                    RowLabel("Only for meetings with a video call link",
                             subtitle: "Links to Zoom, Google Meet, Microsoft Teams, Webex and FaceTime are found in the event’s URL, location and notes.")
                }
                Toggle(isOn: $s.value.reminderSound) {
                    RowLabel("Play a sound")
                }
                LabeledContent {
                    Button("Show Example") { module.showExampleReminder() }
                } label: {
                    RowLabel("Try it")
                }
            }
            .disabled(s.value.reminderLead == nil)
        }
    }

    // MARK: World clocks

    private var clocksSection: some View {
        Section("World clocks") {
            Toggle(isOn: $s.value.showWorldClocks) {
                RowLabel("Show world clocks in the calendar", subtitle: "With the time difference and whether it’s day or night there.")
            }
            ForEach(Array(s.value.worldClocks.enumerated()), id: \.element.id) { index, clock in
                WorldClockRow(clock: clockBinding(clock.id), locale: module.clockLocale,
                              canMoveUp: index > 0, canMoveDown: index < s.value.worldClocks.count - 1,
                              move: { delta in moveClock(index, by: delta) },
                              remove: { s.value.worldClocks.removeAll { $0.id == clock.id } })
            }
            VStack(alignment: .leading, spacing: 6) {
                TextField("Add a clock", text: $citySearch,
                          prompt: Text("Add a city or time zone, like Tokyo, Paris or PST"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit {
                        if let first = WorldClockSearch.search(citySearch).first { addClock(first) }
                    }
                let results = WorldClockSearch.search(citySearch, limit: 6)
                if !citySearch.isEmpty && results.isEmpty {
                    Text("No matching city or time zone.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(results) { city in
                    Button { addClock(city) } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            Text(verbatim: city.name)
                            Text(verbatim: city.region.isEmpty ? city.timeZoneID : city.countryName()).foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: module.clockLocale,
                                                                             timeZone: TimeZone(identifier: city.timeZoneID) ?? .current)))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func clockBinding(_ id: UUID) -> Binding<WorldClock> {
        Binding(get: { s.value.worldClocks.first { $0.id == id } ?? WorldClock(timeZoneID: "UTC", name: "UTC") },
                set: { new in
                    if let i = s.value.worldClocks.firstIndex(where: { $0.id == id }) { s.value.worldClocks[i] = new }
                })
    }

    private func moveClock(_ index: Int, by delta: Int) {
        let target = index + delta
        guard s.value.worldClocks.indices.contains(target) else { return }
        s.value.worldClocks.swapAt(index, target)
    }

    private func addClock(_ city: CityEntry) {
        s.value.worldClocks.append(WorldClock(timeZoneID: city.timeZoneID, name: city.name))
        citySearch = ""
    }
}

/// A field and button that add your own text to the format.
private struct CustomTextAdder: View {
    @Binding var text: String
    let add: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("Text", text: $text, prompt: Text("Your text", comment: "Placeholder: custom text to add to the menu bar format"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 150)
                .onSubmit(submit)
            Button("Add Text", action: submit)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        add(t)
        text = ""
    }
}

/// One piece of the format: its current value; click for move and remove.
private struct TokenChip: View {
    let token: MenuBarToken
    let sample: String
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        Menu {
            Button("Move Left") { move(-1) }.disabled(!canMoveLeft)
            Button("Move Right") { move(1) }.disabled(!canMoveRight)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: sample).font(.system(size: 12, weight: .semibold).monospacedDigit())
                if !token.isText {
                    Text(verbatim: token.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(token.isText ? Color.primary.opacity(0.05) : Tint.red.color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(token.isText ? Color.primary.opacity(0.12) : Tint.red.color.opacity(0.3)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text(verbatim: token.title))
    }
}

/// What the menu bar item looks like right now.
private struct FormatPreview: View {
    let module: MenuBarCalendarModule

    var body: some View {
        let s = module.settings.value
        TimelineView(.periodic(from: .now, by: MenuBarFormatter.refreshInterval(s.tokens))) { context in
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi")
                MenuBarItemMock(style: s.style, text: module.formatter.string(s.tokens, date: context.date),
                                day: module.model.calendar.component(.day, from: context.date))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.42), Color(red: 0.5, green: 0.24, blue: 0.55)],
                               startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// The menu bar item drawn in SwiftUI (icon and/or text), for previews.
struct MenuBarItemMock: View {
    let style: MenuBarStyle
    let text: String
    let day: Int
    var highlighted = false

    var body: some View {
        HStack(spacing: 5) {
            if style != .text {
                Image(nsImage: DayIcon.image(day: day)).renderingMode(.template)
            }
            if style != .icon {
                Text(verbatim: text).monospacedDigit()
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(highlighted ? 0.22 : 0)))
    }
}

private struct WorldClockRow: View {
    @Binding var clock: WorldClock
    let locale: Locale
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        TimelineView(.everyMinute) { context in
            let reading = ClockReading(date: context.date, zone: clock.timeZone, reference: .current)
            HStack(spacing: 10) {
                // The multicolor moon is white; on a light row it needs a color of its own.
                Group {
                    if reading.daylight == .night {
                        Image(systemName: reading.symbol).symbolRenderingMode(.hierarchical).foregroundStyle(Tint.indigo.color)
                    } else {
                        Image(systemName: reading.symbol).symbolRenderingMode(.multicolor)
                    }
                }
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    TextField("Name", text: $clock.name, prompt: Text(verbatim: clock.timeZoneID))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(.system(size: 13, weight: .medium))
                        .help(Text("Click to rename"))
                    Text(verbatim: [clock.timeZoneID, reading.dayText, reading.offsetText(locale: locale)].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: clock.timeZone)))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                Menu {
                    Button("Move Up") { move(-1) }.disabled(!canMoveUp)
                    Button("Move Down") { move(1) }.disabled(!canMoveDown)
                    Divider()
                    Button("Remove", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

private struct CalendarKeyRow: View {
    let title: Text
    let keys: [String]

    var body: some View {
        LabeledContent { Keycaps(keys) } label: { title }
    }
}

/// The hero: a strip of menu bar with the item as set up, and the calendar dropping from it.
private struct CalendarHero: View {
    let module: MenuBarCalendarModule

    var body: some View {
        HeroCard(tint: .red) {
            HStack(alignment: .center, spacing: 20) {
                CalendarMiniScreen(module: module)
                    .frame(width: 290, height: 176)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Today, your week and the world, one click away").font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("The date in the menu bar opens a month with week numbers, the day’s events with Join buttons, and clocks for the places you work with.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Open Calendar") { module.togglePanel() }
                            .buttonStyle(.borderedProminent)
                            .tint(Tint.red.color)
                        if let shortcut = module.settings.value.shortcut { Keycaps(shortcut) }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// A miniature desktop with the configured menu bar item and a tiny month under it.
private struct CalendarMiniScreen: View {
    let module: MenuBarCalendarModule

    var body: some View {
        let s = module.settings.value
        let cal = module.model.calendar
        TimelineView(.everyMinute) { context in
            let now = context.date
            let weeks = WeekMath.monthGrid(for: now, firstWeekday: module.model.firstWeekday, numbering: s.weekNumbering, calendar: cal)
            ZStack(alignment: .topTrailing) {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                        Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "wifi").font(.system(size: 9, weight: .semibold))
                        MenuBarItemMock(style: s.style, text: module.formatter.string(s.tokens, date: now),
                                        day: cal.component(.day, from: now), highlighted: true)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(.black.opacity(0.22))
                    VStack(spacing: 3) {
                        ForEach(weeks.prefix(5), id: \.self) { week in
                            HStack(spacing: 3) {
                                if s.showWeekNumbers {
                                    Text(week.number, format: .number).font(.system(size: 6.5).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                                        .frame(width: 10)
                                }
                                ForEach(week.days, id: \.self) { day in
                                    let today = cal.isDate(day.date, inSameDayAs: now)
                                    Text(day.day, format: .number)
                                        .font(.system(size: 7, weight: today ? .bold : .medium).monospacedDigit())
                                        .foregroundStyle(.white.opacity(day.inMonth ? 1 : 0.3))
                                        .frame(width: 13, height: 13)
                                        .background(Circle().fill(today ? Tint.red.color : .clear))
                                }
                            }
                        }
                        RoundedRectangle(cornerRadius: 3).fill(Tint.blue.color.opacity(0.8)).frame(height: 8).padding(.top, 3)
                        RoundedRectangle(cornerRadius: 3).fill(Tint.green.color.opacity(0.7)).frame(height: 8)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.12).opacity(0.88)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.14)))
                    .padding(.trailing, 10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.1)))
        .accessibilityHidden(true)
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
