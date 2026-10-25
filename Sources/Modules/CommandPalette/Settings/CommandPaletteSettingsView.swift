import AppKit
import MacToysCore
import SwiftUI

/// Command Palette's settings page, grouped like PowerToys' (General, Layout, Extensions, Command links).
struct CommandPaletteSettingsView: View {
    let module: CommandPaletteModule
    @Bindable var settings: Persisted<CommandPaletteSettings>
    @Bindable var options: Persisted<ProviderOptions>

    init(module: CommandPaletteModule) {
        self.module = module
        settings = module.settings
        options = module.engine.options
    }

    private var engine: LauncherEngine { module.engine }

    var body: some View {
        SettingsPage(module: module, hero: { hero }) {
            activation
            behavior
            layout
            pinned
            aliases
            hotkeys
            extensions
            links
        }
    }

    private var hero: some View {
        HeroCard(tint: .blue) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type to find anything").font(.headline)
                    Text("Apps, files, windows, calculations, clipboard history, System Settings, bookmarks, your own scripts. Press ⌘K on a result for more actions, ⌥1…⌥9 for pinned commands.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Open Command Palette") { module.open() }.buttonStyle(.borderedProminent)
                        Keycaps(settings.value.activation)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Sections

    private var activation: some View {
        Section("Activation") {
            ShortcutRow("Activation shortcut", subtitle: "Shows or hides Command Palette", shortcut: $settings.value.activation)
            Toggle(isOn: $settings.value.ignoreInFullScreen) {
                RowLabel("Ignore the shortcut while an app is full screen")
            }
        }
    }

    private var behavior: some View {
        Section("Behavior") {
            Picker(selection: $settings.value.returnHomeAfter) {
                Text("Immediately").tag(0)
                ForEach([10, 20, 30, 60, 90, 120, 180], id: \.self) { Text("After \($0) seconds").tag($0) }
                Text("Never").tag(-1)
            } label: { RowLabel("Return to Home after closing", subtitle: "Reopening within this time continues where you left off") }
            Toggle(isOn: $settings.value.keepQuery) { RowLabel("Keep search text when reopened") }
            Toggle(isOn: $settings.value.selectQueryOnOpen) { RowLabel("Select search text when opened", subtitle: "Typing replaces it") }
            Toggle(isOn: $settings.value.rememberFilter) { RowLabel("Remember the result filter") }
            Picker(selection: $settings.value.screen) {
                ForEach(LauncherScreen.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel("Open Command Palette on") }
            Picker(selection: $settings.value.escapeBehavior) {
                ForEach(CommandPaletteSettings.EscapeBehavior.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel("Esc key") }
            Toggle(isOn: $settings.value.backspaceGoesBack) { RowLabel("Go back with ⌫ when the search is empty") }
            Toggle(isOn: $settings.value.singleClickActivates) {
                RowLabel("Run results with a single click", subtitle: "Off: click selects, double-click runs")
            }
            Picker(selection: $settings.value.numberKeys) {
                ForEach(CommandPaletteSettings.NumberKeys.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel(title: Text(verbatim: "⌥1…⌥9"), subtitle: Text("⌥⇧1…⌥⇧9 always selects")) }
            Toggle(isOn: $settings.value.hideOnResign) { RowLabel("Close when clicking outside") }
        }
    }

    private var layout: some View {
        Section("Layout") {
            Picker(selection: $settings.value.openMode) {
                ForEach(CommandPaletteSettings.OpenMode.allCases) { Text($0.title).tag($0) }
            } label: {
                RowLabel("How Command Palette opens", subtitle: "The compact search box expands when you type, press ↓ or ⇥")
            }
            Toggle(isOn: $settings.value.showShelf) {
                RowLabel("Quick access shelf", subtitle: "Pinned commands under the search box; ⌥1…⌥9 run them")
            }
            Stepper(value: $settings.value.maxPins, in: 0...20) {
                RowLabel(title: Text("Maximum pinned items on the shelf"), subtitle: Text(settings.value.maxPins, format: .number))
            }
            Picker(selection: $settings.value.shelfRecents) {
                ForEach(CommandPaletteSettings.RecentPlacement.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel("Recent items on the shelf") }
            Picker(selection: $settings.value.homeRecents) {
                ForEach(CommandPaletteSettings.RecentPlacement.allCases) { Text($0.title).tag($0) }
            } label: { RowLabel("Recent items on Home") }
            Stepper(value: $settings.value.maxRecents, in: 1...10) {
                RowLabel(title: Text("Maximum recent items"), subtitle: Text(settings.value.maxRecents, format: .number))
            }
            LabeledContent { Button("Clear History") { engine.usage.clearHistory() } } label: {
                RowLabel("Recent items and ranking", subtitle: "What you ran rises in the results")
            }
            Toggle(isOn: $settings.value.showDetails) { RowLabel("Show the details pane") }
            Stepper(value: $settings.value.resultsPerSection, in: 1...10) {
                RowLabel("Results per provider", subtitle: "\(settings.value.resultsPerSection) in the main search; pages and filters show all")
            }
            SliderRow("Background opacity", value: $settings.value.backgroundOpacity, in: 0.2...0.95,
                      format: { $0.formatted(.percent.precision(.fractionLength(0))) })
        }
    }

    private var pinned: some View {
        Section {
            if settings.value.pins.isEmpty {
                Text("Nothing pinned. Press ⌘K on a result and choose Pin to Quick Access.").foregroundStyle(.secondary)
            }
            ForEach(Array(settings.value.pins.enumerated()), id: \.element.id) { i, pin in
                HStack(spacing: 10) {
                    ItemIconView(icon: pin.icon, size: 22)
                    TextField(String(localized: "Title", comment: "Placeholder: the pin's title on the shelf"), text: Binding(get: { pin.title }, set: { v in
                        if i < settings.value.pins.count { settings.value.pins[i].title = v }
                    }))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    Spacer()
                    if i < 9 { Keycaps(["⌥", String(i + 1)]) }
                    Button { settings.value.pins.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0)
                    Button { settings.value.pins.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == settings.value.pins.count - 1)
                    Button { settings.value.pins.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            CommandMenu(title: "Pin a Command", engine: engine) { item in
                guard !settings.value.pins.contains(where: { $0.id == item.id }) else { return }
                settings.value.pins.append(PinnedCommand(id: item.id, title: item.title, icon: item.icon))
            }
        } header: {
            Text("Pinned commands")
        } footer: {
            Text("Pins appear on the quick access shelf (or on Home when the shelf is off). ⌥⇧1…⌥⇧9 selects a pin so ⌘K shows its actions.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var aliases: some View {
        Section {
            ForEach(Array(settings.value.aliases.enumerated()), id: \.offset) { i, alias in
                HStack(spacing: 10) {
                    TextField(String(localized: "alias", comment: "Placeholder: the alias to type, e.g. cb"), text: Binding(get: { alias.alias }, set: { v in
                        guard i < settings.value.aliases.count else { return }
                        let trimmed = v.replacingOccurrences(of: " ", with: "")
                        settings.value.aliases[i].alias = trimmed
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .labelsHidden()
                    .frame(width: 80)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    Text(verbatim: alias.title).lineLimit(1)
                    Spacer()
                    Toggle("Direct", isOn: Binding(get: { alias.direct }, set: { v in
                        if i < settings.value.aliases.count { settings.value.aliases[i].direct = v }
                    }))
                    .toggleStyle(.checkbox)
                    .help("A direct alias works as soon as it’s typed; otherwise type it followed by a space")
                    Button { settings.value.aliases.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            let duplicates = Dictionary(grouping: settings.value.aliases.map { $0.alias.lowercased() }.filter { !$0.isEmpty }, by: { $0 })
                .filter { $0.value.count > 1 }.keys.sorted()
            if !duplicates.isEmpty {
                InfoBar(.warning, title: Text("Duplicate aliases"), message: Text(verbatim: duplicates.joined(separator: ", ")))
            }
            HStack {
                CommandMenu(title: "Add Alias", engine: engine) { item in
                    settings.value.aliases.append(CommandAlias(alias: "", target: item.id, title: item.title, direct: false))
                }
                Button("Restore Defaults") { settings.value.aliases = CommandPaletteSettings.defaultAliases }
            }
        } header: {
            Text("Aliases")
        } footer: {
            Text("Typing an alias opens its page right away: “\("cb ")” shows clipboard history, “\("=")” the calculator. Symbol aliases are direct, so “\("=2+2")” works.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var hotkeys: some View {
        Section {
            if settings.value.hotkeys.isEmpty {
                Text("No command hotkeys. Press ⌘K on a result and choose Assign Hotkey, or add one here.").foregroundStyle(.secondary)
            }
            ForEach(Array(settings.value.hotkeys.enumerated()), id: \.element.id) { i, hk in
                LabeledContent {
                    HStack {
                        ShortcutRecorder(shortcut: Binding(get: { hk.shortcut }, set: { v in
                            if i < settings.value.hotkeys.count { settings.value.hotkeys[i].shortcut = v }
                        }))
                        Button { settings.value.hotkeys.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                } label: {
                    HStack(spacing: 10) {
                        ItemIconView(icon: hk.icon, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: hk.title)
                            if let s = hk.shortcut, !HotkeyCenter.shared.conflicts(for: s, excluding: "cmdpal.command.\(i)").isEmpty {
                                Text("Also used by another shortcut").font(.system(size: 11.5)).foregroundStyle(.orange)
                            } else if hk.shortcut != nil, HotkeyCenter.shared.failed.contains("cmdpal.command.\(i)") {
                                Text("Taken by another app").font(.system(size: 11.5)).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            CommandMenu(title: "Add Command Hotkey", engine: engine) { item in
                guard !settings.value.hotkeys.contains(where: { $0.target == item.id }) else { return }
                settings.value.hotkeys.append(CommandHotkey(target: item.id, title: item.title, icon: item.icon, shortcut: nil))
            }
        } header: {
            Text("Command hotkeys")
        } footer: {
            Text("A global shortcut that runs a command without opening the palette, or opens straight into its page.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var extensions: some View {
        Section {
            ForEach(engine.providers, id: \.id) { p in
                ProviderRow(provider: p, settings: settings, options: options)
            }
        } header: {
            Text("Extensions")
        } footer: {
            Text("Turn off “Main search” to reach an extension only through its alias, the result filter or its page.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var links: some View {
        Section {
            Toggle(isOn: $settings.value.enableCommandLinks) {
                RowLabel("Enable command links",
                         subtitle: "\("mactoys://cmdpal/run?id=…") links run commands after you confirm. ⌘K › Copy Command Link creates one.")
            }
            ForEach(settings.value.allowedLinks, id: \.self) { id in
                LabeledContent {
                    Button("Revoke") { settings.value.allowedLinks.removeAll { $0 == id } }
                } label: {
                    RowLabel(engine.resolve(id)?.title ?? id, subtitle: id)
                }
            }
            if !settings.value.allowedLinks.isEmpty {
                Button("Remove All") { settings.value.allowedLinks.removeAll() }
            }
        } header: {
            Text("Command links")
        }
    }
}

/// One provider in the Extensions list: on/off, main-search inclusion, its options.
private struct ProviderRow: View {
    let provider: any SearchProvider
    @Bindable var settings: Persisted<CommandPaletteSettings>
    @Bindable var options: Persisted<ProviderOptions>
    @State private var expanded = false

    var body: some View {
        let t = settings.value.toggle(for: provider)
        let aliases = settings.value.aliases.filter { $0.target.hasPrefix(provider.id + ":") }.map(\.alias).filter { !$0.isEmpty }
        DisclosureGroup(isExpanded: $expanded) {
            Toggle(isOn: Binding(get: { t.global }, set: { v in update { $0.global = v } })) {
                RowLabel("Main search", subtitle: "Show results without an alias or filter")
            }
            .disabled(!t.enabled)
            if providersWithOptions.contains(provider.id) {
                ProviderOptionsView(providerID: provider.id, options: options).disabled(!t.enabled)
            }
        } label: {
            HStack {
                ProviderHeader(provider: provider, detail: aliases.isEmpty ? nil : "\(provider.summary) · \(aliases.joined(separator: " "))")
                Spacer()
                Toggle(isOn: Binding(get: { t.enabled }, set: { v in update { $0.enabled = v } })) { Text(verbatim: provider.name) }
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private func update(_ change: (inout ProviderToggle) -> Void) {
        var t = settings.value.toggle(for: provider)
        change(&t)
        settings.value.providers[provider.id] = t
    }
}

/// A menu listing commands to pick for pins, aliases and hotkeys.
struct CommandMenu: View {
    let title: LocalizedStringKey
    let engine: LauncherEngine
    let onPick: (PaletteItem) -> Void

    var body: some View {
        Menu(title) {
            let commands = engine.commands { _ in true }.filter(\.isPinnable)
            Section("Commands") {
                ForEach(commands.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, id: \.id) { c in
                    Button(c.title) { onPick(c) }
                }
            }
            let quick = (engine.provider("mactoys") as? MacToysProvider)?.allItems() ?? []
            Section {
                ForEach(quick, id: \.id) { c in Button(c.title) { onPick(c) } }
            } header: {
                Text(verbatim: "MacToys")
            }
            let system = (engine.provider("system") as? SystemCommandsProvider)?.allCommands ?? []
            Section("System") {
                ForEach(system, id: \.id) { c in Button(c.title) { onPick(c) } }
            }
        }
        .fixedSize()
    }
}
