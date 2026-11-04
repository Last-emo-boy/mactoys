import MacToysCore
import SwiftUI

struct MenuBarSettingsView: View {
    let module: MenuBarManagerModule
    @Bindable var s: Persisted<MenuBarSettings>
    let state: MenuBarState
    @State private var permissions = PermissionCenter.shared

    init(module: MenuBarManagerModule) {
        self.module = module
        self.s = module.settings
        self.state = module.controller.state
    }

    private var trusted: Bool { permissions.isGranted(.accessibility) }

    var body: some View {
        SettingsPage(module: module) {
            MenuBarHero(module: module, settings: s.value, state: state)
        } content: {
            sectionsSection
            showingSection
            rehideSection
            notchSection
            searchSection
            appearanceSection
            itemsSection
        }
        .onAppear {
            guard state.isRunning else { return }
            module.controller.refreshItems()
            module.controller.describeForSettings()
            module.controller.evaluateNotch(warn: false)
        }
    }

    // MARK: Sections

    private var sectionsSection: some View {
        Section("Hidden items") {
            Toggle(isOn: $s.value.alwaysHiddenSection) {
                RowLabel("Always-hidden section",
                         subtitle: "A second divider, ‖. Icons to its left only appear when you ⌥-click the chevron, open the separate bar with ⌥ or search for them.")
            }
            Picker(selection: Binding(get: { s.value.barMode }, set: { mode in
                s.value.barMode = mode
                if mode.usesBar { module.requestAccessibilityIfNeeded() }
            })) {
                ForEach(HiddenBarMode.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Show hidden items",
                         subtitle: "The separate bar sits under the menu bar, so icons never end up behind the notch. Opening an item from it needs Accessibility.")
            }
            if s.value.barMode.usesBar && !trusted {
                InfoBar(.info, title: "Allow Accessibility to open items from the bar",
                        message: "Without it, clicking an item in the bar shows it in the menu bar for you to click.",
                        actionTitle: "Grant Access") { permissions.request(.accessibility) }
            }
            if let problem = state.orderProblems.first {
                InfoBar(.warning, title: problem == .chevronLeftOfDivider ? "The chevron is left of the divider" : "The ‖ divider is right of the | divider",
                        message: "Hiding is paused so nothing gets lost. Click Arrange Items and drag the dividers back with ⌘, or reset them.",
                        actionTitle: "Arrange Items…") { module.controller.beginArranging() }
            }
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Reset Dividers") { module.controller.resetPositions() }
                        .disabled(!state.isRunning)
                    Button("Arrange Items…") { module.controller.beginArranging() }
                        .disabled(!state.isRunning)
                }
            } label: {
                RowLabel("Arrange", subtitle: "Shows every section and guides you through moving icons. Reset puts the dividers back at the far left, so nothing is hidden.")
            }
        }
    }

    private var showingSection: some View {
        Section("Show hidden items when") {
            Toggle(isOn: $s.value.showOnHover) {
                RowLabel("The pointer rests in empty menu bar space")
            }
            if s.value.showOnHover {
                SliderRow("Delay", value: $s.value.hoverDelay, in: 0.1...1.5, step: 0.1) {
                    Duration.milliseconds(Int(($0 * 1000).rounded())).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated,
                                                                                       fractionalPart: .show(length: 1)))
                }
            }
            Toggle(isOn: $s.value.showOnEmptyClick) {
                RowLabel("You click empty menu bar space", subtitle: "Click again to hide them.")
            }
            Toggle(isOn: $s.value.showOnUpdate) {
                RowLabel("One of them changes", subtitle: "Shows them for a few seconds when a hidden icon changes size — timers, counters, badges — or a new app adds an icon.")
            }
            if s.value.showOnHover || s.value.showOnEmptyClick {
                Text(trusted
                     ? "Empty space is the part of the menu bar between the app's menus and your icons."
                     : "Without Accessibility, MacToys can't see where the app's menus end, so only the free space next to your icons counts (right of the notch on displays that have one).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ShortcutRow("Show or hide hidden items", shortcut: $s.value.toggleShortcut)
            if s.value.alwaysHiddenSection {
                ShortcutRow("Show always-hidden items too", shortcut: $s.value.alwaysHiddenShortcut)
            }
        }
    }

    private var rehideSection: some View {
        Section("Hide them again") {
            Toggle(isOn: $s.value.rehideAfterDelay) {
                RowLabel("After a delay", subtitle: "The countdown waits while the pointer is on the menu bar or a menu from it is open.")
            }
            if s.value.rehideAfterDelay {
                SliderRow("Delay", value: $s.value.rehideDelay, in: 2...60, step: 1) {
                    Duration.seconds(Int($0.rounded())).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
                }
            }
            Toggle(isOn: $s.value.rehideWhenPointerLeaves) {
                RowLabel("When the pointer leaves the menu bar", subtitle: "Items shown by hovering always hide this way.")
            }
        }
    }

    private var notchSection: some View {
        Section("Notch") {
            if !MenuBarGeometry.anyNotch {
                Text("No display with a camera notch is connected. These settings apply when one is.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !state.isRunning {
                Text("Shows how much room is left beside the notch while Menu Bar Manager is on.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let notch = state.notch {
                if notch.lost.isEmpty {
                    LabeledContent {
                        Text("About \(notch.spare) more icons fit", comment: "Notch status: how many more menu bar icons fit beside the notch")
                            .monospacedDigit().foregroundStyle(.secondary)
                    } label: {
                        RowLabel("Room beside the notch")
                    }
                } else {
                    InfoBar(.warning, title: Text("\(notch.lost.count) icons don't fit beside the notch", comment: "Notch warning title; the number counts menu bar icons"),
                            message: Text(verbatim: notch.lost.formatted(.list(type: .and))),
                            actionTitle: Text("Arrange Items…")) { module.controller.beginArranging() }
                    Text("macOS draws icons that don't fit behind the camera. Hide some of them, or show hidden items in the separate bar.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $s.value.notchWarning) {
                RowLabel("Warn when icons disappear behind the notch", subtitle: "Also tells you once when shown hidden items don't all fit.")
            }
        }
    }

    private var searchSection: some View {
        Section("Search") {
            Toggle(isOn: Binding(get: { s.value.searchEnabled }, set: { on in
                s.value.searchEnabled = on
                if on { module.requestAccessibilityIfNeeded() }
            })) {
                RowLabel("Search menu bar items",
                         subtitle: "Find any icon by its name or its app and open it from the keyboard, hidden or not. Reads item names through Accessibility.")
            }
            if s.value.searchEnabled {
                ShortcutRow("Search shortcut", shortcut: $s.value.searchShortcut)
                if !trusted {
                    InfoBar(.info, title: "Allow Accessibility to search by item name",
                            message: "Without it, search lists apps, and opening one shows it in the menu bar for you to click.",
                            actionTitle: "Grant Access") { permissions.request(.accessibility) }
                }
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $s.value.chevronStyle) {
                ForEach(ChevronStyle.allCases, id: \.self) { style in
                    Label(style.title, systemImage: style.symbol(collapsed: true)).tag(style)
                }
            } label: {
                RowLabel("Show and hide button", subtitle: "Points left while icons are hidden. Right-click it for more.")
            }
            Picker(selection: $s.value.dividerStyle) {
                ForEach(DividerStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                RowLabel("Dividers", subtitle: "Drawn while hidden items show. Invisible dividers still appear while you arrange.")
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $s.value.appearance.enabled) {
                RowLabel("Tint the menu bar",
                         subtitle: "Drawn behind the menu bar on every display, never on full-screen apps. Shows best where macOS draws the menu bar without a background of its own.")
            }
            if s.value.appearance.enabled {
                Picker(selection: $s.value.appearance.shape) {
                    ForEach(BackdropShape.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: {
                    RowLabel("Shape")
                }
                ColorRow("Color", color: $s.value.appearance.tint)
                Toggle(isOn: $s.value.appearance.gradient) { RowLabel("Gradient") }
                if s.value.appearance.gradient {
                    ColorRow("Second color", color: $s.value.appearance.secondTint)
                }
                Toggle(isOn: $s.value.appearance.border) { RowLabel("Border") }
                if s.value.appearance.border {
                    ColorRow("Border color", color: $s.value.appearance.borderColor)
                    SliderRow("Border width", value: $s.value.appearance.borderWidth, in: 0.5...3, step: 0.5) {
                        "\($0.formatted(.number.precision(.fractionLength(1)))) pt"
                    }
                }
                Toggle(isOn: $s.value.appearance.shadow) { RowLabel("Shadow") }
                Text("With Reduce Transparency the colors are drawn solid; with Increase Contrast the edge is stronger.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var itemsSection: some View {
        Section("In your menu bar") {
            if !state.isRunning {
                Text("Turn on Menu Bar Manager to see your icons here, sorted by section.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(sections, id: \.self) { section in
                    let entries = state.items.filter { $0.section == section }.map(BarEntry.init)
                    LabeledContent {
                        if entries.isEmpty {
                            Text("None", comment: "No menu bar icons in this section").foregroundStyle(.tertiary)
                        } else {
                            IconStrip(entries: entries)
                        }
                    } label: {
                        RowLabel(title: Text(section.title), subtitle: Text("\(entries.count) icons", comment: "Number of menu bar icons in a section"))
                    }
                }
            }
        }
    }

    private var sections: [MenuBarSection] {
        s.value.alwaysHiddenSection ? [.visible, .hidden, .alwaysHidden] : [.visible, .hidden]
    }
}

/// A row of item icons, each named in its help tag; long rows end in "+N".
private struct IconStrip: View {
    let entries: [BarEntry]
    static let limit = 12

    var body: some View {
        HStack(spacing: 6) {
            ForEach(entries.prefix(Self.limit)) { e in
                EntryIcon(icon: e.icon, size: 18)
                    .foregroundStyle(.primary)
                    .help(Text(verbatim: e.title == e.appName ? e.title : "\(e.title) — \(e.appName)"))
            }
            if entries.count > Self.limit {
                Text(verbatim: "+\((entries.count - Self.limit).formatted())").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hero

/// The page's hero: the menu bar with its icons hidden and shown, drawn from the current settings
/// (button and divider styles, the always-hidden section, the tint), with the live counts.
private struct MenuBarHero: View {
    let module: MenuBarManagerModule
    let settings: MenuBarSettings
    let state: MenuBarState

    var body: some View {
        HeroCard(tint: .cyan) {
            HStack(alignment: .center, spacing: 20) {
                MenuBarHeroIllustration(settings: settings, hiddenCount: state.isRunning ? state.count(.hidden) : nil)
                    .frame(width: 318, height: 132)
                VStack(alignment: .leading, spacing: 6) {
                    title.font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("Hold ⌘ and drag icons to the left of the divider. Click the chevron, hover or press your shortcut to bring them back.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button {
                            module.controller.toggle()
                        } label: {
                            state.revealed ? Text("Hide Icons") : Text("Show Icons", comment: "Hero button: show the hidden menu bar icons")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.isRunning)
                        Button("Arrange…") { module.controller.beginArranging() }
                            .disabled(!state.isRunning)
                        if let shortcut = settings.toggleShortcut { Keycaps(shortcut) }
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var title: Text {
        guard state.isRunning else { return Text("Hide the menu bar icons you rarely use") }
        let hidden = state.count(.hidden), always = state.count(.alwaysHidden)
        if hidden + always == 0 { return Text("Nothing is hidden yet") }
        if always > 0 && settings.alwaysHiddenSection {
            return Text("\(hidden) icons hidden · \(always) always hidden", comment: "Hero title; numbers of hidden and always-hidden menu bar icons")
        }
        return Text("\(hidden) icons hidden", comment: "Hero title; number of hidden menu bar icons")
    }
}

/// Two strips of menu bar on a wallpaper: icons hidden (top) and shown (bottom).
struct MenuBarHeroIllustration: View {
    let settings: MenuBarSettings
    /// Live number of hidden icons; nil draws the sample.
    var hiddenCount: Int?

    var body: some View {
        let hiddenIcons = Array(MockSamples.hidden.prefix(min(2, max(1, hiddenCount ?? 5))))
        let extra = (hiddenCount ?? 5) - hiddenIcons.count
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                HeroWallpaper()
                VStack(alignment: .leading, spacing: 10) {
                    caption(Text("Hidden", comment: "Hero illustration caption: the menu bar with icons hidden"))
                    strip([.chevron(open: false)] + shownIcons, width: w - 24)
                    caption(Text("Shown", comment: "Hero illustration caption: the menu bar with hidden icons shown"))
                    strip(expandedElements(hiddenIcons, extra: extra), width: w - 24)
                }
                .padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    private func expandedElements(_ hidden: [String], extra: Int) -> [MockMenuBar.Element] {
        var e: [MockMenuBar.Element] = []
        if settings.alwaysHiddenSection {
            e.append(.faded(MockSamples.alwaysHidden[0]))
            e.append(.divider(double: true))
        }
        if extra > 0 { e.append(.text("+\(extra.formatted())")) }
        e += hidden.map(MockMenuBar.Element.icon)
        e.append(.divider(double: false))
        e.append(.chevron(open: true))
        e += shownIcons
        return e
    }

    /// The icons that stay in the menu bar, the same in both strips.
    private var shownIcons: [MockMenuBar.Element] { MockSamples.shown.suffix(4).map(MockMenuBar.Element.icon) }

    private func caption(_ text: Text) -> some View {
        text.font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase).kerning(0.6).foregroundStyle(.white.opacity(0.6))
    }

    private func strip(_ elements: [MockMenuBar.Element], width: CGFloat) -> some View {
        var appearance = settings.appearance
        if !appearance.enabled {
            // Without a tint the strip still reads as a bar.
            appearance = MenuBarAppearance(enabled: true, shape: .rounded, tint: RGBA(red: 1, green: 1, blue: 1, alpha: 0.1),
                                           gradient: false, border: false, shadow: false)
        }
        return MockMenuBar(width: width, height: 26, showsAppMenus: false, elements: Array(elements.suffix(14)), clock: MockSamples.time,
                           appearance: appearance, chevronStyle: settings.chevronStyle,
                           dividerStyle: settings.dividerStyle == .none ? .line : settings.dividerStyle, scale: 0.82)
    }
}

private struct HeroWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.36), Color(red: 0.24, green: 0.17, blue: 0.56),
                                Color(red: 0.6, green: 0.25, blue: 0.53), Color(red: 0.88, green: 0.54, blue: 0.42)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
