import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Every Window Controls option (`windowcontrols.json`).
public struct WindowControlsSettings: Codable, Equatable, Sendable {
    // Zoom button palette
    public var paletteEnabled = true
    /// Seconds the pointer rests on the green button before the palette opens.
    public var hoverDelay = 0.25
    public var gridColumns = 6
    public var gridRows = 4
    public var swapGridOnPortrait = true
    /// Outline where the window will go while choosing in the palette.
    public var showPreview = true
    /// Double-clicking the green button fills the screen (and restores the size the second time).
    public var doubleClickFills = false

    // Keyboard mode
    @NullCodable public var keyboardShortcut: Shortcut? = Shortcut(kVK_ANSI_K, [.control, .option])
    /// Keep keyboard mode open after an action; otherwise it closes after each one.
    public var stayInKeyboardMode = true
    public var showCheatSheet = true
    /// Points ⌥-arrows move a window.
    public var nudgeStep = 20.0
    /// Points ⇧-arrows grow or shrink a window.
    public var resizeStep = 64.0

    // Custom controls
    public var controls: [WindowControl] = BuiltInControls.all

    // Saved layouts
    public var layouts: [SavedLayout] = []
    @NullCodable public var saveLayoutShortcut: Shortcut? = nil
    /// Restores the newest layout saved for the displays connected now.
    @NullCodable public var restoreLayoutShortcut: Shortcut? = nil
    /// Restore a layout on its own when its display arrangement appears again.
    public var autoRestoreLayouts = true
    /// Save the arrangement you had when a display goes away.
    public var autoSaveOnDisconnect = true

    // Placement
    /// Points between windows placed next to each other.
    public var gap = 8.0
    /// Points between windows and the edges of the screen.
    public var edgeMargin = 8.0
    public var bringToFront = true
    public var excludedApps: [String] = []

    public init() {}

    var spacing: Spacing { Spacing(gap: CGFloat(max(0, gap)), margin: CGFloat(max(0, edgeMargin))) }

    /// Controls numbered 1…9 in keyboard mode, in list order.
    var keyboardControls: [WindowControl] { Array(controls.filter(\.inKeyboard).prefix(9)) }

    var paletteControls: [WindowControl] { controls.filter(\.inPalette) }

    /// A control by id, or by name (case-insensitive) for URLs and the CLI.
    func control(named query: String) -> WindowControl? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: q), let c = controls.first(where: { $0.id == id }) { return c }
        return controls.first { $0.displayName == q }
            ?? controls.first { $0.displayName.caseInsensitiveCompare(q) == .orderedSame }
            ?? controls.first { $0.builtIn == q }
    }

    /// A layout by id or name (case-insensitive).
    func layout(named query: String) -> SavedLayout? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let id = UUID(uuidString: q), let l = layouts.first(where: { $0.id == id }) { return l }
        return layouts.first { $0.name == q } ?? layouts.first { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// The newest layout saved for an arrangement.
    func newestLayout(for arrangementKey: String, autoRestoreOnly: Bool = false) -> SavedLayout? {
        layouts.filter { $0.arrangementKey == arrangementKey && (!autoRestoreOnly || $0.autoRestore) }
            .max { $0.created < $1.created }
    }
}
