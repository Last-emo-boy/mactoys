import AppKit
import ApplicationServices
import MacToysCore

/// The screen edge the Dock sits on.
public enum DockEdge: Equatable, Sendable {
    case bottom, left, right

    /// From the Dock window's frame and its screen's frame (top-left coordinates).
    public static func of(dock: CGRect, screen: CGRect) -> DockEdge {
        guard dock.height > dock.width else { return .bottom }
        return dock.midX < screen.midX ? .left : .right
    }

    /// A swipe away from the edge (into the screen) shows the app; toward the edge hides it.
    public func intent(for direction: SwipeDirection) -> DockIntent? {
        switch (self, direction) {
        case (.bottom, .up), (.left, .right), (.right, .left): .show
        case (.bottom, .down), (.left, .left), (.right, .right): .hide
        default: nil
        }
    }
}

public enum DockIntent: Equatable, Sendable { case show, hide }

/// An app icon in the Dock.
struct DockItem {
    let name: String
    let bundleURL: URL?
    /// The icon's frame, top-left coordinates.
    let frame: CGRect?

    /// The running instance, if any.
    var app: NSRunningApplication? {
        guard let bundleURL else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == bundleURL.standardizedFileURL }
    }

    /// The app icon under `point`, asked of the Dock through Accessibility.
    static func at(_ point: CGPoint) -> DockItem? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<4 {
            if element.role == "AXDockItem" {
                guard (element.ax(kAXSubroleAttribute) as String?) == "AXApplicationDockItem" else { return nil }
                let url: URL? = (element.ax(kAXURLAttribute) as NSURL?).map { $0 as URL }
                let name: String = element.ax(kAXTitleAttribute) ?? url?.deletingPathExtension().lastPathComponent ?? ""
                return DockItem(name: name, bundleURL: url, frame: WindowRef(element: element, pid: 0).frame)
            }
            guard let parent: AXUIElement = element.ax(kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }
}

/// What the Dock gestures do to an app.
@MainActor
enum DockActions {
    /// Unhides the app, brings back its minimized windows and activates it; launches it if needed.
    static func showWindows(_ item: DockItem) {
        guard let app = item.app else {
            if let url = item.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
            return
        }
        app.unhide()
        for w in WindowRef.windows(of: app.processIdentifier) where w.isMinimized { w.minimize(false) }
        app.activate()
    }

    /// The system's view of every window of the app, side by side.
    static func expose(_ item: DockItem) {
        guard let app = item.app else { showWindows(item); return }
        app.unhide()
        app.activate()
        let missionControl = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["2"]            // 2 = the front app's windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSWorkspace.shared.openApplication(at: missionControl, configuration: config)
        }
    }

    static func hide(_ item: DockItem) {
        item.app?.hide()
    }

    static func minimizeAll(_ item: DockItem) {
        guard let app = item.app else { return }
        for w in WindowRef.windows(of: app.processIdentifier) where w.isStandard && !w.isMinimized { w.minimize() }
    }
}
