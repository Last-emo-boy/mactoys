import AppKit
import MacToysCore
import SwiftUI

/// The optional tint behind the menu bar: one click-through panel per display that shows a menu
/// bar, just below the menu bar's own window level so the menus and icons stay on top. It isn't
/// shown on full-screen Spaces (no full-screen auxiliary behavior), nor on displays whose menu bar
/// hides itself; Reduce Transparency makes the colors solid.
@MainActor
final class MenuBarBackdrop {
    private var panels: [CGDirectDisplayID: OverlayPanel] = [:]
    private var appearance: MenuBarAppearance?

    static let shadowPad: CGFloat = 10
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)

    var windowIDs: Set<CGWindowID> { Set(panels.values.map { CGWindowID($0.windowNumber) }) }

    /// Shows, updates or removes the panels for `appearance` (nil or disabled removes them).
    func update(_ appearance: MenuBarAppearance?) {
        guard let appearance, appearance.enabled else {
            tearDown()
            return
        }
        self.appearance = appearance
        let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        var seen: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            let barHeight = screen.frame.maxY - screen.visibleFrame.maxY
            guard barHeight > 0 else { continue }
            let id = screen.displayID
            seen.insert(id)
            let frame = CGRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight - Self.shadowPad,
                               width: screen.frame.width, height: barHeight + Self.shadowPad)
            let bar = MenuBarGeometry.bar(for: screen)
            let notch = bar.notch.map { ($0.lowerBound - screen.frame.minX)...($0.upperBound - screen.frame.minX) }
            let panel = panels[id] ?? makePanel(frame)
            panel.setFrame(frame, display: false)
            // The camera housing must not inset the drawing on notched displays.
            panel.setContent(BackdropShapeView(appearance: appearance, notch: notch, solid: solid, highContrast: contrast,
                                               shadowPad: Self.shadowPad).ignoresSafeArea())
            panel.orderFrontRegardless()
            panels[id] = panel
        }
        for (id, panel) in panels where !seen.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
    }

    /// Re-lays out for the current displays and accessibility options.
    func refresh() { update(appearance) }

    func tearDown() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        appearance = nil
    }

    private func makePanel(_ frame: CGRect) -> OverlayPanel {
        let panel = OverlayPanel(frame: frame, interactive: false, acceptsKey: false, level: Self.level)
        // Every Space, but not full-screen ones (their menu bar slides in over the app).
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }
}

/// Display geometry for Menu Bar Manager.
@MainActor
enum MenuBarGeometry {
    /// Height of a display's menu bar (also when it hides itself, for hit testing).
    static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        if inset > 0 { return inset }
        return max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    }

    static func bar(for screen: NSScreen) -> BarGeometry {
        BarGeometry.make(frame: screen.frame, menuBarHeight: menuBarHeight(screen),
                         topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea)
    }

    /// The menu bar strip of a display, Cocoa coordinates.
    static func strip(for screen: NSScreen) -> CGRect {
        let h = menuBarHeight(screen)
        return CGRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    static var anyNotch: Bool { NSScreen.screens.contains { bar(for: $0).notch != nil } }
}
