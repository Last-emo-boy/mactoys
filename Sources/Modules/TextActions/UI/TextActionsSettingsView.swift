import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

struct TextActionsSettingsView: View {
    let module: TextActionsModule
    @Bindable var settings: Persisted<TextActionsSettings>
    @State private var editing: EditorRequest?
    @State private var importMessage: ImportMessage?

    struct EditorRequest: Identifiable {
        var action: CustomAction
        var isNew: Bool
        var id: UUID { action.id }
    }

    struct ImportMessage: Equatable {
        var kind: InfoKind
        var text: String

        static func == (a: ImportMessage, b: ImportMessage) -> Bool { a.text == b.text }
    }

    var body: some View {
        SettingsPage(module: module) {
            TextActionsHero(settings: settings.value)
        } content: {
            showingSection
            barSection
            actionsSection
            customSection
            optionsSection
            readingSection
            Section("Excluded apps") {
                ExcludedAppsEditor("Don’t show the bar in these apps", apps: $settings.value.excludedApps)
            }
        }
        .sheet(item: $editing) { request in
            CustomActionEditor(action: request.action, isNew: request.isNew,
                               onSave: { save($0, isNew: request.isNew) },
                               onDelete: request.isNew ? nil : { settings.value.remove(customID: request.action.id) })
        }
    }

    private func save(_ action: CustomAction, isNew: Bool) {
        if isNew {
            settings.value.add(action)
        } else if let i = settings.value.customActions.firstIndex(where: { $0.id == action.id }) {
            settings.value.customActions[i] = action
        }
    }

    // MARK: Showing the bar

    private var showingSection: some View {
        Section("Showing the bar") {
            Toggle(isOn: $settings.value.autoShow) {
                RowLabel("Show the bar when you select text", subtitle: "When off, the bar appears only with the shortcut.")
            }
            if settings.value.autoShow {
                LabeledContent {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Dragging across text", isOn: $settings.value.triggers.drag)
                        Toggle("Double- or triple-clicking", isOn: $settings.value.triggers.multiClick)
                        Toggle("⇧-clicking to extend a selection", isOn: $settings.value.triggers.shiftClick)
                        Toggle("Selecting with ⇧ and the arrow keys", isOn: $settings.value.triggers.keyboard)
                        Toggle("Clicking and holding (offers Paste)", isOn: $settings.value.triggers.longPress)
                    }
                    .toggleStyle(.checkbox)
                    .fixedSize()
                } label: {
                    RowLabel("Selections that show it", subtitle: "Never in password fields or while secure input is on.")
                }
                Picker(selection: $settings.value.requiredModifier) {
                    ForEach(TextActionsSettings.RequiredModifier.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                } label: {
                    RowLabel(title: Text("Only while holding"),
                             subtitle: settings.value.requiredModifier == .none
                                 ? Text("Hold ⌘ while selecting to skip the bar once.")
                                 : Text("Hold the key as you finish selecting."))
                }
                SliderRow("Delay", subtitle: "Time between finishing a selection and the bar appearing.",
                          value: $settings.value.delay, in: 0...1000, step: 50) { Self.milliseconds($0) }
            }
            ShortcutRow("Show for the current selection",
                        subtitle: "Choose with ← →, run with Return or 1–9, close with Esc.",
                        shortcut: $settings.value.showShortcut)
        }
    }

    static func milliseconds(_ value: Double) -> String {
        Duration.milliseconds(Int(value)).formatted(.units(allowed: [.milliseconds], width: .abbreviated))
    }

    // MARK: Bar

    private var barSection: some View {
        Section("Bar") {
            Picker(selection: $settings.value.labelStyle) {
                ForEach(TextActionsSettings.LabelStyle.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Buttons show")
            }
            .pickerStyle(.segmented)
            Picker(selection: $settings.value.size) {
                ForEach(TextActionsSettings.BarSize.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Size")
            }
            .pickerStyle(.segmented)
            Picker(selection: $settings.value.placement) {
                ForEach(TextActionsSettings.Placement.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            } label: {
                RowLabel("Position", subtitle: "Multi-line selections follow the pointer: above where a drag went up, below where it went down.")
            }
            LabeledContent {
                Stepper(value: $settings.value.visibleCount, in: 3...12) {
                    Text(verbatim: settings.value.visibleCount.formatted())
                        .monospacedDigit()
                        .frame(minWidth: 20, alignment: .trailing)
                }
            } label: {
                RowLabel("Actions before the overflow button", subtitle: "The rest are one click away behind ›.")
            }
            Toggle(isOn: $settings.value.hideWhenPointerLeaves) {
                RowLabel("Close when the pointer moves away")
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section {
            BarPreviewStrip(settings: settings.value)
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            ForEach(settings.value.slots) { slot in
                ActionRow(slot: slot, settings: settings,
                          edit: { action in editing = EditorRequest(action: action, isNew: false) })
            }
            .onMove { from, to in
                var slots = settings.value.slots
                slots.move(fromOffsets: from, toOffset: to)
                settings.value.actions = slots
            }
        } header: {
            Text("Actions")
        } footer: {
            Text("Drag to reorder. Each action appears only when it fits the selection, so the bar stays short.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Custom actions

    private var customSection: some View {
        Section("Custom actions") {
            if settings.value.customActions.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 22))
                        .foregroundStyle(Tint.purple.color)
                        .frame(width: 34)
                    RowLabel("Add your own actions",
                             subtitle: "Open a URL with the selection, run a shell script, AppleScript or Shortcut on it, or press keys. They join the list above.")
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(CustomAction.Kind.allCases, id: \.self) { kind in
                        Button {
                            editing = EditorRequest(action: CustomAction(name: "", kind: kind, template: kind == .url ? "https://" : ""),
                                                    isNew: true)
                        } label: {
                            Label { Text(verbatim: kind.title) } icon: { Image(systemName: kind.symbol) }
                        }
                    }
                    Divider()
                    Section("Examples") {
                        ForEach(CustomActionExamples.all, id: \.name) { example in
                            Button {
                                editing = EditorRequest(action: example, isNew: true)
                            } label: {
                                Label { Text(verbatim: example.name) } icon: { Image(systemName: example.symbol) }
                            }
                        }
                    }
                } label: {
                    Label("New Action", systemImage: "plus")
                }
                .fixedSize()
                Spacer()
                Button("Import…", action: importActions)
                Button("Export…", action: exportActions)
                    .disabled(settings.value.customActions.isEmpty)
            }
            if let importMessage {
                InfoBar(importMessage.kind, title: Text(verbatim: importMessage.text))
            }
        }
    }

    private func importActions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a file of text actions exported from MacToys")
        panel.prompt = String(localized: "Import", comment: "Open panel button: import the chosen file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let existing = Set(settings.value.customActions.map(\.id))
            let imported = try CustomActionsFile.import(try Data(contentsOf: url), existing: existing)
            settings.update { s in imported.forEach { s.add($0) } }
            importMessage = ImportMessage(kind: .success, text: String(localized: "Imported \(imported.count) actions.",
                                                                       comment: "%lld is the number of imported custom actions"))
        } catch {
            importMessage = ImportMessage(kind: .error, text: error.localizedDescription)
        }
    }

    private func exportActions() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = String(localized: "Text Actions.json", comment: "Default file name for exported custom text actions")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CustomActionsFile.export(settings.value.customActions).write(to: url, options: .atomic)
            importMessage = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            importMessage = ImportMessage(kind: .error, text: error.localizedDescription)
        }
    }

    // MARK: Action options

    private var optionsSection: some View {
        Section("Action options") {
            Picker(selection: $settings.value.searchEngine) {
                ForEach(SearchEngine.allCases, id: \.self) { engine in
                    if engine == .custom { Divider() }
                    Text(verbatim: engine.title).tag(engine)
                }
            } label: {
                RowLabel("Search with")
            }
            if settings.value.searchEngine == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(text: $settings.value.customSearchURL, prompt: Text(verbatim: "https://example.com/search?q={text}")) {
                        Text("Search URL")
                    }
                    .font(.system(size: 12, design: .monospaced))
                    Text("{text} is replaced by the selection.", comment: "Keep {text} as is: it's the placeholder")
                        .font(.system(size: 11.5))
                        .foregroundStyle(URLTemplate.isValid(settings.value.customSearchURL) ? Color.secondary : Color.red)
                }
            }
            Picker(selection: $settings.value.translateTarget) {
                Text("System language (\(LanguageGuess.name(LanguageGuess.target(setting: ""))))",
                     comment: "Translate target choice; %@ is the language name")
                    .tag("")
                Divider()
                ForEach(Self.translationLanguages, id: \.self) { code in
                    Text(verbatim: LanguageGuess.name(Locale.Language(identifier: code))).tag(code)
                }
            } label: {
                RowLabel("Translate into", subtitle: "Translation runs on this Mac. Languages you haven’t downloaded are offered in Language & Region settings.")
            }
            LabeledContent {
                Button("Language & Region…") { OnDeviceTranslator.openLanguageSettings() }
            } label: {
                RowLabel("Translation languages", subtitle: "Download languages under Translation Languages to translate offline.")
            }
        }
    }

    static let translationLanguages = ["ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt-BR",
                                       "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]

    // MARK: Reading the selection

    private var readingSection: some View {
        Section("Reading the selection") {
            Toggle(isOn: $settings.value.copyFallback) {
                RowLabel("Copy the selection in apps that don’t share it",
                         subtitle: "Presses ⌘C and puts your clipboard back right after. The shortcut always tries this.")
            }
            Toggle(isOn: $settings.value.pasteToReplace) {
                RowLabel("Replace text by pasting",
                         subtitle: "For apps that ignore text replaced through Accessibility. Your clipboard is put back afterwards.")
            }
        }
    }
}

/// One action in the reorderable list.
private struct ActionRow: View {
    let slot: ActionSlot
    @Bindable var settings: Persisted<TextActionsSettings>
    let edit: (CustomAction) -> Void

    var body: some View {
        let custom = settings.value.custom(slotID: slot.id)
        let builtIn = BuiltInAction(rawValue: slot.id)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ModuleIcon(symbol: custom?.symbol ?? builtIn?.symbol ?? "bolt", tint: custom != nil ? .purple : builtIn?.tint ?? .graphite,
                       size: 24)
                .opacity(slot.enabled ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: custom?.name ?? builtIn?.title ?? slot.id)
                    if let custom {
                        Text(verbatim: custom.kind.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Tint.purple.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Tint.purple.color.opacity(0.12)))
                    }
                }
                Text(verbatim: custom?.condition.title ?? builtIn?.condition ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Move Up") { move(-1) }.disabled(index == 0)
                Button("Move Down") { move(1) }.disabled(index == settings.value.slots.count - 1)
                if let custom {
                    Divider()
                    Button("Edit…") { edit(custom) }
                    Button("Delete", role: .destructive) { settings.value.remove(customID: custom.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More", comment: "Accessibility: menu with more options for an action"))
            Toggle(isOn: Binding(get: { slot.enabled }, set: { setEnabled($0) })) {
                Text(verbatim: custom?.name ?? builtIn?.title ?? slot.id)
            }
            .labelsHidden()
            .toggleStyle(.adaptiveSwitch)
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let custom { edit(custom) } }
    }

    private var index: Int { settings.value.slots.firstIndex { $0.id == slot.id } ?? 0 }

    private func move(_ delta: Int) {
        var slots = settings.value.slots
        let i = index, j = i + delta
        guard slots.indices.contains(j) else { return }
        slots.swapAt(i, j)
        settings.value.actions = slots
    }

    private func setEnabled(_ on: Bool) {
        var slots = settings.value.slots
        guard let i = slots.firstIndex(where: { $0.id == slot.id }) else { return }
        slots[i].enabled = on
        settings.value.actions = slots
    }
}

/// The enabled actions as the bar would show them, on a dark strip, updated live.
struct BarPreviewStrip: View {
    let settings: TextActionsSettings

    var body: some View {
        let model = BarModel()
        let items = settings.slots.filter(\.enabled).compactMap { slot -> BarItem? in
            if let builtIn = BuiltInAction(rawValue: slot.id) { return .builtIn(builtIn) }
            return settings.custom(slotID: slot.id).map(BarItem.custom)
        }
        model.reset(items: items, settings: settings, keyboard: false)
        model.showsCaption = false
        model.isShown = true
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.3), Color(red: 0.34, green: 0.22, blue: 0.42)],
                                     startPoint: .leading, endPoint: .trailing))
            if items.isEmpty {
                Text("Turn on at least one action.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                ActionBarView(model: model)
                    .environment(\.colorScheme, .dark)
                    .allowsHitTesting(false)
                    .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of the bar", comment: "Accessibility: live preview of the Text Actions bar"))
    }
}
