import AppKit
import MacToysCore

/// Reads the current desktop: displays, and every standard window of regular apps on the
/// current Space (plus minimized ones), front to back.
@MainActor
enum WorkspaceCapture {
    static func displays() -> [SavedDisplay] {
        let primary = NSScreen.screens.first
        return NSScreen.screens.map {
            SavedDisplay(id: $0.stableID, name: $0.localizedName, frame: $0.axFrame, visibleFrame: $0.axVisibleFrame,
                         isMain: $0 == primary)
        }
    }

    static func geometries() -> [DisplayGeometry] {
        displays().map { DisplayGeometry(id: $0.id, frame: $0.frame, visibleFrame: $0.visibleFrame, isMain: $0.isMain) }
    }

    /// A window found on screen, before it becomes part of a workspace.
    struct FoundWindow: Equatable {
        var id: CGWindowID
        var appName: String
        var bundleID: String?
        var appPath: String
        var title: String
        var frame: CGRect
        var isMinimized = false
        var isFullScreen = false
        var isAppHidden = false
    }

    /// A new workspace holding what's open now.
    static func capture(name: String, moveExisting: Bool) -> Workspace {
        let own = ProcessInfo.processInfo.processIdentifier
        var found: [FoundWindow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != own {
            guard let url = app.bundleURL else { continue }
            let appName = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            for window in standardWindows(of: app.processIdentifier) {
                guard let id = window.windowID, let frame = window.frame else { continue }
                found.append(FoundWindow(id: id, appName: appName, bundleID: app.bundleIdentifier, appPath: url.path,
                                         title: window.title ?? "", frame: frame, isMinimized: window.isMinimized,
                                         isFullScreen: window.isFullScreen, isAppHidden: app.isHidden))
            }
        }
        return assemble(name: name, windows: found, displays: displays(), zOrder: WindowInfo.onScreen().map(\.id),
                        moveExisting: moveExisting)
    }

    /// Turns found windows into a workspace: drops tiny windows, records each window's display
    /// and state, and orders them front to back.
    nonisolated static func assemble(name: String, windows: [FoundWindow], displays: [SavedDisplay], zOrder: [CGWindowID],
                         moveExisting: Bool) -> Workspace {
        let usable = windows.filter { $0.frame.width >= 80 && $0.frame.height >= 60 }
        let ordered = WindowOrder.frontToBack(usable, id: { $0.id }, zOrder: zOrder)
        let apps = ordered.map { w in
            let state: WindowState = w.isAppHidden ? .hidden : w.isMinimized ? .minimized : w.isFullScreen ? .fullScreen : .saved
            let display = DisplayMapper.display(for: w.frame, among: displays) ?? displays.first
            return WorkspaceApp(name: w.appName, bundleID: w.bundleID, appPath: w.appPath, windowTitle: w.title,
                                displayID: display?.id ?? "", frame: w.frame, state: state)
        }
        return Workspace(name: name, apps: apps, displays: displays, moveExistingWindows: moveExisting)
    }

    /// Standard windows of an app, with short AX timeouts so a hung app can't stall the UI.
    static func standardWindows(of pid: pid_t) -> [WindowRef] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        let elements: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
        return elements.compactMap { element in
            AXUIElementSetMessagingTimeout(element, 0.5)
            let ref = WindowRef(element: element, pid: pid)
            return ref.isStandard ? ref : nil
        }
    }
}

/// Window-server stacking order helpers.
enum WindowOrder {
    /// Sorts by position in `zOrder` (front first); items not in it keep their order at the end.
    static func frontToBack<T>(_ items: [T], id: (T) -> CGWindowID, zOrder: [CGWindowID]) -> [T] {
        var rank: [CGWindowID: Int] = [:]
        for (i, wid) in zOrder.enumerated() where rank[wid] == nil { rank[wid] = i }
        return items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
