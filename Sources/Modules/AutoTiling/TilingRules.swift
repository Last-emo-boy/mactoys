import CoreGraphics
import Foundation

/// What Auto Tiling needs to know about a window to decide whether to tile it.
public struct WindowTraits: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var isResizable: Bool
    public var isFullScreen: Bool
    public var isMinimized: Bool
    public var size: CGSize
    public var bundleID: String?
    public var appName: String
    /// The window belongs to MacToys.
    public var isOwnApp: Bool

    public init(role: String?, subrole: String?, isResizable: Bool, isFullScreen: Bool = false, isMinimized: Bool = false,
                size: CGSize, bundleID: String?, appName: String, isOwnApp: Bool = false) {
        self.role = role
        self.subrole = subrole
        self.isResizable = isResizable
        self.isFullScreen = isFullScreen
        self.isMinimized = isMinimized
        self.size = size
        self.bundleID = bundleID
        self.appName = appName
        self.isOwnApp = isOwnApp
    }
}

/// The rules for which windows are tiled.
public enum TileEligibility: Equatable, Sendable {
    case tile
    /// Never tiled: dialogs, sheets, panels, popovers, fixed-size and MacToys' own windows.
    case never
    /// Not now: full screen or minimized; it may be tiled when that changes.
    case notNow
    /// The user doesn't tile this app.
    case optedOut

    public static func evaluate(_ w: WindowTraits, excludedApps: [String]) -> TileEligibility {
        guard !w.isOwnApp, w.role == "AXWindow", w.subrole == "AXStandardWindow", w.isResizable else { return .never }
        guard w.size.width >= 40, w.size.height >= 40 else { return .never }
        if w.isFullScreen || w.isMinimized { return .notNow }
        if AppList.contains(excludedApps, bundleID: w.bundleID, name: w.appName) { return .optedOut }
        return .tile
    }
}

/// Matching apps against a user list of names and bundle identifiers (like Core's excluded-apps
/// lists: a bundle id matches exactly, a name entry matches app names containing it,
/// case-insensitively).
public enum AppList {
    public static func contains(_ list: [String], bundleID: String?, name: String) -> Bool {
        let bid = bundleID?.lowercased() ?? ""
        let n = name.lowercased()
        return list.contains { entry in
            let e = entry.trimmingCharacters(in: .whitespaces).lowercased()
            guard !e.isEmpty else { return false }
            return e == bid || (!n.isEmpty && n.contains(e))
        }
    }

    /// The list without any entry that matches the app (to tile it again).
    public static func removing(_ list: [String], bundleID: String?, name: String) -> [String] {
        list.filter { !contains([$0], bundleID: bundleID, name: name) }
    }
}

/// Window corner radii on macOS 26: windows with a toolbar are rounder than title-bar-only ones.
public enum WindowCorners {
    public static let toolbarRadius: CGFloat = 26
    public static let titlebarRadius: CGFloat = 16

    public static func radius(hasToolbar: Bool) -> CGFloat { hasToolbar ? toolbarRadius : titlebarRadius }
}

/// Stage Manager state, from the `GloballyEnabled` key of `com.apple.WindowManager`.
public enum StageManagerState {
    /// Interprets the preference value (a number, boolean or string).
    public static func isEnabled(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["1", "true", "yes"].contains(s.lowercased())
        default: return false
        }
    }
}

/// A request from a URL (`mactoys://autotile/<action>?…`), the CLI or a quick action.
public enum TilingCommand: Equatable, Sendable {
    case pause, resume, togglePause, retile
    case layout(TileLayoutKind, display: Int?)
    case makeMain, toggleFloat, sendToNextDisplay
    case swap(TileDirection)
    case cycleStack(forward: Bool)
    case focusMode, noPeek, cleanSpace, tabView
    case settings

    public static func parse(action: String, parameters: [String: String]) -> TilingCommand? {
        switch action.lowercased() {
        case "pause": return .pause
        case "resume": return .resume
        case "toggle": return .togglePause
        case "retile": return .retile
        case "make-main", "main": return .makeMain
        case "float", "toggle-float": return .toggleFloat
        case "send-to-display", "next-display": return .sendToNextDisplay
        case "next-in-stack", "cycle-stack": return .cycleStack(forward: true)
        case "previous-in-stack": return .cycleStack(forward: false)
        case "focus", "focus-mode": return .focusMode
        case "no-peek": return .noPeek
        case "clean-space": return .cleanSpace
        case "tab-view", "windows": return .tabView
        case "open", "settings", "show": return .settings
        case "layout":
            guard let raw = parameters["kind"] ?? parameters["layout"],
                  let kind = TileLayoutKind(rawValue: raw.lowercased()) else { return nil }
            let display = parameters["display"].flatMap { Int($0) }
            if let display, display < 1 { return nil }
            return .layout(kind, display: display)
        case "swap", "move":
            guard let raw = parameters["dir"] ?? parameters["direction"],
                  let d = TileDirection(rawValue: raw.lowercased()) else { return nil }
            return .swap(d)
        default:
            return nil
        }
    }
}
