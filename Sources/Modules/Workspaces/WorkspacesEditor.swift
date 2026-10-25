import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Selection state of the editor, shared with the module (so "capture" can select what it made).
@MainActor
@Observable
final class EditorState {
    var selection: UUID?
    var selectedApp: UUID?
    var expandedApp: UUID?
}

/// What the editor asks the module to do.
struct EditorActions {
    var capture: () -> Void = {}
    var launch: (UUID) -> Void = { _ in }
    var recapture: (UUID) -> Void = { _ in }
    var duplicate: (UUID) -> Void = { _ in }
    var delete: (UUID) -> Void = { _ in }
    var export: (UUID, WorkspaceExport.Kind) -> Void = { _, _ in }
    /// Picks a file or folder for an app's "open" field: workspace id, app id.
    var chooseTarget: (UUID, UUID) -> Void = { _, _ in }
}

/// The Workspaces editor window.
@MainActor
final class WorkspacesEditorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(settings: Persisted<WorkspacesSettings>, state: EditorState, actions: EditorActions) {
        if window == nil {
            let host = NSHostingController(rootView: WorkspacesEditorView(settings: settings, state: state, actions: actions))
            let w = NSWindow(contentViewController: host)
            w.title = String(localized: "Workspaces")
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // An empty unified toolbar gives the 52 pt title bar the header row is designed for.
            w.toolbar = NSToolbar(identifier: "workspaces.editor")
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 980, height: 660))
            w.minSize = NSSize(width: 820, height: 520)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacToysWorkspacesEditor")
            w.delegate = self
            if w.frame.origin == .zero { w.center() }
            // Don't start with the name field in edit mode.
            w.initialFirstResponder = w.contentView
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    /// The window for sheets and panels.
    var nsWindow: NSWindow? { window }
}

struct WorkspacesEditorView: View {
    let settings: Persisted<WorkspacesSettings>
    let state: EditorState
    let actions: EditorActions

    var body: some View {
        let list = settings.value.workspaces
        let selected = list.first { $0.id == state.selection } ?? list.first
        VStack(spacing: 0) {
            header(selected)
                .background(Color(nsColor: .windowBackgroundColor))
                // Scroll views extend under the title bar on macOS 26; keep the header on top.
                .zIndex(1)
            Divider()
            HStack(spacing: 0) {
                sidebar(list, selected: selected?.id)
                    .frame(width: 262)
                Divider()
                Group {
                    if let selected, let binding = binding(for: selected) {
                        WorkspaceDetail(workspace: binding, state: state, actions: actions)
                            .id(selected.id)
                    } else {
                        empty
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.025))
            }
        }
        // The header row lives in the (transparent) title bar, next to the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 820, minHeight: 520)
    }

    private func header(_ selected: Workspace?) -> some View {
        HStack(spacing: 9) {
            Color.clear.frame(width: 62, height: 1)
            ModuleIcon(symbol: "rectangle.split.2x2.fill", tint: .blue, size: 22)
            Text("Workspaces").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button("Capture current", action: actions.capture)
                .help("Save the apps and windows open now as a new workspace")
            Button { if let id = selected?.id { actions.launch(id) } } label: {
                Text("Launch", comment: "Button: launch the workspace")
            }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private func sidebar(_ list: [Workspace], selected: UUID?) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(list) { ws in
                    WorkspaceCard(workspace: ws, selected: ws.id == selected)
                        .onTapGesture {
                            state.selection = ws.id
                            state.selectedApp = nil
                            state.expandedApp = nil
                        }
                        .contextMenu {
                            Button { actions.launch(ws.id) } label: {
                                Text("Launch", comment: "Button: launch the workspace")
                            }
                            Button("Recapture Current Windows") { actions.recapture(ws.id) }
                            Button("Duplicate") { actions.duplicate(ws.id) }
                            Menu("Create Shortcut") {
                                ForEach(WorkspaceExport.Kind.allCases) { kind in
                                    Button(kind.title) { actions.export(ws.id, kind) }
                                }
                            }
                            Divider()
                            Button("Delete…", role: .destructive) { actions.delete(ws.id) }
                        }
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: actions.capture) {
                    Label("New from current windows", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No workspaces yet", systemImage: "rectangle.split.2x2")
        } description: {
            Text("Open and arrange the apps you use together, then capture them as a workspace.")
        } actions: {
            Button("Capture current", action: actions.capture).buttonStyle(.borderedProminent)
        }
    }

    /// A binding to a workspace by id, safe against the list changing underneath.
    private func binding(for ws: Workspace) -> Binding<Workspace>? {
        guard settings.value.workspaces.contains(where: { $0.id == ws.id }) else { return nil }
        let id = ws.id
        return Binding(
            get: { settings.value.workspaces.first { $0.id == id } ?? ws },
            set: { new in
                if let i = settings.value.workspaces.firstIndex(where: { $0.id == id }) { settings.value.workspaces[i] = new }
            })
    }
}

/// A workspace in the sidebar: name, app icons, summary.
private struct WorkspaceCard: View {
    let workspace: Workspace
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: workspace.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 4) {
                ForEach(uniqueApps.prefix(4), id: \.self) { path in
                    Image(nsImage: AppIcons.icon(path: path)).resizable().frame(width: 20, height: 20)
                }
                Text(verbatim: WorkspaceText.summary(of: workspace))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.09)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var uniqueApps: [String] {
        var seen = Set<String>()
        return workspace.apps.map(\.appPath).filter { seen.insert($0).inserted }
    }
}

/// Right side of the editor: name, canvas, app rows and workspace options.
private struct WorkspaceDetail: View {
    @Binding var workspace: Workspace
    let state: EditorState
    let actions: EditorActions

    var body: some View {
        @Bindable var st = state
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Workspace name", text: $workspace.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Text(verbatim: hint).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                WorkspaceCanvas(workspace: $workspace, selectedApp: $st.selectedApp)
                    .frame(height: 236)
                appList
                options
            }
            .padding(16)
        }
    }

    private var hint: String {
        guard let shortcut = workspace.shortcut else { return String(localized: "Drag windows to adjust") }
        return String(localized: "Drag windows to adjust · \(shortcut.description) launches",
                      comment: "Workspace editor hint; %@ is the keyboard shortcut that launches the workspace")
    }

    private var appList: some View {
        VStack(spacing: 0) {
            if workspace.apps.isEmpty {
                Text("No apps left. Recapture to add the windows open now.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(16)
            }
            ForEach(Array(workspace.apps.enumerated()), id: \.element.id) { i, app in
                if i > 0 { Divider().padding(.leading, 48) }
                WorkspaceAppRow(app: appBinding(app), workspace: workspace,
                                selected: state.selectedApp == app.id, expanded: state.expandedApp == app.id,
                                onSelect: { state.selectedApp = app.id },
                                onToggle: {
                                    state.selectedApp = app.id
                                    state.expandedApp = state.expandedApp == app.id ? nil : app.id
                                },
                                onRemove: { workspace.apps.removeAll { $0.id == app.id } },
                                onChoose: { actions.chooseTarget(workspace.id, app.id) })
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var options: some View {
        VStack(spacing: 0) {
            optionRow("Move existing windows",
                      "Apps that are already open have their windows moved instead of opening new ones") {
                Toggle("Move existing windows", isOn: $workspace.moveExistingWindows).toggleStyle(.adaptiveSwitch).labelsHidden()
            }
            Divider()
            optionRow("Shortcut", "Launches this workspace from anywhere") {
                ShortcutRecorder(shortcut: $workspace.shortcut)
            }
            Divider()
            optionRow("Launch at login", "Runs when MacToys opens as you log in") {
                Toggle("Launch at login", isOn: $workspace.launchAtLogin).toggleStyle(.adaptiveSwitch).labelsHidden()
            }
            Divider()
            HStack(spacing: 8) {
                Menu("Create Shortcut") {
                    ForEach(WorkspaceExport.Kind.allCases) { kind in
                        Button(kind.title) { actions.export(workspace.id, kind) }
                    }
                }
                .fixedSize()
                .help("Save a file that launches this workspace — put it in the Dock or on the Desktop")
                Button("Recapture") { actions.recapture(workspace.id) }
                    .help("Replace the windows with the ones open now, keeping launch options")
                Button("Duplicate") { actions.duplicate(workspace.id) }
                Spacer()
                Button("Delete…", role: .destructive) { actions.delete(workspace.id) }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func optionRow<Control: View>(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey,
                                          @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            RowLabel(title, subtitle: subtitle)
            Spacer(minLength: 12)
            control()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appBinding(_ app: WorkspaceApp) -> Binding<WorkspaceApp> {
        let id = app.id
        return Binding(
            get: { workspace.apps.first { $0.id == id } ?? app },
            set: { new in if let i = workspace.apps.firstIndex(where: { $0.id == id }) { workspace.apps[i] = new } })
    }
}

/// One window of the workspace, with its launch options when expanded.
private struct WorkspaceAppRow: View {
    @Binding var app: WorkspaceApp
    let workspace: Workspace
    let selected: Bool
    let expanded: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: AppIcons.icon(path: app.appPath)).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: app.name).font(.system(size: 13, weight: .medium))
                    Text(verbatim: WorkspaceText.subtitle(of: app, in: workspace))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Menu {
                    Button(action: onToggle) { expanded ? Text("Hide Launch Options") : Text("Launch Options…") }
                    Picker("Launch As", selection: $app.state) {
                        ForEach(WindowState.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Divider()
                    Button("Remove from Workspace", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Options for \(app.name)", comment: "Accessibility: menu button; %@ is the app name"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onToggle)
            .onTapGesture(perform: onSelect)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Arguments").foregroundStyle(.secondary)
                        TextField("Arguments", text: $app.arguments,
                                  prompt: Text("e.g. --reuse-window",
                                               comment: "Placeholder: an example command-line argument; keep --reuse-window"))
                            .font(.system(size: 12, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Open", comment: "Open (verb), as a label: the field with the file, folder or URL the app opens when launched")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            TextField("Open", text: $app.openTarget,
                                      prompt: Text("URL, ~/folder or /path/to/file",
                                                   comment: "Placeholder; keep ~/folder and /path/to/file as path samples"))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…", action: onChoose)
                        }
                    }
                    GridRow {
                        Text("Launch as").foregroundStyle(.secondary)
                        Picker("Launch as", selection: $app.state) {
                            ForEach(WindowState.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    GridRow {
                        Text("Window", comment: "Label: the saved size and position of the window").foregroundStyle(.secondary)
                        Text("\(Int(app.frame.width)) × \(Int(app.frame.height)) at \(Int(app.frame.minX)), \(Int(app.frame.minY))",
                             comment: "Window size and position in points: width × height at x, y")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
                .padding(.leading, 48)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.04))
            }
        }
    }
}
