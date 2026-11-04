import AppKit
import MacToysCore
import SwiftUI

struct AppVolumeSettingsView: View {
    let module: AppVolumeModule
    @Bindable var s: Persisted<AppVolumeSettings>
    var store: AppVolumeStore
    @State private var renaming: String?
    @State private var renameText = ""

    init(module: AppVolumeModule) {
        self.module = module
        self.s = module.settings
        self.store = module.store
    }

    var body: some View {
        SettingsPage(module: module) {
            AppVolumeHero(module: module)
        } content: {
            if store.capture == .silent {
                Section {
                    InfoBar(.warning, title: Text("App Volume can't hear any apps"),
                            message: Text("Allow MacToys in System Settings › Privacy & Security › Screen & System Audio Recording. Until then, apps play as usual."),
                            actionTitle: Text("Open Privacy & Security")) { module.openPrivacySettings() }
                }
            }

            Section("Menu bar") {
                Toggle(isOn: $s.value.showMenuBarIcon) {
                    RowLabel("Show in the menu bar", subtitle: "Click the icon to open the App Volume flyout.")
                }
                Picker(selection: $s.value.menuBarIcon) {
                    ForEach(MenuBarIcon.allCases, id: \.self) { style in
                        Label(style.title, systemImage: Self.symbol(style)).tag(style)
                    }
                } label: {
                    RowLabel("Menu bar icon")
                }
                .disabled(!s.value.showMenuBarIcon)
                ShortcutRow("Show App Volume", subtitle: "Opens the flyout from anywhere.", shortcut: $s.value.flyoutShortcut)
                ShortcutRow("Mute the frontmost app", subtitle: "Press again to unmute it.", shortcut: $s.value.muteFrontmostShortcut)
            }

            Section("Flyout") {
                Toggle(isOn: $s.value.showMeters) {
                    RowLabel("Show level meters",
                             subtitle: "While the flyout is open, MacToys listens to each playing app to draw its meter. The sound itself isn't changed.")
                }
                Toggle(isOn: $s.value.showInputDevice) {
                    RowLabel("Show the input device", subtitle: "Microphone choice, level and mute under the output.")
                }
                Picker(selection: $s.value.lingerSeconds) {
                    ForEach(AppVolumeSettings.lingerChoices, id: \.self) { seconds in
                        Text(verbatim: Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))
                            .tag(seconds)
                    }
                } label: {
                    RowLabel("Keep apps listed after they stop playing", subtitle: "So you can still reach an app that paused.")
                }
            }

            Section("Volume") {
                Picker(selection: Binding(get: { s.value.maxVolume }, set: { max in
                    s.update { v in
                        v.maxVolume = max
                        v.newAppVolume = min(v.newAppVolume, max)
                        for (key, var app) in v.apps where app.volume > max { app.volume = max; v.apps[key] = app }
                    }
                })) {
                    ForEach(AppVolumeSettings.maxVolumeChoices, id: \.self) { value in
                        Text(verbatim: value.formatted(.percent.precision(.fractionLength(0)))).tag(value)
                    }
                } label: {
                    RowLabel("Highest volume", subtitle: "Above 100 %, a limiter keeps loud passages from distorting.")
                }
                .pickerStyle(.segmented)
                SliderRow("New apps start at", subtitle: "Apps you haven't changed play at this volume. 100 % leaves them untouched.",
                          value: $s.value.newAppVolume, in: 0...1, step: 0.05,
                          format: { $0.formatted(.percent.precision(.fractionLength(0))) })
                Toggle(isOn: $s.value.rememberApps) {
                    RowLabel("Remember each app's settings",
                             subtitle: "Volume, output and equalizer come back when the app plays again. When off, they're cleared when the app quits, except for apps kept in the list.")
                }
            }

            Section("Equalizer") {
                LabeledContent {
                    Stepper(value: Binding(get: { s.value.eqBandCount }, set: { n in s.update { $0.setBandCount(n) } }),
                            in: EQLayout.bandRange) {
                        Text(s.value.eqBandCount, format: .number).monospacedDigit()
                    }
                    .fixedSize()
                } label: {
                    RowLabel(title: Text("Bands"),
                             subtitle: Text(verbatim: EQLayout.frequencies(count: s.value.eqBandCount).map(EQCurve.label).joined(separator: " · ") + " Hz"))
                }
                if s.value.customPresets.isEmpty {
                    Text("Save a curve with Save as Preset… in an app's equalizer to use it for other apps.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(s.value.customPresets) { preset in presetRow(preset) }
                }
            }

            Section {
                let remembered = s.value.apps.sorted { $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending }
                if remembered.isEmpty {
                    Text("Apps you change appear here with their settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(remembered, id: \.key) { key, app in
                    RememberedAppRow(module: module, key: key, app: app)
                }
            } header: {
                HStack {
                    Text("Remembered apps")
                    Spacer()
                    if !s.value.apps.isEmpty {
                        Button("Forget All") {
                            s.update { v in
                                // Kept-in-list apps stay listed, with their settings reset.
                                v.apps = v.apps.filter { v.isPinned($0.key) }
                                    .mapValues { AppAudioSettings(name: $0.name, volume: v.newAppVolume) }
                            }
                        }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
            }

            Section("Excluded apps") {
                ExcludedAppsEditor("Apps App Volume leaves alone", apps: $s.value.excludedApps)
                Text("They aren't listed, metered or changed. Useful for music software that needs the lowest latency.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("System audio access") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To change an app's sound, MacToys records it through macOS's System Audio Recording permission and plays it back adjusted. macOS asks the first time you change an app. Apps you leave as they are are never touched, and while MacToys handles an app's sound macOS shows its recording indicator in the menu bar.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open Privacy & Security") { module.openPrivacySettings() }
                        if store.capture != .granted { Button("Check Again") { module.retryCapture() } }
                        Spacer()
                        captureStatus
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var captureStatus: some View {
        let (symbol, color, text): (String, Color, Text) = switch store.capture {
        case .granted: ("checkmark.circle.fill", .green, Text("Working", comment: "App Volume: system audio capture works"))
        case .silent: ("exclamationmark.triangle.fill", .orange, Text("No sound received", comment: "App Volume: capture seems blocked"))
        case .unknown: ("circle.dashed", .secondary, Text("Not used yet", comment: "App Volume: no app has been changed yet"))
        }
        return Label { text } icon: { Image(systemName: symbol).foregroundStyle(color) }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    static func symbol(_ style: MenuBarIcon) -> String {
        switch style {
        case .mixer: "slider.vertical.3"
        case .speaker: "speaker.wave.2"
        case .outputDevice: "headphones"
        }
    }

    @ViewBuilder
    private func presetRow(_ preset: CustomEQPreset) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.vertical.3").foregroundStyle(Tint.purple.color)
            if renaming == preset.id {
                TextField("Name", text: $renameText)
                    .onSubmit {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, let i = s.value.customPresets.firstIndex(where: { $0.id == preset.id }) {
                            s.value.customPresets[i].name = name
                        }
                        renaming = nil
                    }
                    .frame(maxWidth: 220)
            } else {
                Text(verbatim: preset.name)
            }
            Spacer()
            EQMiniCurve(gains: preset.gains, frequencies: preset.frequencies)
                .frame(width: 72, height: 22)
            Menu {
                Button("Rename") { renameText = preset.name; renaming = preset.id }
                Button("Delete", role: .destructive) {
                    s.update { v in
                        v.customPresets.removeAll { $0.id == preset.id }
                        for (key, var app) in v.apps where app.eq.preset == preset.id { app.eq.preset = nil; v.apps[key] = app }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }
}

/// One remembered app with a summary of its settings.
private struct RememberedAppRow: View {
    let module: AppVolumeModule
    let key: String
    let app: AppAudioSettings

    var body: some View {
        let identity = AppIdentity(key: key, name: app.name.isEmpty ? key : app.name,
                                   kind: key == AppIdentity.systemSoundsKey ? .systemSounds
                                       : key == AppIdentity.webContentKey ? .webContent : .app)
        HStack(spacing: 10) {
            AppIconView(identity: identity, size: 28)
            RowLabel(title: Text(verbatim: identity.name), subtitle: Text(verbatim: Self.summary(app, world: module.store.world)))
            Spacer(minLength: 8)
            let pinned = module.settings.value.isPinned(key)
            Button { module.togglePin(key) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .foregroundStyle(pinned ? AnyShapeStyle(Tint.purple.color) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(pinned ? Text("Unpin from the flyout") : Text("Keep in the flyout's list"))
            Button("Forget") {
                module.settings.update { s in
                    s.apps[key] = nil
                    s.pinnedApps.removeAll { $0 == key }
                }
            }
        }
    }

    static func summary(_ app: AppAudioSettings, world: AudioWorld) -> String {
        var parts: [String] = []
        parts.append(app.muted ? String(localized: "Muted", comment: "Remembered app summary")
                     : app.volume.formatted(.percent.precision(.fractionLength(0))))
        if let uid = app.outputUID {
            parts.append(world.device(uid: uid)?.name ?? app.outputName ?? uid)
        }
        if app.balance != 0 { parts.append(BalanceText.describe(app.balance)) }
        if app.eq.isEffective {
            let preset = EQPreset.named(app.eq.preset)?.name
            parts.append(preset.map { String(localized: "EQ \($0)", comment: "Remembered app summary; the placeholder is a preset name") }
                         ?? String(localized: "Custom EQ", comment: "Remembered app summary"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A tiny curve for preset rows.
private struct EQMiniCurve: View {
    let gains: [Double]
    let frequencies: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard gains.count >= 2 else { return }
            let lo = log10(20.0), hi = log10(20_000.0)
            var path = Path()
            for (i, f) in frequencies.enumerated() {
                let x = (log10(f) - lo) / (hi - lo) * size.width
                let y = size.height / 2 - gains[i] / 12 * (size.height / 2 - 2)
                if i == 0 { path.move(to: CGPoint(x: 0, y: y)) }
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2 - (gains.last ?? 0) / 12 * (size.height / 2 - 2)))
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height / 2)); $0.addLine(to: CGPoint(x: size.width, y: size.height / 2)) },
                       with: .color(.secondary.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            ctx.stroke(path, with: .color(Tint.purple.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Hero

/// A miniature desktop with the App Volume flyout open under its menu bar icon, drawn from the
/// apps playing now (or remembered apps), with each one's volume, mute and output.
struct AppVolumeHero: View {
    let module: AppVolumeModule

    var body: some View {
        let store = module.store
        let settings = module.settings.value
        HeroCard(tint: .purple) {
            HStack(alignment: .center, spacing: 20) {
                AppVolumeHeroIllustration(items: Self.items(module: module), maxVolume: settings.maxVolume,
                                          outputSymbol: DeviceSymbol.name(for: store.world.defaultOutput),
                                          outputVolume: Double(store.output.volume ?? 0.7),
                                          menuSymbol: menuSymbol(settings))
                    .frame(width: 236, height: 150)
                VStack(alignment: .leading, spacing: 6) {
                    Text("A volume slider for every app")
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Turn one app down, boost another, send music to the speakers and calls to your headphones. Apps you don't change play as they are.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        Button("Open App Volume") { module.toggleFlyout() }
                            .buttonStyle(.borderedProminent)
                        if let shortcut = settings.flyoutShortcut { Keycaps(shortcut) }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var status: Text {
        let store = module.store
        let playing = store.playingCount
        let adjusted = store.processing.count
        if !store.hasScanned { return Text("Turn App Volume on to see the apps playing sound.") }
        if playing == 0 { return Text("Nothing is playing right now") }
        return adjusted > 0
            ? Text("\(playing) playing · \(adjusted) adjusted", comment: "Hero status: apps playing sound, then apps whose sound MacToys changes")
            : Text("\(playing) playing", comment: "Hero status: number of apps playing sound")
    }

    private func menuSymbol(_ s: AppVolumeSettings) -> String {
        switch s.menuBarIcon {
        case .mixer: "slider.vertical.3"
        case .speaker: "speaker.wave.2"
        case .outputDevice: DeviceSymbol.name(for: module.store.world.defaultOutput)
        }
    }

    /// Up to three apps: the flyout's rows, else remembered apps, else placeholders.
    @MainActor
    static func items(module: AppVolumeModule) -> [AppVolumeHeroIllustration.Item] {
        let s = module.settings.value
        var identities = module.store.rows.prefix(3).map(\.identity)
        if identities.isEmpty {
            identities = s.apps.sorted { $0.key < $1.key }.prefix(3).map { AppIdentity(key: $0.key, name: $0.value.name) }
        }
        if identities.isEmpty {
            return [.init(identity: nil, symbol: "music.note", tint: .pink, volume: 0.8, muted: false),
                    .init(identity: nil, symbol: "globe", tint: .blue, volume: 0.45, muted: false),
                    .init(identity: nil, symbol: "video.fill", tint: .green, volume: 1.3, muted: false)]
        }
        return identities.map { id in
            let a = s.settings(for: id.key)
            return .init(identity: id, symbol: nil, tint: .graphite, volume: a.volume, muted: a.muted)
        }
    }
}

struct AppVolumeHeroIllustration: View {
    struct Item {
        var identity: AppIdentity?
        var symbol: String?
        var tint: Tint
        var volume: Double
        var muted: Bool
    }

    let items: [Item]
    let maxVolume: Double
    let outputSymbol: String
    let outputVolume: Double
    let menuSymbol: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                        Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                menuBar(width: w)
                flyout
                    .frame(width: 138)
                    .offset(x: w - 138 - 10, y: 17)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private func menuBar(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "apple.logo").font(.system(size: 6.5))
            ForEach(0..<3, id: \.self) { i in Capsule().fill(.white.opacity(0.55)).frame(width: i == 0 ? 14 : 10, height: 2.5) }
            Spacer()
            Image(systemName: "wifi").font(.system(size: 6))
            Image(systemName: menuSymbol)
                .font(.system(size: 6.5, weight: .semibold))
                .frame(width: 13, height: 9)
                .background(RoundedRectangle(cornerRadius: 2.5).fill(.white.opacity(0.28)))
            Capsule().fill(.white.opacity(0.55)).frame(width: 16, height: 2.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(width: width, height: 11)
        .background(.white.opacity(0.2))
    }

    private var flyout: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Capsule().fill(.white.opacity(0.85)).frame(width: 34, height: 3)
                Spacer()
                Circle().fill(.white.opacity(0.18)).frame(width: 6, height: 6)
            }
            .padding(.bottom, 1)
            HStack(spacing: 4) {
                Image(systemName: outputSymbol).font(.system(size: 6.5, weight: .semibold)).frame(width: 9)
                bar(outputVolume, maximum: 1, muted: false)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.07)))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    icon(item)
                    VStack(alignment: .leading, spacing: 3) {
                        Capsule().fill(.white.opacity(0.6)).frame(width: 26, height: 2.2)
                        HStack(spacing: 3) {
                            TintedSymbol(name: item.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 4.5, weight: .bold,
                                         color: item.muted ? .systemOrange : NSColor.white.withAlphaComponent(0.6))
                            bar(item.volume, maximum: maxVolume, muted: item.muted)
                        }
                    }
                }
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.07)))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func icon(_ item: Item) -> some View {
        if let identity = item.identity {
            AppIconView(identity: identity, size: 15)
        } else {
            ModuleIcon(symbol: item.symbol ?? "app.fill", tint: item.tint, size: 13).frame(width: 15, height: 15)
        }
    }

    private func bar(_ value: Double, maximum: Double, muted: Bool) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fill = max(5, w * min(value, maximum) / max(maximum, 0.01))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(value > 1 ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.92), Tint.purple.color],
                                                                   startPoint: .leading, endPoint: .trailing))
                          : AnyShapeStyle(Color.white.opacity(0.92)))
                    .frame(width: fill)
                    .opacity(muted ? 0.35 : 1)
            }
        }
        .frame(height: 5)
    }
}
