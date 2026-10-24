import MacToysCore
import PreviewKit
import SwiftUI

/// Peek: a keyboard-driven preview window for the Finder selection.
///
/// ⌃⌥P previews the selected items (or, with one file selected in Finder, steps through its
/// folder). Markdown, code, JSON/XML, CSV, SQLite, SVG, G-code, STL, QOI and folders are rendered by
/// PreviewKit; everything else by Quick Look's own previewer.
@MainActor
public final class PeekModule: ToyModule {
    public let info = ModuleInfo(
        id: "peek", name: "Peek",
        summary: "Preview files in a quick, keyboard-driven window without opening an app.",
        symbol: "eye.fill", tint: .cyan, category: .fileManagement,
        permissions: [.automation], enabledByDefault: true,
        keywords: ["quick look", "preview", "space", "viewer", "file preview"])

    let settings = Persisted("peek", default: PeekSettings())
    private lazy var controller = PeekController(settings: settings)
    private var running = false
    private static let hotkeyID = "peek.activate"

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.registerHotkey()
            self.controller.applySettings()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        controller.close()
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.activation) { [weak self] in
            self?.peekAtFinderSelection()
        }
    }

    /// The hotkey: toggles Peek for the Finder selection.
    func peekAtFinderSelection() {
        if controller.isVisible { controller.close(); return }
        guard PermissionCenter.shared.isGranted(.automation) else {
            HUD.show("Automation permission needed", symbol: "exclamationmark.shield")
            PermissionCenter.shared.request(.automation)
            return
        }
        let finderFront = FinderSelection.finderIsFrontmost
        let selection = PeekItems.existing(FinderSelection.selectedURLs())
        guard !selection.isEmpty else {
            HUD.show("Select a file in Finder to peek at it", symbol: "eye")
            return
        }
        if selection.count == 1, finderFront, settings.value.browseFolder {
            controller.show(PeekItems.siblings(of: selection[0]))
        } else {
            controller.show(PeekItems(selection))
        }
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "peek.selection", title: "Peek", symbol: "eye.fill", tint: .cyan,
                     shortcut: settings.value.activation) { [weak self] in self?.peekAtFinderSelection() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Peek at the Finder selection", settings.value.activation),
         ShortcutBinding("Previous / next file", keys: ["←", "→"]),
         ShortcutBinding("Previous / next file from inside a preview", keys: ["⌥", "←", "→"]),
         ShortcutBinding("Open with the default app", keys: ["⌘", "↩"]),
         ShortcutBinding("Copy the file", keys: ["⌘", "C"]),
         ShortcutBinding("Move to Trash", keys: ["⌫"]),
         ShortcutBinding("Close Peek", keys: ["Space"])]
    }

    /// `mactoys://peek/<action>`:
    /// - `open` with `file=` paths: preview those (Services, Finder extension, CLI). One file plus
    ///   `folder=1` steps through its folder. Without files: the Finder selection.
    /// - `selection` / `show` / `toggle`: the hotkey's behavior. `close`: closes the window.
    public func handle(_ command: AppCommand) -> Bool {
        if ["open", "preview", "selection", "show", "toggle"].contains(command.action), !isEnabled {
            HUD.show("Peek is turned off in MacToys settings", symbol: "eye.slash")
            return true
        }
        switch command.action {
        case "open", "preview":
            let files = PeekItems.existing(command.files)
            if command.files.isEmpty { peekAtFinderSelection(); return true }
            guard !files.isEmpty else {
                HUD.show("Nothing to preview: the file doesn't exist", symbol: "eye.slash")
                return true
            }
            let wantsFolder = ["1", "true", "yes"].contains(command.parameters["folder"]?.lowercased() ?? "")
            controller.show(files.count == 1 && wantsFolder ? PeekItems.siblings(of: files[0]) : PeekItems(files))
        case "selection", "show", "toggle":
            peekAtFinderSelection()
        case "close", "hide":
            controller.close()
        default:
            return false
        }
        return true
    }

    public func settingsView() -> AnyView {
        AnyView(PeekSettingsView(module: self))
    }

    public var previewScenes: [PreviewScene] { PeekScenes.all }
}
