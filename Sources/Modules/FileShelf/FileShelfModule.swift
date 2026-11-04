import AppKit
import MacToysCore
import SwiftUI

/// File Shelf: a floating shelf that holds files, text, images and links while you move between
/// apps. Shake the pointer while dragging to open one (or press ⌃⌥S), drop things on it, then drag
/// them all out at once wherever they need to go.
@MainActor
public final class FileShelfModule: ToyModule {
    public let info = ModuleInfo(
        id: "shelf", name: "File Shelf",
        summary: "Hold files, text and links on a floating shelf while you switch apps, then drag them out together.",
        symbol: "tray.full.fill", tint: .teal, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["shelf", "drag", "drop", "stash", "files", "shake", "holding area", "basket", "clipboard"])

    let settings = Persisted("shelf", default: ShelfSettings())
    lazy var manager = ShelfManager(settings: settings)
    private let watcher = DragWatcher()
    private var running = false

    private enum HotkeyID {
        static let new = "shelf.new"
        static let clipboard = "shelf.clipboard"
        static let reopen = "shelf.reopen"
    }

    public init() {
        watcher.onShake = { [weak self] point in self?.manager.shakeDetected(at: point) }
        watcher.shouldOpen = { [weak self] in
            guard let self else { return false }
            return !self.settings.value.excludedApps.matches(app: NSWorkspace.shared.frontmostApplication)
        }
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.apply()
            self.manager.applySettings()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        apply()
        manager.start()
    }

    public func stop() {
        guard running else { return }
        running = false
        watcher.stop()
        for id in [HotkeyID.new, HotkeyID.clipboard, HotkeyID.reopen] { HotkeyCenter.shared.unregister(id) }
        manager.stop()
        settings.flush()
    }

    /// Hotkeys and the shake watcher, from the current settings.
    private func apply() {
        let s = settings.value
        HotkeyCenter.shared.register(HotkeyID.new, s.newShelfShortcut) { [weak self] in self?.manager.newShelf() }
        HotkeyCenter.shared.register(HotkeyID.clipboard, s.clipboardShortcut) { [weak self] in self?.manager.newShelfFromClipboard() }
        HotkeyCenter.shared.register(HotkeyID.reopen, s.reopenShortcut) { [weak self] in self?.manager.reopen() }
        if s.shakeToOpen { watcher.start(sensitivity: s.shakeSensitivity) } else { watcher.stop() }
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "shelf.new", title: "New Shelf", symbol: "tray.and.arrow.down.fill", tint: .teal,
                        shortcut: settings.value.newShelfShortcut) { [weak self] in self?.perform { $0.newShelf() } },
            QuickAction(id: "shelf.clipboard", title: "Shelf from Clipboard", symbol: "doc.on.clipboard.fill", tint: .teal,
                        shortcut: settings.value.clipboardShortcut) { [weak self] in self?.perform { $0.newShelfFromClipboard() } },
            QuickAction(id: "shelf.reopen", title: "Reopen Last Shelf", symbol: "clock.arrow.circlepath", tint: .teal,
                        shortcut: settings.value.reopenShortcut) { [weak self] in self?.perform { $0.reopen() } },
            QuickAction(id: "shelf.shake", title: "Shake to Open Shelf", symbol: "hand.draw.fill", tint: .teal,
                        isOn: { [weak self] in self?.settings.value.shakeToOpen ?? false },
                        detail: { [weak self] in
                            guard let s = self?.settings.value else { return "" }
                            return String(localized: "Sensitivity: \(s.shakeSensitivity.title)", comment: "Menu bar switch detail; the placeholder is Low, Medium or High")
                        }) { [weak self] in self?.settings.value.shakeToOpen.toggle() },
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [
            ShortcutBinding("New shelf", settings.value.newShelfShortcut),
            ShortcutBinding("New shelf from the clipboard", settings.value.clipboardShortcut),
            ShortcutBinding("Reopen the last closed shelf", settings.value.reopenShortcut),
            ShortcutBinding("Open a shelf while dragging", keys: [String(localized: "Shake", comment: "Keycap-style label: shake the pointer")]),
            ShortcutBinding("Quick Look the selected items", keys: ["Space"]),
            ShortcutBinding("Copy the items", keys: ["⌘", "C"]),
            ShortcutBinding("Paste into the shelf", keys: ["⌘", "V"]),
            ShortcutBinding("Remove the selection from the shelf", keys: ["⌫"]),
            ShortcutBinding("Close the shelf", keys: ["⌘", "W"]),
            ShortcutBinding("Keep the shelf open when dragging everything out", keys: [String(localized: "Hold", comment: "Keycap-style label: hold a key"), "⇧"]),
        ]
    }

    /// `mactoys://shelf/<action>`:
    /// - `new` (also `open`, the default): a new shelf at the pointer, holding any `file=` paths,
    ///   `text=` and `url=` values.
    /// - `add`: adds `file=` paths (and `text=`/`url=`) to the shelf used last, or a new one. This is
    ///   the Finder Services action ("Add to Shelf", `NSUserData` = `shelf/add`).
    /// - `clipboard`: a new shelf with what's on the clipboard.
    /// - `reopen` (`recent`): reopens the last closed shelf, or `index=N` from the recent list (0 = newest).
    /// - `close-all`: closes every shelf (they go to the recent list).
    public func handle(_ command: AppCommand) -> Bool {
        let known = ["new", "open", "add", "clipboard", "reopen", "recent", "close-all"]
        guard known.contains(command.action) else { return false }
        guard isEnabled, running else {
            HUD.show("File Shelf is turned off in MacToys settings", symbol: "tray.full")
            return true
        }
        var drops = command.files.map { ShelfDrop.file($0.standardizedFileURL) }
            .filter { if case .file(let url) = $0 { FileManager.default.fileExists(atPath: url.path) } else { true } }
        if let text = command.parameters["text"], !text.isEmpty { drops.append(.text(text)) }
        if let s = command.parameters["url"], let url = URL(string: s), url.scheme != nil { drops.append(.link(url, title: nil)) }
        switch command.action {
        case "new", "open":
            manager.newShelf(with: drops)
        case "add":
            guard !drops.isEmpty else {
                HUD.show("Nothing to add to the shelf", symbol: "tray")
                return true
            }
            manager.addToCurrentShelf(drops)
        case "clipboard":
            manager.newShelfFromClipboard()
        case "reopen", "recent":
            let index = command.parameters["index"].flatMap(Int.init)
            let id = index.flatMap { manager.recent.indices.contains($0) ? manager.recent[$0].id : nil }
            manager.reopen(id)
        case "close-all":
            manager.closeAll()
        default:
            return false
        }
        return true
    }

    /// Runs a quick action, or explains why it can't (module turned off).
    private func perform(_ action: (ShelfManager) -> Void) {
        guard running else {
            HUD.show("File Shelf is turned off in MacToys settings", symbol: "tray.full")
            return
        }
        action(manager)
    }

    public func settingsView() -> AnyView {
        AnyView(ShelfSettingsView(module: self))
    }

    public var previewScenes: [PreviewScene] { ShelfScenes.all }
}
