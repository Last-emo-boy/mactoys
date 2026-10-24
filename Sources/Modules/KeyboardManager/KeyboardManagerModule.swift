import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class KeyboardManagerModule: ToyModule {
    public let info = ModuleInfo(
        id: "keyboardmanager", name: "Keyboard Manager",
        summary: "Remap keys and shortcuts, globally or per app.",
        symbol: "keyboard.fill", tint: .orange, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["remap", "key", "shortcut", "caps lock", "hyper", "keyboard", "chord", "macro", "text"])

    let settings = Persisted("keyboardmanager", default: KeyboardManagerSettings())
    private let driver = RemapDriver()
    private let systemMapping = SystemKeyMapping()
    private let log = Log.for("keyboardmanager")
    private var running = false
    /// Remapping is suspended while a key recorder has focus, so it captures physical keys.
    private var recorders = 0
    private var applied: AppliedState?
    private var editor: RemapEditorWindow?
    private var observing = false

    private struct AppliedState: Equatable {
        var plan: RemapPlan
        var tapTimeout: Double
        var chordTimeout: Double
    }

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        if !observing {
            observing = true
            settings.onChange { [weak self] _ in
                guard let self, self.running else { return }
                self.apply()
                self.registerHotkeys()
            }
        }
        registerHotkeys()
        apply()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "keyboardmanager.")
        driver.uninstall()
        systemMapping.restore()
        // Stop also runs at quit: finish restoring the user's key mapping before the process exits.
        systemMapping.waitUntilIdle()
        applied = nil
        settings.flush()
    }

    /// Whether remaps are being applied right now.
    var isRemapping: Bool { running && !settings.value.paused }

    /// Syncs the tap and the system key mapping with the settings.
    private func apply() {
        let s = settings.value
        guard running, !s.paused, recorders == 0 else {
            if applied != nil {
                driver.uninstall()
                systemMapping.restore()
                applied = nil
            }
            return
        }
        let plan = RemapPlan.make(s.remaps, useSystemMapping: s.useSystemKeyMapping)
        let next = AppliedState(plan: plan, tapTimeout: s.tapTimeout, chordTimeout: s.chordTimeout)
        guard next != applied else { return }
        if applied?.plan.systemMappings != plan.systemMappings {
            systemMapping.apply(plan.systemMappings)
        }
        driver.install(plan, tapTimeout: s.tapTimeout, chordTimeout: s.chordTimeout)
        applied = next
        log.info("Applied \(plan.tapRemaps.count) tap remaps, \(plan.systemMappings.count) system mappings")
    }

    private func registerHotkeys() {
        HotkeyCenter.shared.register("keyboardmanager.editor", settings.value.openEditorShortcut) { [weak self] in
            self?.openEditor()
        }
        HotkeyCenter.shared.register("keyboardmanager.toggle", settings.value.toggleShortcut) { [weak self] in
            self?.togglePaused()
        }
    }

    // MARK: - Recording

    /// Called by key recorders when they gain or lose focus.
    func recorderFocusChanged(_ focused: Bool) {
        recorders = max(0, recorders + (focused ? 1 : -1))
        HotkeyCenter.shared.isSuspended = recorders > 0
        if running { apply() }
    }

    // MARK: - Actions

    func togglePaused() {
        settings.value.paused.toggle()
        HUD.show(settings.value.paused ? "Key remapping paused" : "Key remapping on",
                 symbol: settings.value.paused ? "pause.circle" : "keyboard")
    }

    func openEditor() {
        if editor == nil { editor = RemapEditorWindow(module: self) }
        editor?.show()
    }

    func exportProfile(to url: URL? = nil) {
        let s = settings.value
        let profile = s.profiles.isEmpty ? RemapProfile(name: "Default") : s.profiles[s.activeProfileIndex]
        let write: (URL) -> Void = { [log] url in
            do { try RemapProfileFile(profile: profile).encoded().write(to: url, options: .atomic) }
            catch {
                log.error("Export failed: \(error.localizedDescription, privacy: .public)")
                HUD.show("Export failed", symbol: "exclamationmark.triangle")
            }
        }
        if let url { write(url); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(profile.name) Keyboard Profile.json"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { write(url) }
    }

    /// Imports a profile file as a new profile and makes it active.
    func importProfile(from url: URL? = nil) {
        let read: (URL) -> Void = { [weak self] url in
            guard let self else { return }
            do {
                var profile = try RemapProfileFile.decode(Data(contentsOf: url))
                profile.id = UUID()
                for i in profile.remaps.indices { profile.remaps[i].id = UUID() }
                if profile.name.isEmpty { profile.name = url.deletingPathExtension().lastPathComponent }
                let names = Set(self.settings.value.profiles.map(\.name))
                if names.contains(profile.name) { profile.name += " (imported)" }
                self.settings.update {
                    $0.profiles.append(profile)
                    $0.activeProfileID = profile.id
                }
                HUD.show("Imported “\(profile.name)” · \(profile.remaps.count) remaps", symbol: "square.and.arrow.down")
            } catch {
                self.log.error("Import failed: \(error.localizedDescription, privacy: .public)")
                HUD.show(error.localizedDescription, symbol: "exclamationmark.triangle")
            }
        }
        if let url { read(url); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { read(url) }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(KeyboardManagerSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "keyboardmanager.editor", title: "Keyboard Manager", symbol: "keyboard", tint: .orange,
                        shortcut: settings.value.openEditorShortcut) { [weak self] in self?.openEditor() },
            QuickAction(id: "keyboardmanager.remapping", title: "Key Remapping", symbol: "keyboard.badge.ellipsis",
                        tint: .orange, shortcut: settings.value.toggleShortcut,
                        isOn: { [weak self] in self?.isRemapping ?? false },
                        detail: { [weak self] in
                            guard let self else { return "" }
                            let n = self.settings.value.remaps.filter(\.isEnabled).count
                            return "\(n) remap\(n == 1 ? "" : "s") · \(self.activeProfileName)"
                        },
                        perform: { [weak self] in self?.togglePaused() }),
        ]
    }

    var activeProfileName: String {
        let s = settings.value
        return s.profiles.isEmpty ? "Default" : s.profiles[s.activeProfileIndex].name
    }

    public var shortcutBindings: [ShortcutBinding] {
        var list = [ShortcutBinding("Open Keyboard Manager", settings.value.openEditorShortcut),
                    ShortcutBinding("Pause or resume remapping", settings.value.toggleShortcut)]
        for r in settings.value.remaps where r.isEnabled && r.kind == .shortcut {
            list.append(ShortcutBinding("Remapped: \(RemapFormatting.actionSummary(r.action))", keys: r.triggerKeycaps))
        }
        return list.filter { !$0.keys.isEmpty }
    }

    /// `mactoys://keyboardmanager/<action>`: `open`/`editor`, `pause`, `resume`, `toggle`,
    /// `profile?name=…`, `export?file=…`, `import?file=…`, `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "editor", "show":
            openEditor()
        case "pause":
            settings.value.paused = true
        case "resume":
            settings.value.paused = false
        case "toggle":
            togglePaused()
        case "profile":
            guard let name = command.parameters["name"],
                  let p = settings.value.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { return false }
            settings.value.activeProfileID = p.id
            HUD.show("Keyboard profile: \(p.name)", symbol: "keyboard")
        case "export":
            exportProfile(to: command.files.first)
        case "import":
            importProfile(from: command.files.first)
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("editor", size: CGSize(width: 760, height: 600), wallpaper: false) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(RemapEditorView(model: RemapEditorModel(module: self, preview: SampleRemaps.design),
                                           showsWindowControls: true))
        }]
    }
}
