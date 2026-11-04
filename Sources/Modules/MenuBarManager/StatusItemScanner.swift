import AppKit
import CoreGraphics
import MacToysCore

/// A status item window read from the window server: owner and bounds only (no Screen Recording,
/// no Accessibility needed).
struct StatusWindow: Equatable, Sendable, Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let ownerName: String
    /// Global top-left coordinates (x is the same as in Cocoa).
    let frame: CGRect
    let isOnScreen: Bool
}

/// A status item with what is known about it: its window, its section, and (with Accessibility)
/// its own name.
struct MenuBarItem: Identifiable, Equatable, Sendable {
    /// `MenuBarLayout.itemKey`.
    let id: String
    let window: StatusWindow
    let bundleID: String
    let appName: String
    var section: MenuBarSection
    /// The item's accessibility title, description or help, when Accessibility is on.
    var name: String?
    /// The item's accessibility identifier (Apple's items: "com.apple.menuextra.wifi"…).
    var identifier: String?

    var pid: pid_t { window.pid }
    var frame: CGRect { window.frame }
    var title: String { name ?? appName }
}

/// Reads the status item windows (window layer `kCGStatusWindowLevel`) and menus that are open.
enum StatusItemScanner {
    static let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
    static let popUpMenuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
    static let mainMenuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))

    /// Every status item window, including the ones pushed off the screen, left to right.
    static func windows(onScreenOnly: Bool = false) -> [StatusWindow] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly] : [.optionAll]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var result: [StatusWindow] = []
        for d in list {
            guard let layer = d[kCGWindowLayer as String] as? Int, layer == statusLayer,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 0, bounds.height > 0, bounds.height <= 80 else { continue }
            result.append(StatusWindow(id: id, pid: pid, ownerName: d[kCGWindowOwnerName as String] as? String ?? "",
                                       frame: bounds, isOnScreen: d[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        return result.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Whether a menu, popover or panel opened from the menu bar is up: a pop-up menu window, or a
    /// taller window at a status or menu level hanging from the top of a display.
    static func menuIsOpen(excluding own: Set<CGWindowID>) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        let tops = NSScreen.screens.map(\.axFrame.minY)
        for d in list {
            guard let layer = d[kCGWindowLayer as String] as? Int,
                  let id = d[kCGWindowNumber as String] as? CGWindowID, !own.contains(id),
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if layer == popUpMenuLayer && bounds.height > 12 { return true }
            if layer >= mainMenuLayer && layer < popUpMenuLayer && bounds.height > 60,
               tops.contains(where: { abs(bounds.minY - $0) < 70 }) { return true }
        }
        return false
    }

    /// Builds items from windows: own control items left out, sections assigned, keys made.
    static func items(from windows: [StatusWindow], controls: ControlFrames, ownControlIDs: Set<CGWindowID>) -> [MenuBarItem] {
        let others = windows.filter { !ownControlIDs.contains($0.id) }
        var ordinal: [pid_t: Int] = [:]
        var built: [MenuBarItem] = []
        // Ordinals count from the right, where an app's first item usually sits.
        for w in others.reversed() {
            let app = NSRunningApplication(processIdentifier: w.pid)
            let bundleID = app?.bundleIdentifier ?? w.ownerName
            let n = ordinal[w.pid, default: 0]
            ordinal[w.pid] = n + 1
            built.append(MenuBarItem(id: MenuBarLayout.itemKey(bundleID: bundleID, ordinalFromRight: n), window: w,
                                     bundleID: bundleID, appName: app?.localizedName ?? w.ownerName,
                                     section: MenuBarLayout.section(of: w.frame, controls: controls)))
        }
        return built.reversed()
    }
}
