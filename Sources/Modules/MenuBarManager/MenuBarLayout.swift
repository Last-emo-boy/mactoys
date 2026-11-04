import CoreGraphics
import Foundation

/// Which part of the menu bar an item sits in, judged by its position relative to the dividers.
enum MenuBarSection: String, Codable, CaseIterable, Sendable {
    /// Right of the hidden divider: always shown.
    case visible
    /// Between the two dividers: shown on demand.
    case hidden
    /// Left of the always-hidden divider: shown only on request (⌥-click, the bar, search).
    case alwaysHidden

    var title: String {
        switch self {
        case .visible: String(localized: "Shown", comment: "Menu Bar Manager section: icons that are always in the menu bar")
        case .hidden: String(localized: "Hidden", comment: "Menu Bar Manager section: icons shown on demand")
        case .alwaysHidden: String(localized: "Always hidden", comment: "Menu Bar Manager section: icons only shown on request")
        }
    }
}

/// One display's menu bar: its horizontal extent, its height and, on Macs with a camera housing,
/// the x-range the notch covers. All x values are global, which is the same in Cocoa and in
/// Accessibility / CGWindowList coordinates (only y is flipped between them).
struct BarGeometry: Equatable, Sendable {
    var minX: CGFloat
    var maxX: CGFloat
    var height: CGFloat
    var notch: ClosedRange<CGFloat>?

    var width: CGFloat { maxX - minX }

    /// Room status items can use: from the notch's right edge (or the screen's left edge) to the right edge.
    var statusRoom: CGFloat { maxX - (notch?.upperBound ?? minX) }

    /// - Parameters:
    ///   - frame: the screen's frame (global coordinates).
    ///   - topLeftArea, topRightArea: `NSScreen.auxiliaryTopLeftArea`/`…RightArea`, the unobscured
    ///     parts beside the camera housing. They're accepted in global or in screen-local coordinates
    ///     (a screen at a negative x tells them apart).
    static func make(frame: CGRect, menuBarHeight: CGFloat, topLeftArea: CGRect?, topRightArea: CGRect?) -> BarGeometry {
        var notch: ClosedRange<CGFloat>?
        if var left = topLeftArea, var right = topRightArea, left.width > 0, right.width > 0 {
            let isGlobal = left.minX >= frame.minX - 0.5 && right.maxX <= frame.maxX + 0.5
            if !isGlobal {
                left.origin.x += frame.minX
                right.origin.x += frame.minX
            }
            if right.minX - left.maxX > 1 { notch = left.maxX...right.minX }
        }
        return BarGeometry(minX: frame.minX, maxX: frame.maxX, height: menuBarHeight, notch: notch)
    }
}

/// The x extents of Menu Bar Manager's own status items (global coordinates).
struct ControlFrames: Equatable, Sendable {
    var chevron: CGRect?
    var hidden: CGRect?
    var alwaysHidden: CGRect?
}

/// Something about the order of the control items that would hide the wrong things.
enum OrderProblem: Equatable, Sendable {
    /// The chevron sits left of the hidden divider: hiding would push the chevron off screen too.
    case chevronLeftOfDivider
    /// The always-hidden divider sits right of the hidden divider: it would push everything off screen.
    case alwaysHiddenRightOfDivider
}

/// Pure geometry of the spacer technique: a divider status item whose length grows until every
/// item to its left is pushed off the screen.
enum MenuBarLayout {
    /// Length of a collapsed divider: wide enough to push items off the widest display, twice over.
    static func collapsedLength(screenWidths: [CGFloat]) -> CGFloat {
        max(10_000, (screenWidths.max() ?? 0) * 2)
    }

    /// Length of a divider while its section is shown.
    static func expandedLength(style: DividerStyle, arranging: Bool) -> CGFloat {
        switch style {
        case .line: 14
        case .dots: 14
        case .none: arranging ? 14 : 0
        }
    }

    /// Which section a status item belongs to, from where it is relative to the dividers. Works the
    /// same while a divider is collapsed (its frame then reaches far to the left).
    static func section(of frame: CGRect, controls: ControlFrames) -> MenuBarSection {
        guard let hidden = controls.hidden else { return .visible }
        if frame.midX >= hidden.maxX - 0.5 { return .visible }
        if let ah = controls.alwaysHidden, frame.midX <= ah.maxX + 0.5 { return .alwaysHidden }
        return .hidden
    }

    /// Checks the control items' order before collapsing, so hiding never takes the chevron along.
    static func orderProblems(_ c: ControlFrames) -> [OrderProblem] {
        guard let hidden = c.hidden else { return [] }
        var problems: [OrderProblem] = []
        if let chevron = c.chevron, chevron.maxX < hidden.maxX - 0.5 { problems.append(.chevronLeftOfDivider) }
        if let ah = c.alwaysHidden, ah.maxX > hidden.maxX + 0.5 { problems.append(.alwaysHiddenRightOfDivider) }
        return problems
    }

    /// How many hidden items would fit when the hidden section is shown in place.
    /// - Parameters:
    ///   - room: width available for status items (`BarGeometry.statusRoom`).
    ///   - visibleWidths: widths of everything already shown (system items, the chevron, dividers…).
    ///   - hiddenWidths: widths of the hidden items, nearest the divider first (right to left), the
    ///     order in which they'd come back.
    ///   - margin: space kept free next to the notch or the app menus.
    static func fittingCount(room: CGFloat, visibleWidths: [CGFloat], hiddenWidths: [CGFloat], margin: CGFloat = 8) -> Int {
        var free = room - margin - visibleWidths.reduce(0, +)
        var count = 0
        for w in hiddenWidths {
            free -= w
            guard free >= 0 else { break }
            count += 1
        }
        return count
    }

    /// Items (right to left) that don't fit into `room`: their indices, the ones macOS loses under
    /// the notch.
    static func overflowing(room: CGFloat, widths: [CGFloat], margin: CGFloat = 0) -> [Int] {
        var used: CGFloat = 0
        var lost: [Int] = []
        for (i, w) in widths.enumerated() {
            used += w
            if used > room - margin + 0.5 { lost.append(i) }
        }
        return lost
    }

    /// Whether the hidden items would land under the notch if shown in place.
    static func isCrowded(bar: BarGeometry, visibleWidths: [CGFloat], hiddenWidths: [CGFloat]) -> Bool {
        guard bar.notch != nil else { return false }
        return fittingCount(room: bar.statusRoom, visibleWidths: visibleWidths, hiddenWidths: hiddenWidths) < hiddenWidths.count
    }

    /// Visible items currently covered by the notch: on its display, left of the notch's right edge.
    static func underNotch(_ frames: [CGRect], bar: BarGeometry) -> [Int] {
        guard let notch = bar.notch else { return [] }
        return frames.indices.filter { i in
            let f = frames[i]
            return f.maxX > bar.minX + 0.5 && f.minX < bar.maxX && f.minX < notch.upperBound - 0.5
        }
    }

    /// About how many more icons of `typical` width fit beside what's shown.
    static func spareSlots(room: CGFloat, used: CGFloat, typical: CGFloat = 30) -> Int {
        max(0, Int(((room - used) / typical).rounded(.down)))
    }

    /// Stretches of the menu bar with nothing in them, where hovering or clicking shows hidden items.
    /// - Parameters:
    ///   - statusItemsMinX: left edge of the leftmost status item on this display.
    ///   - appMenuMaxX: right edge of the front app's menus, when Accessibility can tell. Without it,
    ///     only the half of the free space next to the status items counts (or, on a display with a
    ///     notch, the part right of it), so a click on an app menu is never taken for an empty one.
    static func emptyRanges(bar: BarGeometry, statusItemsMinX: CGFloat?, appMenuMaxX: CGFloat?) -> [ClosedRange<CGFloat>] {
        let statusLeft = min(statusItemsMinX ?? bar.maxX, bar.maxX) - 2
        var ranges: [ClosedRange<CGFloat>] = []
        func add(_ lo: CGFloat, _ hi: CGFloat) {
            if hi - lo >= 8 { ranges.append(lo...hi) }
        }
        if let notch = bar.notch {
            if let menus = appMenuMaxX, menus < notch.lowerBound - 12 {
                add(menus + 6, notch.lowerBound - 4)
            }
            add(max(notch.upperBound, appMenuMaxX.map { $0 + 6 } ?? notch.upperBound) + 4, statusLeft)
        } else if let menus = appMenuMaxX {
            add(menus + 6, statusLeft)
        } else {
            add(bar.minX + (statusLeft - bar.minX) / 2, statusLeft)
        }
        return ranges
    }

    /// Stable key for an item across launches without Accessibility: the owner's bundle id and the
    /// item's place among that app's items, counted from the right.
    static func itemKey(bundleID: String, ordinalFromRight: Int) -> String {
        "\(bundleID)#\(ordinalFromRight)"
    }
}
