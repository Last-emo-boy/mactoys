import CoreGraphics
import Foundation
import MacToysCore

/// AppKit also brings in QuickDraw's `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// A display as it was when a workspace was captured.
public struct SavedDisplay: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// `NSScreen.stableID` (vendor-model-serial), stable across reconnects.
    public var id: String
    public var name: String
    /// Global top-left coordinates.
    public var frame: CGRect
    /// Frame minus menu bar and Dock, global top-left coordinates.
    public var visibleFrame: CGRect
    public var isMain: Bool

    public init(id: String, name: String, frame: CGRect, visibleFrame: CGRect, isMain: Bool) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isMain = isMain
    }
}

/// How a window is left after launching ("launch as").
public enum WindowState: String, Codable, CaseIterable, Sendable {
    case saved, minimized, fill, fullScreen, hidden

    public var title: String {
        switch self {
        case .saved: String(localized: "Saved position", comment: "Launch a window as: at its saved position")
        case .minimized: String(localized: "Minimized", comment: "Window state: minimized (a badge on a window, or how it is launched)")
        case .fill: String(localized: "Fill the screen", comment: "Launch a window as: filling the screen")
        case .fullScreen: String(localized: "Full screen", comment: "Launch a window as: in full-screen mode")
        case .hidden: String(localized: "Hidden", comment: "Launch a window as: its app hidden")
        }
    }
}

/// One window of a workspace: which app, where, and how to launch it.
public struct WorkspaceApp: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var bundleID: String?
    /// Path of the .app bundle, used when the bundle id can't be resolved.
    public var appPath: String
    /// Title at capture time; helps match windows when an app restores several.
    public var windowTitle = ""
    /// `SavedDisplay.id` of the display the window was on.
    public var displayID: String
    /// Global top-left frame at capture time (or as edited).
    public var frame: CGRect
    public var state: WindowState = .saved
    /// Command-line arguments passed when the app is launched (shell-style quoting).
    public var arguments = ""
    /// A URL, or a file or folder path, opened with the app.
    public var openTarget = ""

    public init(id: UUID = UUID(), name: String, bundleID: String?, appPath: String, windowTitle: String = "",
                displayID: String, frame: CGRect, state: WindowState = .saved, arguments: String = "", openTarget: String = "") {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.appPath = appPath
        self.windowTitle = windowTitle
        self.displayID = displayID
        self.frame = frame
        self.state = state
        self.arguments = arguments
        self.openTarget = openTarget
    }

    /// Tolerates missing keys so older or hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "App"
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        appPath = try c.decodeIfPresent(String.self, forKey: .appPath) ?? ""
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        displayID = try c.decodeIfPresent(String.self, forKey: .displayID) ?? ""
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame) ?? CGRect(x: 100, y: 100, width: 900, height: 600)
        state = try c.decodeIfPresent(WindowState.self, forKey: .state) ?? .saved
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        openTarget = try c.decodeIfPresent(String.self, forKey: .openTarget) ?? ""
    }

    /// Groups windows of the same app for launching.
    var appKey: String { bundleID ?? appPath }
}

/// A named set of app windows to restore together.
public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var apps: [WorkspaceApp]
    public var displays: [SavedDisplay]
    /// Reuse windows of apps that are already running instead of asking for new ones.
    public var moveExistingWindows = true
    public var shortcut: Shortcut?
    public var launchAtLogin = false
    public var created = Date()
    public var lastLaunched: Date?

    public init(id: UUID = UUID(), name: String, apps: [WorkspaceApp], displays: [SavedDisplay],
                moveExistingWindows: Bool = true, shortcut: Shortcut? = nil, launchAtLogin: Bool = false,
                created: Date = Date(), lastLaunched: Date? = nil) {
        self.id = id
        self.name = name
        self.apps = apps
        self.displays = displays
        self.moveExistingWindows = moveExistingWindows
        self.shortcut = shortcut
        self.launchAtLogin = launchAtLogin
        self.created = created
        self.lastLaunched = lastLaunched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Workspace"
        apps = try c.decodeIfPresent([WorkspaceApp].self, forKey: .apps) ?? []
        displays = try c.decodeIfPresent([SavedDisplay].self, forKey: .displays) ?? []
        moveExistingWindows = try c.decodeIfPresent(Bool.self, forKey: .moveExistingWindows) ?? true
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        lastLaunched = try c.decodeIfPresent(Date.self, forKey: .lastLaunched)
    }

    /// Number of distinct apps (an app with two windows counts once).
    public var appCount: Int { Set(apps.map(\.appKey)).count }

    /// 1-based display number for the editor ("Display 1"), main display first.
    public func displayNumber(of displayID: String) -> Int {
        let ordered = displays.sorted { ($0.isMain ? 0 : 1, $0.frame.minX) < ($1.isMain ? 0 : 1, $1.frame.minX) }
        return (ordered.firstIndex { $0.id == displayID } ?? 0) + 1
    }

    /// Carries launch options of matching apps over to a fresh capture (Recapture keeps them).
    public func keepingOptions(from old: Workspace) -> Workspace {
        var copy = self
        copy.id = old.id
        copy.name = old.name
        copy.moveExistingWindows = old.moveExistingWindows
        copy.shortcut = old.shortcut
        copy.launchAtLogin = old.launchAtLogin
        copy.created = old.created
        copy.lastLaunched = old.lastLaunched
        var pool = old.apps
        for i in copy.apps.indices {
            guard let j = pool.firstIndex(where: { $0.appKey == copy.apps[i].appKey }) else { continue }
            copy.apps[i].arguments = pool[j].arguments
            copy.apps[i].openTarget = pool[j].openTarget
            pool.remove(at: j)
        }
        return copy
    }
}

/// Persisted options and workspaces (`workspaces.json`).
public struct WorkspacesSettings: Codable, Equatable, Sendable {
    public var editorShortcut: Shortcut? = Shortcut(0x0D, [.control, .option])   // kVK_ANSI_W
    public var workspaces: [Workspace] = []
    /// Default of "Move existing windows" for newly captured workspaces.
    public var moveExistingByDefault = true
    /// Seconds to wait for an app's windows to appear.
    public var windowTimeout: Double = 15
    public var showProgress = true
    public var closeProgressWhenDone = true

    public init() {}
}
