import AppKit
import MacToysCore
import SwiftUI

/// Workspaces: capture the apps and window layout on screen as a named workspace, then bring
/// it back with one click, a shortcut, a URL, a Dock shortcut or at login.
@MainActor
public final class WorkspacesModule: ToyModule {
    public let info = ModuleInfo(
        id: "workspaces", name: "Workspaces",
        summary: "Launch a set of apps into saved window positions with one click.",
        symbol: "rectangle.split.2x2.fill", tint: .blue, category: .windowing,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["layout", "desktop", "launch", "apps", "session", "restore", "windows"])

    let settings = Persisted("workspaces", default: WorkspacesSettings())
    let editorState = EditorState()

    private let editor = WorkspacesEditorWindow()
    private let progress = LaunchProgressPanel()
    private var current: LaunchSession?
    private var queue: [UUID] = []
    private var running = false
    private var registeredEditor: Shortcut??
    private var registeredLaunch: [UUID: Shortcut] = [:]
    private var checkedLoginLaunch = false
    private let log = Log.for("workspaces")

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkeys()
        }
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        registerHotkeys()
        launchLoginWorkspacesIfNeeded()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "workspaces.")
        registeredEditor = nil
        registeredLaunch = [:]
        queue.removeAll()
        current?.cancel()
        current = nil
        progress.close()
        editor.close()
        settings.flush()
    }

    public func settingsView() -> AnyView { AnyView(WorkspacesSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        var actions = [QuickAction(id: "workspaces.editor", title: "Workspaces", symbol: info.symbol, tint: info.tint,
                                   shortcut: settings.value.editorShortcut) { [weak self] in self?.openEditor() }]
        for ws in settings.value.workspaces {
            actions.append(QuickAction(id: "workspaces.launch.\(ws.id.uuidString)",
                                       title: String(localized: "Launch \(ws.name)", comment: "Quick action; %@ is the workspace name"),
                                       symbol: "play.rectangle.fill", tint: info.tint, shortcut: ws.shortcut) {
                [weak self] in self?.launch(ws.id)
            })
        }
        return actions
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Open the Workspaces editor", settings.value.editorShortcut)]
            + settings.value.workspaces.compactMap { ws in ws.shortcut.map { ShortcutBinding("Launch “\(ws.name)”", $0) } }
    }

    /// `mactoys://workspaces/<action>`: `editor` (alias `open`, optional `name=`), `launch?name=…` or
    /// `launch?id=…`, `capture?name=…`, `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "editor", "open", "show":
            openEditor(selecting: find(command)?.id)
        case "launch":
            guard let ws = find(command) else {
                HUD.show("No workspace named “\(command.parameters["name"] ?? command.parameters["id"] ?? "")”",
                         symbol: "questionmark.square.dashed")
                return true
            }
            launch(ws.id)
        case "capture":
            capture(name: command.parameters["name"])
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("editor", size: CGSize(width: 980, height: 940), wallpaper: false) { AnyView(WorkspacesEditorPreview()) },
         PreviewScene("progress", size: CGSize(width: 420, height: 400)) { AnyView(LaunchProgressPreview()) }]
    }

    // MARK: Editor

    func openEditor(selecting id: UUID? = nil) {
        if let id { editorState.selection = id }
        editor.show(settings: settings, state: editorState, actions: editorActions)
    }

    private var editorActions: EditorActions {
        EditorActions(
            capture: { [weak self] in self?.capture(name: nil) },
            launch: { [weak self] id in self?.launch(id) },
            recapture: { [weak self] id in self?.recapture(id) },
            duplicate: { [weak self] id in self?.duplicate(id) },
            delete: { [weak self] id in self?.confirmDelete(id) },
            export: { [weak self] id, kind in self?.export(id, as: kind) },
            chooseTarget: { [weak self] ws, app in self?.chooseTarget(workspace: ws, app: app) })
    }

    private func find(_ command: AppCommand) -> Workspace? {
        let list = settings.value.workspaces
        if let raw = command.parameters["id"], let id = UUID(uuidString: raw) { return list.first { $0.id == id } }
        guard let name = command.parameters["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return list.first { $0.name == name } ?? list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Capture and edit

    func capture(name: String?) {
        guard requireAccessibility() else { return }
        let n = name.flatMap { $0.isEmpty ? nil : $0 } ?? nextName()
        let ws = WorkspaceCapture.capture(name: n, moveExisting: settings.value.moveExistingByDefault)
        guard !ws.apps.isEmpty else {
            HUD.show("No windows to capture", symbol: "rectangle.dashed")
            return
        }
        settings.value.workspaces.append(ws)
        editorState.selection = ws.id
        editorState.selectedApp = nil
        HUD.show(String(localized: "Captured “\(n)” · \(ws.appCount) apps",
                        comment: "HUD after capturing a workspace; %@ is its name, %lld the number of apps"),
                 symbol: "rectangle.split.2x2.fill")
    }

    private func recapture(_ id: UUID) {
        guard requireAccessibility(),
              let i = settings.value.workspaces.firstIndex(where: { $0.id == id }) else { return }
        let old = settings.value.workspaces[i]
        let fresh = WorkspaceCapture.capture(name: old.name, moveExisting: old.moveExistingWindows)
        guard !fresh.apps.isEmpty else {
            HUD.show("No windows to capture", symbol: "rectangle.dashed")
            return
        }
        settings.value.workspaces[i] = fresh.keepingOptions(from: old)
        HUD.show("Recaptured “\(old.name)”", symbol: "rectangle.split.2x2.fill")
    }

    private func duplicate(_ id: UUID) {
        guard let i = settings.value.workspaces.firstIndex(where: { $0.id == id }) else { return }
        var copy = settings.value.workspaces[i]
        copy.id = UUID()
        copy.name = uniqueName(String(localized: "\(copy.name) copy", comment: "Name of a duplicated workspace; %@ is the original name"))
        copy.shortcut = nil
        copy.launchAtLogin = false
        copy.lastLaunched = nil
        copy.created = Date()
        settings.value.workspaces.insert(copy, at: i + 1)
        editorState.selection = copy.id
    }

    private func confirmDelete(_ id: UUID) {
        guard let ws = settings.value.workspaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(ws.name)”?", comment: "Alert title; %@ is the workspace name")
        alert.informativeText = String(localized: "Its apps keep running; only the saved layout is removed.")
        alert.addButton(withTitle: String(localized: "Delete", comment: "Alert button: delete the workspace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        let remove = { [weak self] in
            guard let self else { return }
            self.settings.value.workspaces.removeAll { $0.id == id }
            if self.editorState.selection == id { self.editorState.selection = self.settings.value.workspaces.first?.id }
        }
        if let window = editor.nsWindow, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { MainActor.assumeIsolated { remove() } }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            remove()
        }
    }

    private func chooseTarget(workspace wsID: UUID, app appID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Open panel button: use the selected file or folder")
        panel.message = String(localized: "Choose a file or folder to open with the app")
        let apply = { [weak self] (url: URL) in
            guard let self, let i = self.settings.value.workspaces.firstIndex(where: { $0.id == wsID }),
                  let j = self.settings.value.workspaces[i].apps.firstIndex(where: { $0.id == appID }) else { return }
            let home = NSHomeDirectory()
            self.settings.value.workspaces[i].apps[j].openTarget = url.path.hasPrefix(home + "/")
                ? "~" + url.path.dropFirst(home.count) : url.path
        }
        if let window = editor.nsWindow, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { apply(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            apply(url)
        }
    }

    private func export(_ id: UUID, as kind: WorkspaceExport.Kind) {
        guard let ws = settings.value.workspaces.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = WorkspaceExport.fileName(for: ws.name, kind: kind)
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        panel.message = String(localized: "Opening this file launches “\(ws.name)”.",
                               comment: "Save panel message; %@ is the workspace name")
        let write = { [weak self] (url: URL) in
            do {
                try WorkspaceExport.write(kind, for: ws, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                self?.log.error("Export failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
        NSApp.activate()
        if let window = editor.nsWindow, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                MainActor.assumeIsolated { write(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            write(url)
        }
    }

    private func nextName() -> String {
        var n = settings.value.workspaces.count + 1
        func name(_ n: Int) -> String {
            String(localized: "Workspace \(n)", comment: "Default name of a newly captured workspace; %lld is a number")
        }
        while settings.value.workspaces.contains(where: { $0.name == name(n) }) { n += 1 }
        return name(n)
    }

    private func uniqueName(_ base: String) -> String {
        var name = base, n = 2
        while settings.value.workspaces.contains(where: { $0.name == name }) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    // MARK: Launching

    func launch(_ id: UUID) {
        guard running else {
            HUD.show("Workspaces is off", symbol: "rectangle.split.2x2")
            return
        }
        guard requireAccessibility(), let i = settings.value.workspaces.firstIndex(where: { $0.id == id }) else { return }
        if let current, !current.isFinished {
            if current.workspaceID != id && !queue.contains(id) { queue.append(id) }
            return
        }
        let ws = settings.value.workspaces[i]
        settings.value.workspaces[i].lastLaunched = Date()
        let session = LaunchSession(workspace: ws)
        current = session
        let s = settings.value
        if s.showProgress {
            progress.show(session) { [weak self] in self?.progress.close() }
        }
        log.info("Launching \(ws.name, privacy: .public) with \(ws.apps.count) windows")
        session.task = Task { [weak self] in
            await WorkspaceLauncher.run(ws, timeout: max(3, s.windowTimeout), session: session)
            self?.finished(session)
        }
    }

    private func finished(_ session: LaunchSession) {
        let s = settings.value
        let cancelled = session.rows.contains { $0.status == .cancelled }
        if s.showProgress {
            if s.closeProgressWhenDone && session.failedCount == 0 && !cancelled { progress.close(after: 1.4) }
        } else if session.failedCount > 0 {
            HUD.show(session.summary, symbol: "exclamationmark.triangle")
        } else if !cancelled {
            HUD.show("“\(session.workspaceName)” is ready", symbol: "checkmark.circle")
        }
        if current === session { current = nil }
        if running, !queue.isEmpty {
            let next = queue.removeFirst()
            // Let the panel show the finished state for a moment before the next launch replaces it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.launch(next) }
        }
    }

    /// Workspaces marked "Launch at login" run when MacToys itself was started by the login.
    private func launchLoginWorkspacesIfNeeded() {
        guard !checkedLoginLaunch else { return }
        checkedLoginLaunch = true
        let appLaunch = NSRunningApplication.current.launchDate ?? Date()
        guard LoginSession.isLoginLaunch(appLaunch: appLaunch, login: LoginSession.consoleLoginDate()) else { return }
        let ids = settings.value.workspaces.filter(\.launchAtLogin).map(\.id)
        guard !ids.isEmpty else { return }
        log.info("Launching \(ids.count) login workspace(s)")
        // Give the login a few seconds to settle (Dock, menu bar, restored apps).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            for id in ids { self?.launch(id) }
        }
    }

    // MARK: Hotkeys and permissions

    private func registerHotkeys() {
        let s = settings.value
        if registeredEditor != .some(s.editorShortcut) {
            HotkeyCenter.shared.register("workspaces.editor", s.editorShortcut) { [weak self] in self?.openEditor() }
            registeredEditor = .some(s.editorShortcut)
        }
        var wanted: [UUID: Shortcut] = [:]
        for ws in s.workspaces { if let sc = ws.shortcut { wanted[ws.id] = sc } }
        guard wanted != registeredLaunch else { return }
        for id in registeredLaunch.keys where wanted[id] == nil {
            HotkeyCenter.shared.unregister("workspaces.launch.\(id.uuidString)")
        }
        for (id, shortcut) in wanted where registeredLaunch[id] != shortcut {
            HotkeyCenter.shared.register("workspaces.launch.\(id.uuidString)", shortcut) { [weak self] in self?.launch(id) }
        }
        registeredLaunch = wanted
    }

    private func requireAccessibility() -> Bool {
        guard AXIsProcessTrusted() else {
            HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.accessibility)
            return false
        }
        return true
    }
}
