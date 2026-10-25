import AppKit
import MacToysCore
import SwiftUI

/// Design 07 "Environment Variables": profiles in a sidebar; the selected scope's variables,
/// PATH-like lists as reorderable entries, and the User variables underneath.
struct EnvEditorView: View {
    let module: EnvironmentVariablesModule
    @Bindable var s: Persisted<EnvSettings>
    @Bindable var editor: EnvEditorState
    var chrome = false

    init(module: EnvironmentVariablesModule, chrome: Bool = false) {
        self.module = module
        self.s = module.settings
        self.editor = module.editor
        self.chrome = chrome
    }

    var body: some View {
        VStack(spacing: 0) {
            if chrome { PreviewTitleBar(title: String(localized: "Environment Variables"), symbol: "curlybraces", tint: .graphite) { actions } }
            HStack(spacing: 0) {
                sidebar.frame(width: 200)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle("Environment Variables")
        .toolbar { ToolbarItemGroup(placement: .primaryAction) { actions } }
    }

    @ViewBuilder private var actions: some View {
        Button("Remove duplicates") { module.removeDuplicates() }
            .disabled(!module.selectionHasDuplicates)
            .help("Removes repeated entries from PATH-like variables, keeping the first of each")
        Button {
            module.apply()
        } label: {
            if editor.applying { ProgressView().controlSize(.small) } else { Text("Apply") }
        }
        .buttonStyle(.borderedProminent)
        .disabled(editor.applying)
        .keyboardShortcut("s", modifiers: .command)
        .help(module.hasUnappliedChanges ? Text("Write your changes to ~/.zshenv and launchd") : Text("Everything is applied"))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: Binding(get: { editor.selection }, set: { if let v = $0 { editor.selection = v } })) {
                Section("Profiles") {
                    ForEach(s.value.profiles) { p in
                        HStack(spacing: 8) {
                            Circle().fill(s.value.appliedProfile == p.id ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(verbatim: p.name).lineLimit(1)
                        }
                        .tag(EnvEditorState.Selection.profile(p.id))
                        .contextMenu {
                            Button {
                                module.setApplied(s.value.appliedProfile == p.id ? nil : p.id)
                            } label: {
                                s.value.appliedProfile == p.id ? Text("Un-apply", comment: "Stop applying this profile") : Text("Apply")
                            }
                            Button("Duplicate") { module.duplicateProfile(p.id) }
                            Divider()
                            Button("Delete", role: .destructive) { module.deleteProfile(p.id) }
                        }
                    }
                }
                Section("Environment") {
                    Label("User variables", systemImage: "person").tag(EnvEditorState.Selection.user)
                    Label("Effective", systemImage: "eye").tag(EnvEditorState.Selection.effective)
                }
            }
            .listStyle(.sidebar)
            Divider()
            Button {
                module.addProfile()
            } label: {
                Label("New profile", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let m = editor.message {
                    InfoBar(m.kind, title: m.kind == .error ? Text("Couldn't apply")
                                : (m.kind == .warning ? Text("Applied with warnings") : Text("Done")),
                            message: Text(verbatim: m.text), actionTitle: Text("Dismiss")) { editor.message = nil }
                } else if module.hasUnappliedChanges && editor.selection != .effective {
                    InfoBar(.info, title: "Unapplied changes", message: "Apply writes them to ~/.zshenv and launchd.",
                            actionTitle: "Apply") { module.apply() }
                }
                switch editor.selection {
                case .profile(let id):
                    if let profile = s.value.profiles.first(where: { $0.id == id }) { profileDetail(profile) }
                case .user:
                    ScopeEditor(title: Text("User", comment: "Scope of the User variables"), subtitle: Text(verbatim: "~/.zshenv · launchctl"),
                                vars: $s.value.userVariables,
                                emptyText: Text("Variables here apply to every zsh and, with launchd on, to apps you open."))
                case .effective:
                    EffectiveView(module: module)
                }
            }
            .padding(20)
        }
    }

    /// A binding to one profile by id, safe while the profile is being deleted.
    private func profileBinding(_ profile: EnvProfile) -> Binding<EnvProfile> {
        let id = profile.id
        return Binding(get: { s.value.profiles.first { $0.id == id } ?? profile },
                       set: { new in if let i = s.value.profiles.firstIndex(where: { $0.id == id }) { s.value.profiles[i] = new } })
    }

    @ViewBuilder private func profileDetail(_ profile: EnvProfile) -> some View {
        let id = profile.id
        let binding = profileBinding(profile)
        let applied = s.value.appliedProfile == id
        HStack(spacing: 12) {
            TextField("Profile name", text: binding.name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
            Spacer()
            Toggle(isOn: Binding(get: { applied }, set: { module.setApplied($0 ? id : nil) })) {
                applied ? Text("Applied", comment: "This profile is applied") : Text("Not applied", comment: "This profile isn't applied")
            }
                .toggleStyle(.adaptiveSwitch)
            Menu {
                Button("Duplicate") { module.duplicateProfile(id) }
                Button("Delete", role: .destructive) { module.deleteProfile(id) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        ScopeEditor(title: Text(verbatim: profile.name),
                    subtitle: !applied ? Text("not applied — only one profile can be applied")
                        : s.value.applyToLaunchd ? Text("applied to zsh + launchd") : Text("applied to zsh"),
                    vars: binding.variables,
                    emptyText: Text("Add the variables this profile sets. They take precedence over User variables of the same name."),
                    userVariables: s.value.userVariables)
        ScopeEditor(title: Text("User", comment: "Scope of the User variables"), subtitle: Text(verbatim: "~/.zshenv · launchctl"),
                    vars: $s.value.userVariables, emptyText: Text("No User variables."), compact: true)
    }

    /// Sample data for `MacToys --snapshot`.
    @MainActor
    static func preview() -> some View {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-preview-\(UUID().uuidString)")
        let module = EnvironmentVariablesModule(store: SettingsStore(directory: dir))
        let python = EnvProfile(name: "Python 3.13", variables: [
            EnvVariable(name: "PYENV_VERSION", value: "3.13.1"),
            EnvVariable(name: "PYTHONDONTWRITEBYTECODE", value: "1"),
            EnvVariable(name: "PATH", value: "/opt/homebrew/bin:~/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"),
        ])
        module.settings.value.profiles = [
            EnvProfile(name: "Default shell"), python, EnvProfile(name: "Node LTS"), EnvProfile(name: "Proxy (office)"),
        ]
        module.settings.value.userVariables = [EnvVariable(name: "EDITOR", value: "nvim"), EnvVariable(name: "LANG", value: "en_US.UTF-8")]
        module.settings.value.appliedProfile = python.id
        module.settings.value.lastApplied = EnvComposer.effective(module.settings.value)
        module.editor.selection = .profile(python.id)
        return EnvEditorView(module: module, chrome: true).background(Color(nsColor: .windowBackgroundColor))
    }
}

/// One scope's variables: a card of name/value rows, then a list card per PATH-like variable.
private struct ScopeEditor: View {
    let title: Text
    let subtitle: Text
    @Binding var vars: [EnvVariable]
    let emptyText: Text
    var userVariables: [EnvVariable] = []
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title.font(.system(size: 13, weight: .semibold))
                subtitle.font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                addMenu
            }
            let plain = vars.filter { !$0.isPathLike }
            if vars.isEmpty {
                emptyText.font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(card)
            } else if !plain.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(plain.enumerated()), id: \.element.id) { n, v in
                        if n > 0 { Divider() }
                        VariableRow(variable: binding(v), onDelete: { vars.removeAll { $0.id == v.id } },
                                    onMove: { delta in move(v.id, by: delta) },
                                    isFirst: vars.first?.id == v.id, isLast: vars.last?.id == v.id)
                    }
                }
                .background(card)
            }
            ForEach(vars.filter(\.isPathLike)) { v in
                PathEditor(variable: binding(v), onDelete: { vars.removeAll { $0.id == v.id } })
            }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }

    private var addMenu: some View {
        Menu {
            Button("New Variable") { vars.append(EnvVariable(name: "NEW_VARIABLE", value: "")) }
            if !vars.contains(where: { $0.name == "PATH" }) {
                Button("PATH (prepend to the inherited PATH)") { vars.append(EnvVariable(name: "PATH", value: "$PATH")) }
            }
            let copyable = userVariables.filter { u in !vars.contains { $0.name == u.name } }
            if !copyable.isEmpty {
                Menu("Copy from User Variables") {
                    ForEach(copyable) { u in Button(u.name) { vars.append(EnvVariable(name: u.name, value: u.value)) } }
                }
            }
        } label: {
            Label("Add variable", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
    }

    /// A binding to one variable by id, safe while it's being deleted.
    private func binding(_ v: EnvVariable) -> Binding<EnvVariable> {
        let id = v.id
        return Binding(get: { vars.first { $0.id == id } ?? v },
                       set: { new in if let i = vars.firstIndex(where: { $0.id == id }) { vars[i] = new } })
    }

    private func move(_ id: UUID, by delta: Int) {
        guard let i = vars.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard vars.indices.contains(j) else { return }
        vars.swapAt(i, j)
    }
}

private struct VariableRow: View {
    @Binding var variable: EnvVariable
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                TextField("NAME", text: $variable.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .frame(width: 200, alignment: .leading)
                TextField("value", text: $variable.value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Menu {
                    Button("Move Up") { onMove(-1) }.disabled(isFirst)
                    Button("Move Down") { onMove(1) }.disabled(isLast)
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let problem = EnvNames.problem(variable.name) {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A PATH-like variable as an ordered list of entries; repeats are flagged.
private struct PathEditor: View {
    @Binding var variable: EnvVariable
    let onDelete: () -> Void
    @State private var newEntry = ""

    private var entries: [String] { PathList.split(variable.value) }

    var body: some View {
        let list = entries
        let dupes = PathList.duplicateIndices(list)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("NAME", text: $variable.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize()
                Text("\(list.count) entries", comment: "Number of entries in a PATH-like list").font(.system(size: 11.5)).foregroundStyle(.secondary)
                if let problem = EnvNames.problem(variable.name) {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Menu {
                    Button("Delete \(variable.name)", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, entry in
                    if i > 0 { Divider() }
                    HStack(spacing: 12) {
                        Text(i + 1, format: .number).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .frame(width: 28, alignment: .leading)
                        TextField("entry", text: Binding(get: { entry }, set: { update(i, $0) }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(dupes.contains(i) ? Tint.orange.color : (isInherited(entry) ? Color.secondary : Color.primary))
                        if isInherited(entry) {
                            Text("inherited").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                        if dupes.contains(i) {
                            Text("duplicate").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tint.orange.color)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Tint.orange.color.opacity(0.14)))
                        }
                        Button { moveEntry(i, -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0).help("Move up")
                        Button { moveEntry(i, 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == list.count - 1).help("Move down")
                        Button { removeEntry(i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove entry")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    TextField("Add a folder, e.g. ~/bin", text: $newEntry)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .onSubmit(addEntry)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            newEntry = Self.abbreviate(url.path)
                            addEntry()
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            if !list.contains(where: isInherited) && variable.name == "PATH" {
                Text("Without $PATH this replaces the PATH zsh and apps inherit; add $PATH to keep the system folders.")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
    }

    private func isInherited(_ entry: String) -> Bool {
        entry == "$\(variable.name)" || entry == "${\(variable.name)}"
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func update(_ i: Int, _ text: String) {
        var e = entries
        guard e.indices.contains(i) else { return }
        e[i] = text
        variable.value = PathList.join(e)
    }

    private func moveEntry(_ i: Int, _ delta: Int) {
        var e = entries
        let j = i + delta
        guard e.indices.contains(i), e.indices.contains(j) else { return }
        e.swapAt(i, j)
        variable.value = PathList.join(e)
    }

    private func removeEntry(_ i: Int) {
        var e = entries
        guard e.indices.contains(i) else { return }
        e.remove(at: i)
        variable.value = PathList.join(e)
    }

    private func addEntry() {
        let t = newEntry.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var e = entries
        // New folders go before the inherited $PATH so they win.
        if let inherited = e.firstIndex(where: isInherited) { e.insert(t, at: inherited) } else { e.append(t) }
        variable.value = PathList.join(e)
        newEntry = ""
    }
}

/// Read-only: what a new login shell and newly opened apps actually get.
private struct EffectiveView: View {
    let module: EnvironmentVariablesModule
    @Bindable var editor: EnvEditorState

    init(module: EnvironmentVariablesModule) {
        self.module = module
        self.editor = module.editor
    }

    var body: some View {
        let managed = Dictionary(module.effective.map { ($0.name, $0.source) }, uniquingKeysWith: { _, b in b })
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Effective environment").font(.system(size: 13, weight: .semibold))
                Text(verbatim: "zsh -lc env · launchctl").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if editor.loadingEffective { ProgressView().controlSize(.small) }
                Button("Refresh") { module.loadEffective() }.controlSize(.small)
            }
            if let path = editor.zshEnvironment.first(where: { $0.0 == "PATH" })?.1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PATH (evaluated)").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(PathList.split(path).enumerated()), id: \.offset) { i, e in
                        HStack(spacing: 10) {
                            Text(i + 1, format: .number).frame(width: 24, alignment: .leading).foregroundStyle(.secondary)
                            Text(e).textSelection(.enabled)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Name", comment: "Column: environment variable name").bold()
                    Text(verbatim: "zsh").bold()
                    Text("Apps (launchd)").bold()
                    Text(verbatim: "")
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                ForEach(editor.zshEnvironment.filter { $0.0 != "PATH" }, id: \.0) { name, value in
                    GridRow {
                        Text(name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(value).font(.system(size: 12, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        Text(editor.launchdEnvironment[name] ?? "—").font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(2)
                        if let source = managed[name] {
                            (source == .profile ? Text("profile", comment: "Variable source: the applied profile")
                                : Text("user", comment: "Variable source: User variables"))
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        } else {
                            Text(verbatim: "")
                        }
                    }
                }
            }
            Text("System-wide settings (/etc/zshenv, /etc/paths, /etc/paths.d) are read-only here. Variables only reach shells and apps started after Apply.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .onAppear { if !editor.effectiveLoaded { module.loadEffective() } }
    }
}

/// A unified-toolbar look-alike for offscreen previews (real windows use the native toolbar).
struct PreviewTitleBar<Actions: View>: View {
    let title: String
    let symbol: String
    let tint: Tint
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in Circle().fill(c.opacity(0.85)).frame(width: 12, height: 12) }
            }
            .padding(.trailing, 10)
            ModuleIcon(symbol: symbol, tint: tint, size: 22)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            actions
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}
