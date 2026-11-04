import AppKit
import MacToysCore
import SwiftUI

/// Clipboard History: a keyboard-first clipboard manager. ⌃⌥⇧C opens a panel (or a paste bar along the
/// bottom of the screen) with everything copied recently, pinboards and snippets; Return pastes into the
/// app you came from, ⇧Return as plain text, ⌘1…⌘9 the first nine. A paste stack pastes several copies
/// in order. Concealed copies (passwords) and excluded apps are never recorded.
///
/// URL actions: `open` (`?source=history|snippets|<pinboard name>`, `?query=`), `pause`, `resume`,
/// `toggle-pause`, `clear`, `stack` (`?on=1|0`, toggles without), `snippet?name=<name or abbreviation>`
/// (pastes it), `settings`.
@MainActor
public final class ClipboardHistoryModule: ToyModule {
    public let info = ModuleInfo(
        id: "clipboard", name: "Clipboard History",
        summary: "Search everything you copied, keep favorites on pinboards and paste it back from the keyboard.",
        symbol: "list.clipboard.fill", tint: .indigo, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["clipboard", "history", "paste", "copy", "snippets", "pinboard", "paste stack", "manager"])

    public let settings = Persisted("clipboard", default: ClipboardSettings())
    let library: ClipLibrary
    let stack = PasteStackController()
    lazy var panel = ClipboardPanelController(settings: settings, library: library, stack: stack)
    private var running = false
    private var pruneTimer: Timer?
    private var listening = false
    private let log = Log.for("clipboard")

    public init() {
        library = ClipLibrary(file: ClipLibrary.defaultFile)
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.apply()
        }
        stack.onChange = { [weak self] in
            guard let self else { return }
            self.panel.model?.stackCount = self.stack.isActive ? self.stack.stack.count : 0
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        if !listening {
            listening = true
            // Registered once: the history keeps its listeners for the app's lifetime.
            ClipboardHistory.shared.onNewItem { [weak self] item in
                guard let self, self.running else { return }
                self.stack.copied(item)
            }
        }
        ClipboardHistory.shared.retain(info.id)
        panel.start()
        apply()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardHistory.shared.prune() }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "\(info.id).")
        pruneTimer?.invalidate()
        pruneTimer = nil
        panel.stop()
        stack.stop(restore: false)
        // Hand the shared history back as Advanced Paste and Command Palette expect it.
        let history = ClipboardHistory.shared
        history.isPaused = false
        history.excludedApps = []
        history.maxAge = nil
        history.limit = 100
        history.release(info.id)
        library.flush()
        settings.flush()
    }

    private func apply() {
        let s = settings.value
        HotkeyCenter.shared.unregister(prefix: "\(info.id).")
        HotkeyCenter.shared.register("\(info.id).open", s.openShortcut) { [weak self] in self?.panel.toggle() }
        HotkeyCenter.shared.register("\(info.id).stack", s.stackShortcut) { [weak self] in self?.toggleStack() }
        HotkeyCenter.shared.register("\(info.id).pause", s.pauseShortcut) { [weak self] in self?.togglePause() }
        let history = ClipboardHistory.shared
        history.isPaused = s.paused
        history.excludedApps = s.excludedApps
        history.limit = s.maxItems
        history.maxAge = s.retention.interval
        history.prune()
        stack.restoreOriginal = s.restoreClipboardAfterStack
        panel.model?.settings = s
    }

    // MARK: Actions

    func togglePause() {
        settings.value.paused.toggle()
        if settings.value.paused {
            HUD.show("Clipboard recording paused", symbol: "pause.circle.fill")
        } else {
            HUD.show("Clipboard recording resumed", symbol: "record.circle")
        }
    }

    func toggleStack() {
        guard running else { return }
        if !stack.isActive, settings.value.paused {
            settings.value.paused = false
            HUD.show("Clipboard recording resumed", symbol: "record.circle")
        }
        stack.toggle(order: settings.value.stackOrder)
    }

    private var recordingDetail: String {
        settings.value.paused ? String(localized: "Paused · copies aren’t recorded")
            : String(localized: "\(ClipboardHistory.shared.items.count) items", comment: "Clipboard recording status: entries saved")
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "\(info.id).open", title: "Clipboard History", symbol: info.symbol, tint: info.tint,
                        shortcut: settings.value.openShortcut) { [weak self] in self?.panel.show() },
            QuickAction(id: "\(info.id).recording", title: "Clipboard Recording", symbol: "record.circle", tint: .indigo,
                        shortcut: settings.value.pauseShortcut,
                        isOn: { [weak self] in !(self?.settings.value.paused ?? true) },
                        detail: { [weak self] in self?.recordingDetail ?? "" },
                        perform: { [weak self] in self?.togglePause() }),
            QuickAction(id: "\(info.id).stack", title: "Paste Stack", symbol: "square.stack.3d.up.fill", tint: .indigo,
                        shortcut: settings.value.stackShortcut,
                        isOn: { [weak self] in self?.stack.isActive ?? false },
                        detail: { [weak self] in self?.stack.detail ?? "" },
                        perform: { [weak self] in self?.toggleStack() }),
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return [
            ShortcutBinding("Open clipboard history", s.openShortcut),
            ShortcutBinding("Paste stack on/off", s.stackShortcut),
            ShortcutBinding("Pause or resume clipboard recording", s.pauseShortcut),
        ]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show":
            guard isEnabled else { return false }
            panel.show(source: source(named: command.parameters["source"]), query: command.parameters["query"] ?? "")
            return true
        case "pause":
            guard isEnabled else { return false }
            if !settings.value.paused { togglePause() }
            return true
        case "resume":
            guard isEnabled else { return false }
            if settings.value.paused { togglePause() }
            return true
        case "toggle-pause":
            guard isEnabled else { return false }
            togglePause()
            return true
        case "clear":
            ClipboardHistory.shared.clear()
            HUD.show("Clipboard history cleared", symbol: "trash")
            return true
        case "stack":
            guard isEnabled else { return false }
            switch command.parameters["on"] {
            case "1", "true", "on": if !stack.isActive { toggleStack() }
            case "0", "false", "off": stack.stop()
            default: toggleStack()
            }
            return true
        case "snippet":
            guard isEnabled, let name = command.parameters["name"]?.lowercased(),
                  let snippet = library.snippets.first(where: { $0.abbreviation.lowercased() == name || $0.name.lowercased() == name })
            else { return false }
            panel.pasteSnippet(snippet, plain: false, copyOnly: false)
            return true
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    private func source(named name: String?) -> ClipboardPanelModel.Source? {
        guard let name = name?.lowercased(), !name.isEmpty else { return nil }
        switch name {
        case "history": return .history
        case "snippets": return .snippets
        default:
            return library.pinboards.first { $0.name.lowercased() == name || $0.id.uuidString.lowercased() == name }
                .map { .pinboard($0.id) }
        }
    }

    public func settingsView() -> AnyView {
        AnyView(ClipboardSettingsView(module: self, settings: settings, library: library))
    }

    public var previewScenes: [PreviewScene] {
        ClipboardPreviews.scenes(settings: settings.value)
    }
}
