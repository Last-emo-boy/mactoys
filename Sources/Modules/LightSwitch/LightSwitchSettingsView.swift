import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

struct LightSwitchSettingsView: View {
    let module: LightSwitchModule
    @Bindable var s: Persisted<LightSwitchSettings>
    @Bindable var state: LightSwitchState
    @State private var latitudeText = ""
    @State private var longitudeText = ""

    init(module: LightSwitchModule) {
        self.module = module
        self.s = module.settings
        self.state = module.state
    }

    var body: some View {
        SettingsPage(module: module) {
            hero
        } content: {
            if state.automationDenied || [.denied, .notAsked].contains(SystemAppearance.automationStatus) {
                Section {
                    let denied = state.automationDenied || SystemAppearance.automationStatus == .denied
                    InfoBar(denied ? .error : .info,
                            title: denied ? Text("MacToys can't change the appearance") : Text("Automation access for System Events"),
                            message: Text("Light Switch changes the appearance through System Events. macOS asks once; if you declined, allow MacToys under Privacy & Security › Automation."),
                            actionTitle: denied ? Text("Open Settings") : Text("Allow…")) {
                        if denied { PermissionCenter.shared.openSettings(.automation) } else { module.requestAutomation() }
                    }
                }
            }

            Section("Shortcut") {
                ShortcutRow("Toggle light and dark", subtitle: "Switches right away; the schedule resumes at its next change.",
                            shortcut: $s.value.toggleShortcut)
                Toggle(isOn: $s.value.showHUD) { RowLabel("Show a notice when switching by hand") }
            }

            Section("Schedule") {
                Picker(selection: $s.value.scheduleMode) {
                    ForEach(ScheduleMode.allCases.filter { $0 != .followNightShift || NightShiftSchedule.isAvailable }, id: \.self) {
                        Text($0.title).tag($0)
                    }
                } label: {
                    RowLabel("Mode", subtitle: modeSubtitle)
                }
                switch s.value.scheduleMode {
                case .off:
                    EmptyView()
                case .fixedHours:
                    timeRow("Turn on light mode", time: $s.value.lightTime)
                    timeRow("Turn on dark mode", time: $s.value.darkTime)
                    if s.value.lightTime == s.value.darkTime {
                        InfoBar(.warning, title: "Light and dark start at the same time", message: "Pick two different times.")
                    }
                case .sunsetToSunrise:
                    locationRows
                    offsetRow("Sunrise offset", value: $s.value.sunriseOffset)
                    offsetRow("Sunset offset", value: $s.value.sunsetOffset)
                    sunTimesRow
                case .followNightShift:
                    nightShiftRows
                }
            }

            Section("Wallpaper") {
                Toggle(isOn: $s.value.changeWallpaper) {
                    RowLabel("Change the desktop picture with the appearance", subtitle: "Applied to every display.")
                }
                if s.value.changeWallpaper {
                    wallpaperRow("Light mode picture", path: $s.value.lightWallpaper)
                    wallpaperRow("Dark mode picture", path: $s.value.darkWallpaper)
                }
            }

            if let profiles = Services.displayProfiles?() {
                Section("Apply monitor settings") {
                    profilePicker("Light mode profile", profiles: profiles, selection: $s.value.lightDisplayProfile)
                    profilePicker("Dark mode profile", profiles: profiles, selection: $s.value.darkDisplayProfile)
                    Text("Power Display profiles are applied whenever Light Switch changes the appearance.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }

            Section {
                Text("macOS has one appearance for the system and apps, so Light Switch always changes both. Choosing a mode in System Settings › Appearance (including Auto) works alongside it; Light Switch turns Auto off when it switches.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            latitudeText = s.value.latitude.map { String($0) } ?? ""
            longitudeText = s.value.longitude.map { String($0) } ?? ""
            state.current = SystemAppearance.current
        }
        .onChange(of: s.value.latitude) { _, v in latitudeText = v.map { String($0) } ?? "" }
        .onChange(of: s.value.longitude) { _, v in longitudeText = v.map { String($0) } ?? "" }
    }

    private var modeSubtitle: LocalizedStringKey {
        switch s.value.scheduleMode {
        case .off: "Only the shortcut switches the appearance."
        case .fixedHours: "Light and dark at the same times every day."
        case .sunsetToSunrise: "Dark from sunset to sunrise where you are."
        case .followNightShift: "Dark while Night Shift's schedule is on (System Settings › Displays › Night Shift)."
        }
    }

    private var hero: some View {
        HeroCard(tint: .yellow) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 14) {
                    Image(systemName: state.current == .dark ? "moon.stars.fill" : "sun.max.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(state.current == .dark ? Tint.indigo.color : Tint.orange.color)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        (state.current == .dark ? Text("Dark mode is on") : Text("Light mode is on"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(nextText(now: context.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { module.toggle() } label: {
                        state.current == .dark ? Text("Switch to Light", comment: "Button: switch to light mode")
                            : Text("Switch to Dark", comment: "Button: switch to dark mode")
                    }
                    Keycaps(s.value.toggleShortcut)
                }
            }
        }
    }

    private func nextText(now: Date) -> String {
        var text = LightSwitchSchedule.describeNext(plan: module.currentPlan(now: now), mode: s.value.scheduleMode, now: now)
        if let until = s.value.manualOverrideUntil, until > now {
            text = String(localized: "\(text) · manual override until then",
                          comment: "Light Switch status; the placeholder is the next change, e.g. 'Dark at 20:00'")
        }
        if let error = state.lastError { text = error }
        return text
    }

    private func timeRow(_ title: LocalizedStringKey, time: Binding<TimeOfDay>) -> some View {
        DatePicker(selection: Binding(get: { time.wrappedValue.on(Date(), calendar: .current) },
                                      set: { time.wrappedValue = TimeOfDay(of: $0, calendar: .current) }),
                   displayedComponents: .hourAndMinute) {
            RowLabel(title)
        }
    }

    private func offsetRow(_ title: LocalizedStringKey, value: Binding<Int>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                (value.wrappedValue == 0 ? Text("None", comment: "Sunrise or sunset offset of zero minutes")
                    : Text(Measurement(value: Double(value.wrappedValue), unit: UnitDuration.minutes)
                        .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.sign(strategy: .always())))))
                    .monospacedDigit().frame(minWidth: 64, alignment: .trailing)
                Stepper(title, value: value, in: -180...180, step: 5).labelsHidden()
            }
        } label: {
            RowLabel(title, subtitle: "Negative values switch earlier.")
        }
    }

    @ViewBuilder private var locationRows: some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField("Latitude", text: $latitudeText).frame(width: 90)
                    .onSubmit(commitCoordinates)
                TextField("Longitude", text: $longitudeText).frame(width: 90)
                    .onSubmit(commitCoordinates)
                Button { module.locate() } label: { state.locating ? Text("Locating…") : Text("Use My Location") }
                    .disabled(state.locating)
            }
        } label: {
            RowLabel(title: Text("Location"), subtitle: s.value.hasLocation
                     ? Text("Coordinates in degrees; south and west are negative.")
                     : Text("Needed for sunrise and sunset. Enter coordinates or use Location Services."))
        }
        if let error = state.locationError {
            InfoBar(.warning, title: Text("Location unavailable"), message: Text(verbatim: error))
        }
        if latitudeInvalid || longitudeInvalid {
            InfoBar(.warning, title: "Invalid coordinates", message: "Latitude is −90…90 and longitude −180…180.")
        }
    }

    private var latitudeInvalid: Bool {
        !latitudeText.isEmpty && (Double(latitudeText).map { abs($0) > 90 } ?? true)
    }

    private var longitudeInvalid: Bool {
        !longitudeText.isEmpty && (Double(longitudeText).map { abs($0) > 180 } ?? true)
    }

    private func commitCoordinates() {
        guard !latitudeInvalid, !longitudeInvalid else { return }
        let lat = Double(latitudeText), lon = Double(longitudeText)
        s.update {
            $0.latitude = lat
            $0.longitude = lon
        }
    }

    @ViewBuilder private var sunTimesRow: some View {
        if let lat = s.value.latitude, let lon = s.value.longitude {
            let t = SolarCalculator.sunTimes(on: Date(), latitude: lat, longitude: lon)
            LabeledContent {
                if t.isPolarDay { Text("Sun up all day") }
                else if t.isPolarNight { Text("Sun down all day") }
                else if let rise = t.sunrise, let set = t.sunset {
                    Text(verbatim: "☀︎ \(rise.formatted(date: .omitted, time: .shortened))   ☾ \(set.formatted(date: .omitted, time: .shortened))")
                        .monospacedDigit()
                }
            } label: {
                RowLabel("Today", subtitle: "Sunrise and sunset before offsets.")
            }
        }
    }

    @ViewBuilder private var nightShiftRows: some View {
        let schedule = module.nightShift
        LabeledContent {
            switch schedule {
            case .custom(let from, let to)?:
                let start = from.on(Date(), calendar: .current).formatted(date: .omitted, time: .shortened)
                let end = to.on(Date(), calendar: .current).formatted(date: .omitted, time: .shortened)
                Text(verbatim: "\(start) – \(end)").monospacedDigit()
            case .sunsetToSunrise?: Text("Sunset to sunrise")
            case .off?: Text("Off", comment: "Night Shift schedule: off").foregroundStyle(.secondary)
            case nil: Text("Unavailable", comment: "Night Shift schedule can't be read").foregroundStyle(.secondary)
            }
        } label: {
            RowLabel("Night Shift schedule", subtitle: "Change it in System Settings › Displays › Night Shift.")
        }
        if schedule == .sunsetToSunrise { locationRows }
        Button("Open Night Shift Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func wallpaperRow(_ title: LocalizedStringKey, path: Binding<String?>) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let p = path.wrappedValue, let image = NSImage(contentsOfFile: (p as NSString).expandingTildeInPath) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 34).clipShape(RoundedRectangle(cornerRadius: 5))
                }
                (path.wrappedValue.map { Text(verbatim: ($0 as NSString).lastPathComponent) }
                    ?? Text("None", comment: "No desktop picture chosen"))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .trailing)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.image]
                    panel.directoryURL = URL(fileURLWithPath: "/System/Library/Desktop Pictures")
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
                if path.wrappedValue != nil {
                    Button { path.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
                }
            }
        } label: {
            RowLabel(title)
        }
    }

    private func profilePicker(_ title: LocalizedStringKey, profiles: [Services.DisplayProfile], selection: Binding<Int?>) -> some View {
        Picker(selection: selection) {
            Text("Don't change").tag(Int?.none)
            ForEach(profiles) { p in Text(verbatim: p.name).tag(Int?.some(p.id)) }
        } label: {
            RowLabel(title)
        }
    }
}
