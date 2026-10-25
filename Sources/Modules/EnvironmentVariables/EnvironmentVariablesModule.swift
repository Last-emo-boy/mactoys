import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Editor UI state (selection, messages, the read-only effective environment).
@MainActor
@Observable
final class EnvEditorState {
    enum Selection: Hashable {
        case profile(UUID)
        case user
        case effective
    }

    struct Message: Equatable {
        var kind: InfoKind
        var text: String
    }

    var selection: Selection = .user
    var applying = false
    var message: Message?
    /// `zsh -lc env` of a new login shell, and the GUI launchd domain's variables.
    var zshEnvironment: [(String, String)] = []
    var launchdEnvironment: [String: String] = [:]
    var loadingEffective = false
    var effectiveLoaded = false
}

/// Manages environment variables for zsh and GUI apps: User variables plus named profiles,
/// one of which can be applied on top (Profile > User > System).
@MainActor
public final class EnvironmentVariablesModule: ToyModule {
    public let info = ModuleInfo(
        id: "envvars", name: "Environment Variables",
        summary: "Manage environment variables for zsh and GUI apps, grouped into profiles.",
        symbol: "curlybraces", tint: .graphite, category: .advanced,
        permissions: [], enabledByDefault: true,
        keywords: ["env", "path", "zshenv", "launchctl", "setenv", "export", "variables"])

    let settings: Persisted<EnvSettings>
    let editor = EnvEditorState()
    let log = Log.for("envvars")
    var applier = EnvApplier.standard
    private var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var running = false

    public convenience init() {
        self.init(store: .shared)
    }

    init(store: SettingsStore) {
        settings = Persisted("envvars", default: EnvSettings(), store: store)
    }

    public func start() {
        guard !running else { return }
        running = true
        observer = DistributedNotificationCenter.default().addObserver(
            forName: SettingsStore.externalChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings.reload() }
        }
    }

    /// Applied variables stay in place when the utility is turned off (they are the user's
    /// configuration, like PowerToys' registry changes); use "Remove from startup files" to undo them.
    public func stop() {
        guard running else { return }
        running = false
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        window?.close()
        settings.flush()
    }

    // MARK: - Window

    func openWindow() {
        if window == nil {
            let controller = NSHostingController(rootView: EnvEditorView(module: self))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbar = NSToolbar(identifier: "envvars")
            w.toolbarStyle = .unified
            w.title = String(localized: "Environment Variables")
            w.setContentSize(NSSize(width: 860, height: 600))
            w.minSize = NSSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacToysEnvironmentVariables")
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        loadEffective()
    }

    // MARK: - Applying

    var effective: [EffectiveVariable] { EnvComposer.effective(settings.value) }
    var hasUnappliedChanges: Bool { effective != (settings.value.lastApplied ?? []) }

    /// Writes env.zsh, the startup-file blocks and launchd state off the main thread.
    func apply() {
        guard !editor.applying else { return }
        editor.applying = true
        var snapshot = settings.value
        let applier = self.applier
        Task.detached {
            let result: Result<(EnvSettings, [String]), Error>
            do {
                let warnings = try applier.apply(&snapshot)
                result = .success((snapshot, warnings))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { self.finishApply(result) }
        }
    }

    private func finishApply(_ result: Result<(EnvSettings, [String]), Error>) {
        editor.applying = false
        switch result {
        case let .success((applied, warnings)):
            settings.update {
                $0.launchdOriginals = applied.launchdOriginals
                $0.backedUpFiles = applied.backedUpFiles
                $0.lastApplied = applied.lastApplied
            }
            let text: String
            if !warnings.isEmpty {
                text = warnings.joined(separator: "\n")
            } else if let profile = applied.applied?.name {
                text = String(localized: "Applied with \(profile). New shells and newly opened apps see the changes.",
                              comment: "The placeholder is a profile name")
            } else {
                text = String(localized: "Applied. New shells and newly opened apps see the changes.")
            }
            editor.message = .init(kind: warnings.isEmpty ? .success : .warning, text: text)
            log.info("applied \(applied.lastApplied?.count ?? 0) variables")
            loadEffective()
        case .failure(let error):
            editor.message = .init(kind: .error, text: error.localizedDescription)
            log.error("apply failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies (or un-applies) a profile right away, as toggling a profile does in PowerToys.
    func setApplied(_ id: UUID?) {
        settings.value.appliedProfile = id
        apply()
    }

    func uninstall() {
        var snapshot = settings.value
        do {
            let warnings = try applier.uninstall(&snapshot)
            settings.update {
                $0.launchdOriginals = snapshot.launchdOriginals
                $0.lastApplied = nil
            }
            editor.message = .init(kind: warnings.isEmpty ? .success : .warning,
                                   text: warnings.isEmpty ? String(localized: "Removed MacToys from your shell startup files and launchd.")
                                       : warnings.joined(separator: "\n"))
        } catch {
            editor.message = .init(kind: .error, text: error.localizedDescription)
        }
    }

    /// Reads a fresh login shell's environment and launchd's GUI domain in the background.
    func loadEffective() {
        guard !editor.loadingEffective else { return }
        editor.loadingEffective = true
        Task.detached {
            let zsh = EnvFiles.parseEnv0(Shell.run("/bin/zsh", ["-lc", "/usr/bin/env -0"]).stdout)
                .filter { !["_", "SHLVL", "PWD", "OLDPWD"].contains($0.0) }
                .sorted { $0.0 < $1.0 }
            let launchd = Launchctl.domainEnvironment()
            await MainActor.run {
                self.editor.zshEnvironment = zsh
                self.editor.launchdEnvironment = launchd
                self.editor.loadingEffective = false
                self.editor.effectiveLoaded = true
            }
        }
    }

    // MARK: - Editing helpers

    func addProfile() {
        var n = settings.value.profiles.count + 1
        while settings.value.profiles.contains(where: { $0.name == String(localized: "Profile \(n)") }) { n += 1 }
        let p = EnvProfile(name: String(localized: "Profile \(n)", comment: "Default name of a new profile; the placeholder is a number"))
        settings.value.profiles.append(p)
        editor.selection = .profile(p.id)
    }

    func deleteProfile(_ id: UUID) {
        let wasApplied = settings.value.appliedProfile == id
        settings.update {
            $0.profiles.removeAll { $0.id == id }
            if wasApplied { $0.appliedProfile = nil }
        }
        if editor.selection == .profile(id) { editor.selection = .user }
        if wasApplied { apply() }
    }

    func duplicateProfile(_ id: UUID) {
        guard let p = settings.value.profiles.first(where: { $0.id == id }) else { return }
        let copy = EnvProfile(name: String(localized: "\(p.name) copy", comment: "Name of a duplicated profile; the placeholder is the original name"),
                              variables: p.variables.map { EnvVariable(name: $0.name, value: $0.value) })
        settings.value.profiles.append(copy)
        editor.selection = .profile(copy.id)
    }

    /// Removes repeated entries from every PATH-like variable of the selected scope.
    func removeDuplicates() {
        switch editor.selection {
        case .user:
            settings.value.userVariables = Self.deduplicated(settings.value.userVariables)
        case .profile(let id):
            guard let i = settings.value.profiles.firstIndex(where: { $0.id == id }) else { return }
            settings.value.profiles[i].variables = Self.deduplicated(settings.value.profiles[i].variables)
        case .effective:
            break
        }
    }

    static func deduplicated(_ vars: [EnvVariable]) -> [EnvVariable] {
        vars.map { v in
            guard v.isPathLike else { return v }
            var copy = v
            copy.value = PathList.join(PathList.removeDuplicates(PathList.split(v.value)))
            return copy
        }
    }

    var selectionHasDuplicates: Bool {
        let vars: [EnvVariable]
        switch editor.selection {
        case .user: vars = settings.value.userVariables
        case .profile(let id): vars = settings.value.profiles.first { $0.id == id }?.variables ?? []
        case .effective: return false
        }
        return vars.contains { $0.isPathLike && !PathList.duplicateIndices(PathList.split($0.value)).isEmpty }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView { AnyView(EnvSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "envvars.open", title: "Env Variables", symbol: "curlybraces", tint: .graphite,
                     perform: { [weak self] in self?.openWindow() })]
    }

    /// `mactoys://envvars/<action>`: `open`/`show` (editor), `apply`, `settings`,
    /// `profile?name=<name>` (apply that profile; `name=` empty un-applies).
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show": openWindow()
        case "settings": ModuleRegistry.shared.showSettings?(info.id)
        case "apply": apply()
        case "profile":
            let name = command.parameters["name"] ?? ""
            if name.isEmpty { setApplied(nil); return true }
            guard let p = settings.value.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return false }
            setApplied(p.id)
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("window", size: CGSize(width: 860, height: 600), wallpaper: false) {
            AnyView(EnvEditorView.preview())
        }]
    }
}
