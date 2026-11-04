import Carbon.HIToolbox
import Foundation
import MacToysCore

/// A display's layout choice.
public struct DisplayLayout: Codable, Equatable, Sendable {
    public var kind: TileLayoutKind = .grid
    public var main: MainSize = .half

    public init(kind: TileLayoutKind = .grid, main: MainSize = .half) {
        self.kind = kind
        self.main = main
    }
}

/// How tiled windows are marked.
public enum HighlightStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, activeBorder, allBorders, glow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: String(localized: "None", comment: "Auto Tiling highlight style: no highlight")
        case .activeBorder: String(localized: "Active border", comment: "Auto Tiling highlight style: a border around the focused window")
        case .allBorders: String(localized: "All borders", comment: "Auto Tiling highlight style: a border around every tiled window")
        case .glow: String(localized: "Glow", comment: "Auto Tiling highlight style: a soft glow around the focused window")
        }
    }
}

/// Every Auto Tiling option.
public struct AutoTilingSettings: Codable, Equatable, Sendable {
    // Tiling
    public var paused = false
    /// Windows per display, 1–4 (ultrawide displays take a fifth at 4).
    public var maxWindows = 4
    public var stackWhenFull = true

    // Layouts
    /// Display key → layout.
    public var layouts: [String: DisplayLayout] = [:]
    /// Used by displays without a choice of their own.
    public var defaultLayout = DisplayLayout()

    // Appearance
    /// Points between windows and to the display edges.
    public var gap = 8.0
    public var reserve = EdgeReserve()
    public var highlight: HighlightStyle = .activeBorder
    public var highlightUsesAccent = true
    public var highlightColor = RGBA(hex: "#0A84FF") ?? .accent

    // Mouse
    public var dragToSwap = true
    public var quickActionsAboveWindows = true
    public var focusFollowsMouse = false
    /// Milliseconds the pointer rests on a window before it's activated.
    public var focusDelay = 250.0

    // Focus modes
    /// 0.3…0.9: how dark No peek makes the other windows.
    public var noPeekDarkness = 0.6
    public var noPeekBlur = false

    // Keyboard
    public var keyboardShortcuts = true
    @NullCodable public var gridShortcut: Shortcut? = Shortcut(kVK_ANSI_1, [.control, .option, .command])
    @NullCodable public var columnsShortcut: Shortcut? = Shortcut(kVK_ANSI_2, [.control, .option, .command])
    @NullCodable public var rowsShortcut: Shortcut? = Shortcut(kVK_ANSI_3, [.control, .option, .command])
    @NullCodable public var sideShortcut: Shortcut? = Shortcut(kVK_ANSI_4, [.control, .option, .command])
    @NullCodable public var swapLeft: Shortcut? = Shortcut(kVK_LeftArrow, [.control, .option, .command])
    @NullCodable public var swapRight: Shortcut? = Shortcut(kVK_RightArrow, [.control, .option, .command])
    @NullCodable public var swapUp: Shortcut? = Shortcut(kVK_UpArrow, [.control, .option, .command])
    @NullCodable public var swapDown: Shortcut? = Shortcut(kVK_DownArrow, [.control, .option, .command])
    @NullCodable public var pauseShortcut: Shortcut? = Shortcut(kVK_ANSI_T, [.control, .option, .command])
    @NullCodable public var makeMainShortcut: Shortcut? = Shortcut(kVK_Return, [.control, .option, .command])
    @NullCodable public var nextInStackShortcut: Shortcut? = nil
    @NullCodable public var previousInStackShortcut: Shortcut? = nil
    @NullCodable public var floatShortcut: Shortcut? = nil
    @NullCodable public var sendToDisplayShortcut: Shortcut? = nil
    @NullCodable public var focusModeShortcut: Shortcut? = nil
    @NullCodable public var noPeekShortcut: Shortcut? = nil
    @NullCodable public var cleanSpaceShortcut: Shortcut? = nil
    /// Hold its modifiers and press its key repeatedly; release to switch.
    @NullCodable public var tabViewShortcut: Shortcut? = nil

    // Apps
    /// Apps that are never tiled (names or bundle identifiers).
    public var excludedApps: [String] = []

    public init() {}

    public func layout(for display: String) -> DisplayLayout { layouts[display] ?? defaultLayout }

    public func layoutShortcut(_ kind: TileLayoutKind) -> Shortcut? {
        switch kind {
        case .grid: gridShortcut
        case .columns: columnsShortcut
        case .rows: rowsShortcut
        case .side: sideShortcut
        }
    }

    public func swapShortcut(_ d: TileDirection) -> Shortcut? {
        switch d {
        case .left: swapLeft
        case .right: swapRight
        case .up: swapUp
        case .down: swapDown
        }
    }

    /// Whole points, 0…48.
    public var gapPoints: CGFloat { CGFloat(min(max(gap, 0), 48).rounded()) }
}

/// The smallest size an app's windows accept, learned by asking for less.
public struct LearnedSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var size: CGSize { CGSize(width: width, height: height) }
}
