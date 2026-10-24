import AppKit
import MacToysCore

/// A target for one layout: a screen, or every screen combined when zones span displays.
struct ZoneDisplay: Identifiable, Equatable {
    /// Key of the combined display used when "Allow zones to span across displays" is on.
    static let allDisplaysKey = "all-displays"

    /// `NSScreen.stableID` (deduplicated), or `allDisplaysKey`.
    let key: String
    let name: String
    /// 1-based, left to right.
    let number: Int
    /// Full frame in top-left coordinates.
    let frame: CGRect
    /// Visible frame (menu bar and Dock excluded) in top-left coordinates: where zones go.
    let workArea: CGRect
    let isBuiltIn: Bool

    var id: String { key }
    var isVertical: Bool { workArea.height > workArea.width }

    /// Current displays, left to right. With `spanning`, one display covering every screen.
    @MainActor
    static func current(spanning: Bool) -> [ZoneDisplay] {
        let screens = sortedScreens
        guard !screens.isEmpty else { return [] }
        if spanning && screens.count > 1 {
            let frame = screens.map(\.axFrame).reduce(CGRect.null) { $0.union($1) }
            let work = screens.map(\.axVisibleFrame).reduce(CGRect.null) { $0.union($1) }
            return [ZoneDisplay(key: allDisplaysKey, name: "All displays", number: 1, frame: frame,
                                workArea: work, isBuiltIn: false)]
        }
        let keys = keys(for: screens)
        return screens.enumerated().map { i, s in
            ZoneDisplay(key: keys[i], name: s.localizedName, number: i + 1, frame: s.axFrame,
                        workArea: s.axVisibleFrame, isBuiltIn: s.isBuiltIn)
        }
    }

    @MainActor
    static var sortedScreens: [NSScreen] {
        NSScreen.screens.sorted { a, b in
            a.axFrame.minX != b.axFrame.minX ? a.axFrame.minX < b.axFrame.minX : a.axFrame.minY < b.axFrame.minY
        }
    }

    /// Stable keys; identical monitors without serial numbers get their display id appended.
    @MainActor
    static func keys(for screens: [NSScreen]) -> [String] {
        let ids = screens.map(\.stableID)
        return screens.enumerated().map { i, s in
            ids.filter { $0 == ids[i] }.count > 1 ? "\(ids[i])-\(s.displayID)" : ids[i]
        }
    }

    /// Display containing a top-left point (nearest when outside all of them).
    static func containing(_ p: CGPoint, in displays: [ZoneDisplay]) -> ZoneDisplay? {
        displays.first { $0.frame.containsInclusive(p) }
            ?? displays.min { $0.frame.distance(to: p) < $1.frame.distance(to: p) }
    }

    /// Display showing most of a window frame.
    static func showing(_ rect: CGRect, in displays: [ZoneDisplay]) -> ZoneDisplay? {
        if let d = containing(rect.center, in: displays), d.frame.contains(rect.center) { return d }
        return displays.max { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area }
    }
}
