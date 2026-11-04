import CoreGraphics
import Foundation
import MacToysCore

/// AppKit also brings in QuickDraw's `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// A rectangle in fractions of a display's work area, top-left origin: 0…1 on both axes.
public struct UnitRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    /// Kept inside 0…1 with a minimum size of 1 %.
    public var clamped: UnitRect {
        let x0 = min(max(x, 0), 0.99), y0 = min(max(y, 0), 0.99)
        let w = min(max(width, 0.01), 1 - x0), h = min(max(height, 0.01), 1 - y0)
        return UnitRect(x: x0, y: y0, width: w, height: h)
    }
}

/// A point of a rectangle a window is pinned to: a corner, an edge's middle or the center.
public enum Anchor: String, Codable, CaseIterable, Sendable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    /// 0, 0.5 or 1 along each axis.
    public var unit: (x: Double, y: Double) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }

    public var title: String {
        switch self {
        case .topLeft: String(localized: "Top left", comment: "Position on screen")
        case .top: String(localized: "Top edge", comment: "Window Controls: the middle of the screen's top edge")
        case .topRight: String(localized: "Top right", comment: "Position on screen")
        case .left: String(localized: "Left edge", comment: "Window Controls: the middle of the screen's left edge")
        case .center: String(localized: "Center", comment: "Position on screen")
        case .right: String(localized: "Right edge", comment: "Window Controls: the middle of the screen's right edge")
        case .bottomLeft: String(localized: "Bottom left", comment: "Position on screen")
        case .bottom: String(localized: "Bottom edge", comment: "Window Controls: the middle of the screen's bottom edge")
        case .bottomRight: String(localized: "Bottom right", comment: "Position on screen")
        }
    }
}

/// One axis of a resize: a share of the work area, an exact number of points, or left as is.
public struct Dimension: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case fraction, points, unchanged

        public var title: String {
            switch self {
            case .fraction: String(localized: "windowcontrols.unit.percent", defaultValue: "% of screen", comment: "Window Controls resize unit: percent of the screen")
            case .points: String(localized: "Points", comment: "Window Controls resize unit: exact size in points")
            case .unchanged: String(localized: "Unchanged", comment: "Window Controls resize unit: keep this side as it is")
            }
        }
    }

    public var unit: Unit
    /// 0…1 for `fraction`, points for `points`, ignored for `unchanged`.
    public var value: Double

    public init(_ unit: Unit, _ value: Double = 0) {
        self.unit = unit
        self.value = value
    }

    public static func fraction(_ v: Double) -> Dimension { Dimension(.fraction, v) }
    public static func points(_ v: Double) -> Dimension { Dimension(.points, v) }
    public static let unchanged = Dimension(.unchanged)

    /// The length along an axis whose work area is `available` long and whose window is `current` long.
    func resolve(available: CGFloat, current: CGFloat) -> CGFloat {
        switch unit {
        case .fraction: (available * min(max(value, 0.01), 1)).rounded()
        case .points: min(max(CGFloat(value), 40), available).rounded()
        case .unchanged: min(current, available)
        }
    }
}

/// Which display a "move to display" step goes to.
public enum DisplayTarget: String, Codable, CaseIterable, Sendable {
    case next, previous, left, right, up, down, main

    public var title: String {
        switch self {
        case .next: String(localized: "Next display", comment: "Window Controls: move to the next display")
        case .previous: String(localized: "Previous display", comment: "Window Controls: move to the previous display")
        case .left: String(localized: "Display on the left", comment: "Window Controls: move to the display on the left")
        case .right: String(localized: "Display on the right", comment: "Window Controls: move to the display on the right")
        case .up: String(localized: "Display above", comment: "Window Controls: move to the display above")
        case .down: String(localized: "Display below", comment: "Window Controls: move to the display below")
        case .main: String(localized: "Main display", comment: "Window Controls: move to the display with the menu bar")
        }
    }
}

/// One thing a control does to a window.
public struct ControlStep: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Move and resize over a part of the screen (halves, thirds, quarters…).
        case place
        /// Resize to a share of the screen or an exact size, pinned at `anchor`.
        case resize
        /// Move without resizing to a corner, an edge or the center.
        case move
        /// Move to another display, keeping the place on screen.
        case display

        public var title: String {
            switch self {
            case .place: String(localized: "Place on screen", comment: "Window Controls step: move and resize over part of the screen")
            case .resize: String(localized: "Resize", comment: "Window Controls step: change the window's size")
            case .move: String(localized: "Move", comment: "Window Controls step: move the window without resizing it")
            case .display: String(localized: "Move to display", comment: "Window Controls step: move the window to another display")
            }
        }

        public var symbol: String {
            switch self {
            case .place: "rectangle.leadinghalf.inset.filled"
            case .resize: "arrow.up.left.and.arrow.down.right"
            case .move: "arrow.up.and.down.and.arrow.left.and.right"
            case .display: "display.2"
            }
        }
    }

    public var id = UUID()
    public var kind: Kind
    public var region: UnitRect = .full
    public var width: Dimension = .fraction(0.6)
    public var height: Dimension = .fraction(0.7)
    /// Where a resized or moved window goes on screen.
    public var anchor: Anchor = .center
    /// Resize around the window's own center instead of pinning it at `anchor` of the screen.
    public var inPlace = false
    public var display: DisplayTarget = .next

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static func place(_ r: UnitRect) -> ControlStep {
        var s = ControlStep(kind: .place)
        s.region = r
        return s
    }

    public static func resize(_ width: Dimension, _ height: Dimension, anchor: Anchor = .center,
                              inPlace: Bool = false) -> ControlStep {
        var s = ControlStep(kind: .resize)
        s.width = width
        s.height = height
        s.anchor = anchor
        s.inPlace = inPlace
        return s
    }

    public static func move(_ anchor: Anchor) -> ControlStep {
        var s = ControlStep(kind: .move)
        s.anchor = anchor
        return s
    }

    public static func display(_ target: DisplayTarget) -> ControlStep {
        var s = ControlStep(kind: .display)
        s.display = target
        return s
    }

    /// Tolerates missing keys so older or hand-edited files still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .place
        region = try c.decodeIfPresent(UnitRect.self, forKey: .region) ?? .full
        width = try c.decodeIfPresent(Dimension.self, forKey: .width) ?? .fraction(0.6)
        height = try c.decodeIfPresent(Dimension.self, forKey: .height) ?? .fraction(0.7)
        anchor = try c.decodeIfPresent(Anchor.self, forKey: .anchor) ?? .center
        inPlace = try c.decodeIfPresent(Bool.self, forKey: .inPlace) ?? false
        display = try c.decodeIfPresent(DisplayTarget.self, forKey: .display) ?? .next
    }
}

/// A named window action: one step, or a chain of steps run together or one per use.
public struct WindowControl: Codable, Hashable, Sendable, Identifiable {
    public enum ChainMode: String, Codable, CaseIterable, Sendable {
        /// Every step at once, as one action (e.g. next display, then left half).
        case all
        /// One step per use, per window: use it again to get the next one.
        case cycle

        public var title: String {
            switch self {
            case .all: String(localized: "Run all steps at once", comment: "Window Controls chain mode")
            case .cycle: String(localized: "One step per use, in turn", comment: "Window Controls chain mode: each use runs the next step")
            }
        }
    }

    public var id: UUID
    /// The user's name; empty for a built-in control that keeps its localized name.
    public var name: String
    public var steps: [ControlStep]
    public var chainMode: ChainMode
    public var shortcut: Shortcut?
    public var inPalette: Bool
    public var inKeyboard: Bool
    /// Identifier of a built-in control ("left-half"), nil for controls the user made.
    public var builtIn: String?

    public init(id: UUID = UUID(), name: String = "", steps: [ControlStep], chainMode: ChainMode = .all,
                shortcut: Shortcut? = nil, inPalette: Bool = true, inKeyboard: Bool = false, builtIn: String? = nil) {
        self.id = id
        self.name = name
        self.steps = steps
        self.chainMode = chainMode
        self.shortcut = shortcut
        self.inPalette = inPalette
        self.inKeyboard = inKeyboard
        self.builtIn = builtIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        steps = try c.decodeIfPresent([ControlStep].self, forKey: .steps) ?? []
        chainMode = try c.decodeIfPresent(ChainMode.self, forKey: .chainMode) ?? .all
        shortcut = try c.decodeIfPresent(Shortcut.self, forKey: .shortcut)
        inPalette = try c.decodeIfPresent(Bool.self, forKey: .inPalette) ?? true
        inKeyboard = try c.decodeIfPresent(Bool.self, forKey: .inKeyboard) ?? false
        builtIn = try c.decodeIfPresent(String.self, forKey: .builtIn)
    }

    /// The name shown in the UI: the user's, else the built-in control's localized name.
    public var displayName: String {
        if !name.isEmpty { return name }
        if let builtIn, let title = BuiltInControls.title(builtIn) { return title }
        return String(localized: "Untitled control", comment: "Window Controls: a custom control without a name")
    }

    public var isChain: Bool { steps.count > 1 }
}

/// The controls Window Controls starts with. Users can edit, hide, reorder or delete them,
/// and bring them back with "Restore built-in controls".
public enum BuiltInControls {
    private static let third = 1.0 / 3

    /// (identifier, steps, chain mode, in palette, in keyboard mode), in palette order.
    private static let table: [(String, [ControlStep], WindowControl.ChainMode, Bool, Bool)] = [
        ("fill", [.place(.full)], .all, true, false),
        ("left-half", [.place(UnitRect(x: 0, y: 0, width: 0.5, height: 1))], .all, true, false),
        ("right-half", [.place(UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))], .all, true, false),
        ("top-half", [.place(UnitRect(x: 0, y: 0, width: 1, height: 0.5))], .all, true, false),
        ("bottom-half", [.place(UnitRect(x: 0, y: 0.5, width: 1, height: 0.5))], .all, true, false),
        ("center", [.move(.center)], .all, true, false),
        ("left-third", [.place(UnitRect(x: 0, y: 0, width: third, height: 1))], .all, true, true),
        ("center-third", [.place(UnitRect(x: third, y: 0, width: third, height: 1))], .all, true, true),
        ("right-third", [.place(UnitRect(x: 2 * third, y: 0, width: third, height: 1))], .all, true, true),
        ("left-two-thirds", [.place(UnitRect(x: 0, y: 0, width: 2 * third, height: 1))], .all, true, true),
        ("right-two-thirds", [.place(UnitRect(x: third, y: 0, width: 2 * third, height: 1))], .all, true, true),
        ("almost-fill", [.resize(.fraction(0.9), .fraction(0.9))], .all, true, true),
        ("top-left", [.place(UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))], .all, true, false),
        ("top-right", [.place(UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))], .all, true, false),
        ("bottom-left", [.place(UnitRect(x: 0, y: 0.5, width: 0.5, height: 0.5))], .all, true, false),
        ("bottom-right", [.place(UnitRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))], .all, true, false),
        ("size-1280", [.resize(.points(1280), .points(800))], .all, true, true),
        ("size-800", [.resize(.points(800), .points(600))], .all, true, false),
        ("cycle-left", [.place(UnitRect(x: 0, y: 0, width: 0.5, height: 1)),
                        .place(UnitRect(x: 0, y: 0, width: third, height: 1)),
                        .place(UnitRect(x: 0, y: 0, width: 2 * third, height: 1))], .cycle, false, true),
        ("cycle-right", [.place(UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)),
                         .place(UnitRect(x: 2 * third, y: 0, width: third, height: 1)),
                         .place(UnitRect(x: third, y: 0, width: 2 * third, height: 1))], .cycle, false, false),
        ("next-display", [.display(.next)], .all, false, false),
    ]

    /// Stable ids so restoring built-ins doesn't duplicate them and shortcuts keep pointing at them.
    private static func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "57C0A7A0-0000-4000-8000-%012X", index + 1)) ?? UUID()
    }

    public static var all: [WindowControl] {
        table.enumerated().map { i, row in
            let steps = row.1.enumerated().map { j, step -> ControlStep in
                var s = step
                s.id = UUID(uuidString: String(format: "57C0A7A0-0000-4000-8001-%08X%04X", i + 1, j + 1)) ?? UUID()
                return s
            }
            return WindowControl(id: uuid(i), steps: steps, chainMode: row.2, inPalette: row.3, inKeyboard: row.4,
                                 builtIn: row.0)
        }
    }

    /// Localized name of a built-in control.
    public static func title(_ id: String) -> String? {
        switch id {
        case "fill": String(localized: "Fill", comment: "Window Controls: make the window fill the screen")
        case "left-half": String(localized: "Left Half", comment: "Window Controls preset")
        case "right-half": String(localized: "Right Half", comment: "Window Controls preset")
        case "top-half": String(localized: "Top Half", comment: "Window Controls preset")
        case "bottom-half": String(localized: "Bottom Half", comment: "Window Controls preset")
        case "center": String(localized: "Center", comment: "Window Controls preset: center the window without resizing it")
        case "left-third": String(localized: "Left Third", comment: "Window Controls preset")
        case "center-third": String(localized: "Center Third", comment: "Window Controls preset")
        case "right-third": String(localized: "Right Third", comment: "Window Controls preset")
        case "left-two-thirds": String(localized: "Left Two Thirds", comment: "Window Controls preset")
        case "right-two-thirds": String(localized: "Right Two Thirds", comment: "Window Controls preset")
        case "almost-fill": String(localized: "Almost Fill", comment: "Window Controls preset: 90 % of the screen, centered")
        case "top-left": String(localized: "Top Left Quarter", comment: "Window Controls preset")
        case "top-right": String(localized: "Top Right Quarter", comment: "Window Controls preset")
        case "bottom-left": String(localized: "Bottom Left Quarter", comment: "Window Controls preset")
        case "bottom-right": String(localized: "Bottom Right Quarter", comment: "Window Controls preset")
        case "size-1280": String(localized: "1280 × 800", comment: "Window Controls preset: a window size in points")
        case "size-800": String(localized: "800 × 600", comment: "Window Controls preset: a window size in points")
        case "cycle-left": String(localized: "Cycle Left Sizes", comment: "Window Controls preset: left half, third, two thirds in turn")
        case "cycle-right": String(localized: "Cycle Right Sizes", comment: "Window Controls preset: right half, third, two thirds in turn")
        case "next-display": String(localized: "Next Display", comment: "Window Controls preset: move the window to the next display")
        default: nil
        }
    }

    /// The list with every missing built-in control added back (at its default position) and every
    /// built-in control reset to its defaults; the user's own controls are kept after them.
    public static func restored(in controls: [WindowControl]) -> [WindowControl] {
        let builtIns = all
        let ids = Set(builtIns.map(\.id))
        let custom = controls.filter { !ids.contains($0.id) }
        return builtIns.map { b in
            // Keep a shortcut the user gave a built-in control.
            var copy = b
            copy.shortcut = controls.first { $0.id == b.id }?.shortcut
            return copy
        } + custom
    }
}
