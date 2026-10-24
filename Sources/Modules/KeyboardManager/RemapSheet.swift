import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

/// Add or edit one remap.
struct RemapSheet: View {
    @State var remap: Remap
    let isNew: Bool
    let model: RemapEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var newApp = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Remap", selection: kindBinding) {
                        Text("A key").tag(Remap.Kind.key)
                        Text("A shortcut").tag(Remap.Kind.shortcut)
                    }
                    .pickerStyle(.segmented)
                }
                Section(remap.kind == .key ? "When I press the key" : "When I press the shortcut") {
                    KeyField(combo: $remap.trigger, mode: remap.kind == .key ? .key : .shortcut,
                             onFocusChange: model.recorderFocusChanged)
                    if remap.kind == .shortcut {
                        Toggle(isOn: chordBinding) {
                            RowLabel("Chord", subtitle: "Press a second key after the shortcut, like ⌃⇧V then U.")
                        }
                        if remap.chord != nil {
                            KeyField(combo: chordComboBinding, mode: .key, onFocusChange: model.recorderFocusChanged)
                        }
                    }
                }
                Section("Do this") {
                    Picker("Action", selection: actionKindBinding) {
                        Text("Send a key or shortcut").tag(RemapAction.Kind.send)
                        Text("Type text").tag(RemapAction.Kind.text)
                        Text("Open an app or run a program").tag(RemapAction.Kind.run)
                        Text("Open a URL or file").tag(RemapAction.Kind.openURL)
                        Text("Disable the key").tag(RemapAction.Kind.disable)
                    }
                    actionFields
                }
                if remap.kind == .key { tapAloneSection } else { matchSection }
                scopeSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error = remap.validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Add" : "Save") { model.save(remap) }
                    .buttonStyle(.borderedProminent)
                    .disabled(remap.validationError != nil)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
    }

    // MARK: - Action

    @ViewBuilder private var actionFields: some View {
        switch remap.action.kind {
        case .send:
            KeyField(combo: sendComboBinding, mode: .shortcut, onFocusChange: model.recorderFocusChanged)
            Text("Record a single key (a modifier on its own works too) or a shortcut. Use the list for media keys.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        case .text:
            TextField("Text", text: textBinding, axis: .vertical)
                .lineLimit(2...6)
        case .run:
            runFields
        case .openURL:
            TextField("URL, URI or path", text: urlBinding, prompt: Text("https://… · mailto:… · ~/Documents/notes.txt"))
        case .disable:
            Text("The key does nothing.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var runFields: some View {
        LabeledContent("App or program") {
            HStack {
                TextField("", text: runBinding(\.path), prompt: Text("/Applications/Notes.app"))
                Button("Choose…") { choose(\.path, directories: false) }
            }
        }
        TextField("Arguments", text: runBinding(\.arguments), prompt: Text("--new-window \"~/My Folder\""))
        LabeledContent("Start in") {
            HStack {
                TextField("", text: runBinding(\.workingDirectory), prompt: Text("Programs only"))
                Button("Choose…") { choose(\.workingDirectory, directories: true) }
            }
        }
        Picker("If it’s already running", selection: runBinding(\.ifRunning)) {
            ForEach(RunSpec.IfRunning.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Visibility", selection: runBinding(\.visibility)) {
            ForEach(RunSpec.Visibility.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Run as", selection: runBinding(\.elevation)) {
            ForEach(RunSpec.Elevation.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .disabled((remap.action.run?.path ?? "").hasSuffix(".app"))
    }

    // MARK: - Options

    private var tapAloneSection: some View {
        Section("When tapped alone") {
            Toggle(isOn: $remap.tapAlone) {
                RowLabel("Only when the key is tapped on its own",
                         subtitle: "Tapping does the action. Held, or pressed with other keys, the key works as below.")
            }
            if remap.tapAlone {
                Picker("When held", selection: $remap.holdKey) {
                    if remap.trigger.key.isModifier {
                        Text("Acts as itself").tag(Key?.none)
                    } else if remap.trigger.key == .capsLock {
                        Text("Toggles Caps Lock").tag(Key?.none)
                    }
                    ForEach(KeyCatalog.canonicalModifierKey, id: \.1) { mod, code in
                        Text("Acts as \(mod.symbols.joined())").tag(Key?.some(.keyboard(code)))
                    }
                }
            }
        }
    }

    private var matchSection: some View {
        Section("Matching") {
            Toggle(isOn: $remap.exactMatch) {
                RowLabel("Exact match", subtitle: "Only when no other modifiers are held. Otherwise extra modifiers carry over to the output.")
            }
        }
    }

    private var scopeSection: some View {
        Section("Where") {
            Picker("Apply in", selection: Binding(
                get: { remap.apps.isEmpty ? 0 : 1 },
                set: { if $0 == 0 { remap.apps = [] } else if remap.apps.isEmpty { addFrontmostCandidate() } })) {
                Text("All apps").tag(0)
                Text("Only in some apps").tag(1)
            }
            .pickerStyle(.segmented)
            if !remap.apps.isEmpty {
                ForEach(remap.apps, id: \.self) { id in
                    HStack {
                        Text(RemapFormatting.appName(id))
                        Text(id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Button { remap.apps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Bundle identifier", text: $newApp, prompt: Text("com.apple.dt.Xcode"))
                        .onSubmit(addTypedApp)
                    Button("Add", action: addTypedApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu("Running apps") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                                if let id = app.bundleIdentifier { addApp(id) }
                            }
                        }
                    }
                    .fixedSize()
                    Button("Choose…", action: chooseApp)
                }
            }
        }
    }

    // MARK: - Bindings

    private var kindBinding: Binding<Remap.Kind> {
        Binding(get: { remap.kind }, set: { kind in
            remap.kind = kind
            if kind == .key { remap.trigger.modifiers = []; remap.chord = nil }
            else {
                remap.tapAlone = false
                if remap.trigger.modifiers.isEmpty { remap.trigger.modifiers = [.control, .option] }
            }
        })
    }

    private var chordBinding: Binding<Bool> {
        Binding(get: { remap.chord != nil }, set: { remap.chord = $0 ? .keyboard(kVK_ANSI_U) : nil })
    }

    private var chordComboBinding: Binding<KeyCombo> {
        Binding(get: { KeyCombo([], remap.chord ?? .keyboard(kVK_ANSI_U)) }, set: { remap.chord = $0.key })
    }

    private var actionKindBinding: Binding<RemapAction.Kind> {
        Binding(get: { remap.action.kind }, set: { kind in
            remap.action.kind = kind
            switch kind {
            case .send where remap.action.combo == nil: remap.action.combo = KeyCombo([], .escape)
            case .run where remap.action.run == nil: remap.action.run = RunSpec(path: "")
            default: break
            }
        })
    }

    private var sendComboBinding: Binding<KeyCombo> {
        Binding(get: { remap.action.combo ?? KeyCombo([], .escape) }, set: { remap.action.combo = $0 })
    }

    private var textBinding: Binding<String> {
        Binding(get: { remap.action.text ?? "" }, set: { remap.action.text = $0 })
    }

    private var urlBinding: Binding<String> {
        Binding(get: { remap.action.url ?? "" }, set: { remap.action.url = $0 })
    }

    private func runBinding<T>(_ path: WritableKeyPath<RunSpec, T>) -> Binding<T> {
        Binding(get: { (remap.action.run ?? RunSpec(path: ""))[keyPath: path] },
                set: {
                    var spec = remap.action.run ?? RunSpec(path: "")
                    spec[keyPath: path] = $0
                    remap.action.run = spec
                })
    }

    // MARK: - Helpers

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func addApp(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !remap.apps.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
        remap.apps.append(id)
    }

    private func addTypedApp() {
        addApp(newApp)
        newApp = ""
    }

    /// Switching to "some apps" starts with the most recently used other app.
    private func addFrontmostCandidate() {
        let own = Bundle.main.bundleIdentifier
        if let app = runningApps.first(where: { $0.bundleIdentifier != own && $0.isActive })
            ?? runningApps.first(where: { $0.bundleIdentifier != own }), let id = app.bundleIdentifier {
            addApp(id)
        } else {
            addApp("com.apple.finder")
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { addApp(id) }
    }

    private func choose(_ path: WritableKeyPath<RunSpec, String>, directories: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.treatsFilePackagesAsDirectories = false
        if !directories { panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        if panel.runModal() == .OK, let url = panel.url { runBinding(path).wrappedValue = url.path }
    }
}
