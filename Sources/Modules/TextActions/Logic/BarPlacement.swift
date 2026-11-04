import CoreGraphics
import Foundation
import MacToysCore

/// Where the bar goes, in global top-left (Accessibility) coordinates.
public enum BarPlacement {
    /// The screen the selection is on.
    public struct Screen: Equatable, Sendable {
        public var frame: CGRect
        /// Frame minus menu bar and Dock.
        public var visible: CGRect
        /// The camera housing at the top edge, when the display has one.
        public var notch: CGRect?

        public init(frame: CGRect, visible: CGRect, notch: CGRect? = nil) {
            self.frame = frame
            self.visible = visible
            self.notch = notch
        }
    }

    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 6
    /// Selections taller than this are multi-line; the bar then follows the pointer.
    public static let tallSelection: CGFloat = 44
    static let pointerLine: CGFloat = 20

    /// The rectangle the bar is placed against, and which side it prefers.
    ///
    /// - A short selection (one line) uses its own bounds and the preferred side.
    /// - A tall mouse selection uses the line under the pointer: below it when the drag went
    ///   down, above when it went up, so the bar never covers what was just selected.
    /// - A tall keyboard selection uses its first line.
    /// - Without bounds (apps that don't report them) the pointer stands in for the selection.
    public static func anchor(selection: CGRect?, pointer: CGPoint?, dragStart: CGPoint?,
                              preferred: TextActionsSettings.Placement) -> (rect: CGRect, side: TextActionsSettings.Placement) {
        if let s = selection, s.height <= tallSelection {
            return (s, preferred)
        }
        if let s = selection, s.height > tallSelection {
            if let pointer, s.insetBy(dx: -40, dy: -40).contains(pointer) {
                let line = CGRect(x: pointer.x - 1, y: pointer.y - pointerLine / 2, width: 2, height: pointerLine)
                let draggedDown = (dragStart.map { pointer.y > $0.y + 4 }) ?? false
                return (line, draggedDown ? .below : .above)
            }
            return (CGRect(x: s.minX, y: s.minY, width: s.width, height: pointerLine), .above)
        }
        let p = pointer ?? .zero
        return (CGRect(x: p.x - 1, y: p.y - pointerLine / 2, width: 2, height: pointerLine), preferred)
    }

    /// The bar's frame: centered on the anchor, on the preferred side when it fits (and stays
    /// clear of the notch), otherwise on the other side, always inside the visible frame.
    public static func frame(size: CGSize, anchor: CGRect, side: TextActionsSettings.Placement, screen: Screen) -> CGRect {
        let vf = screen.visible
        let x = min(max(anchor.midX - size.width / 2, vf.minX + margin), max(vf.minX + margin, vf.maxX - margin - size.width))
        let above = CGRect(x: x, y: anchor.minY - gap - size.height, width: size.width, height: size.height)
        let below = CGRect(x: x, y: anchor.maxY + gap, width: size.width, height: size.height)

        func fits(_ r: CGRect) -> Bool {
            guard r.minY >= vf.minY + margin, r.maxY <= vf.maxY - margin else { return false }
            if let notch = screen.notch, r.insetBy(dx: -margin, dy: -margin).intersects(notch) { return false }
            return true
        }

        let order = side == .above ? [above, below] : [below, above]
        if let fit = order.first(where: fits) { return fit }
        // Neither side fits (a selection filling the screen): overlap it, inside the visible frame
        // and below the notch.
        var r = order[0]
        let top = max(vf.minY, screen.notch?.maxY ?? vf.minY) + margin
        r.origin.y = min(max(r.minY, top), max(top, vf.maxY - margin - size.height))
        return r
    }
}

/// Which mouse gestures finish a selection, free of events so it can be tested.
public enum SelectionGesture {
    /// How a selection was made.
    public enum Kind: Equatable, Sendable {
        case drag, multiClick, shiftClick, keyboard, longPress, shortcut

        /// Shown without being asked for (subject to excluded apps and the auto-show switch).
        public var isAutomatic: Bool { self != .shortcut }
    }

    /// Pointer travel that turns a click into a drag.
    public static let dragThreshold: CGFloat = 5

    /// The gesture a mouse-up completes, or nil when it doesn't select (a plain click) or the
    /// settings don't want it. `flags` are the modifiers held at mouse-up.
    public static func classify(down: CGPoint, up: CGPoint, clickCount: Int, flags: Modifiers,
                                triggers: TextActionsSettings.Triggers,
                                required: TextActionsSettings.RequiredModifier) -> Kind? {
        guard modifiersAllow(flags, required: required) else { return nil }
        let distance = hypot(up.x - down.x, up.y - down.y)
        if distance >= dragThreshold { return triggers.drag ? .drag : nil }
        if clickCount >= 2 { return triggers.multiClick ? .multiClick : nil }
        if clickCount == 1, flags.contains(.shift) { return triggers.shiftClick ? .shiftClick : nil }
        return nil
    }

    /// A required modifier must be held; without one, holding ⌘ skips the bar once.
    public static func modifiersAllow(_ flags: Modifiers, required: TextActionsSettings.RequiredModifier) -> Bool {
        if required != .none { return flags.contains(required.modifiers) }
        return !flags.contains(.command)
    }
}
