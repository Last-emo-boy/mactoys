import CoreGraphics
import Foundation

/// A zone layout: one of the built-in templates or a custom grid or canvas layout.
///
/// Templates are identified by their kind's raw value (`"columns"`); custom layouts by a UUID.
public struct ZoneLayout: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case blank, focus, columns, rows, grid, priorityGrid, customGrid, canvas

        public var isTemplate: Bool { self != .customGrid && self != .canvas }

        public var title: String {
            switch self {
            case .blank: "No layout"
            case .focus: "Focus"
            case .columns: "Columns"
            case .rows: "Rows"
            case .grid: "Grid"
            case .priorityGrid: "Priority Grid"
            case .customGrid: "Grid"
            case .canvas: "Canvas"
            }
        }

        public static let templates: [Kind] = [.blank, .focus, .columns, .rows, .grid, .priorityGrid]
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Number of zones of a template (custom layouts derive it from their zones).
    public var zoneCount: Int
    /// Space around and between zones in points, applied when `showSpacing` is on. Canvas layouts ignore it.
    public var spacing: Double
    public var showSpacing: Bool
    /// How close (points) the pointer must be to a zone for it to highlight; adjacent zones within
    /// this distance highlight together so a window can be dropped across both.
    public var highlightDistance: Double
    /// 1…9: the layout is applied with ⌃⌥⇧<n> and cycled with the mouse wheel while dragging.
    public var quickKey: Int?
    /// Set for `.customGrid`.
    public var grid: GridLayout?
    /// Set for `.canvas`.
    public var canvas: CanvasLayout?

    public init(id: String, name: String, kind: Kind, zoneCount: Int = 3, spacing: Double = 12,
                showSpacing: Bool = true, highlightDistance: Double = 20, quickKey: Int? = nil,
                grid: GridLayout? = nil, canvas: CanvasLayout? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.zoneCount = zoneCount
        self.spacing = spacing
        self.showSpacing = showSpacing
        self.highlightDistance = highlightDistance
        self.quickKey = quickKey
        self.grid = grid
        self.canvas = canvas
    }

    /// A built-in template with its default parameters.
    public static func template(_ kind: Kind) -> ZoneLayout {
        let count: Int
        switch kind {
        case .blank: count = 0
        case .grid: count = 4
        case .priorityGrid: count = 5
        default: count = 3
        }
        return ZoneLayout(id: kind.rawValue, name: kind.title, kind: kind, zoneCount: count)
    }

    /// Every template, with the quick keys MacToys ships with (Priority Grid ⌃⌥⇧1, Columns 2, Rows 3, Grid 4).
    public static var defaultTemplates: [ZoneLayout] {
        Kind.templates.map { kind in
            var t = template(kind)
            switch kind {
            case .priorityGrid: t.quickKey = 1
            case .columns: t.quickKey = 2
            case .rows: t.quickKey = 3
            case .grid: t.quickKey = 4
            default: break
            }
            return t
        }
    }

    /// A new custom grid layout (three columns, like the PowerToys editor starts with).
    public static func newGrid(name: String) -> ZoneLayout {
        ZoneLayout(id: UUID().uuidString, name: name, kind: .customGrid, zoneCount: 3, grid: .columns(3))
    }

    /// A new custom canvas layout with one zone, for a display of `reference` size.
    public static func newCanvas(name: String, reference: CGSize) -> ZoneLayout {
        let w = reference.width, h = reference.height
        let zone = CanvasZone(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6)
        return ZoneLayout(id: UUID().uuidString, name: name, kind: .canvas, zoneCount: 1,
                          canvas: CanvasLayout(referenceWidth: w, referenceHeight: h, zones: [zone]))
    }

    public var isTemplate: Bool { kind.isTemplate }

    /// Spacing actually applied between zones.
    public var effectiveSpacing: Double { showSpacing && kind != .canvas ? max(0, spacing) : 0 }

    /// The grid this layout is made of (templates other than Focus are grids too).
    public var gridModel: GridLayout? {
        switch kind {
        case .columns: .columns(zoneCount)
        case .rows: .rows(zoneCount)
        case .grid: .grid(zoneCount)
        case .priorityGrid: .priority(zoneCount)
        case .customGrid: grid?.isValid == true ? grid : nil
        case .blank, .focus, .canvas: nil
        }
    }

    /// Number of zones the layout produces.
    public var count: Int {
        switch kind {
        case .blank: 0
        case .focus: max(0, zoneCount)
        case .canvas: canvas?.zones.count ?? 0
        default: gridModel?.zoneCount ?? 0
        }
    }

    /// Zone rectangles in `rect` with the layout's own spacing.
    public func zones(in rect: CGRect) -> [CGRect] {
        ZoneGeometry.zones(for: self, in: rect, spacing: CGFloat(effectiveSpacing))
    }

    /// A copy as a custom layout (templates become custom grids, Focus becomes a canvas).
    public func duplicated(name: String, reference: CGSize) -> ZoneLayout {
        var copy = self
        copy.id = UUID().uuidString
        copy.name = name
        copy.quickKey = nil
        switch kind {
        case .customGrid, .canvas:
            break
        case .focus, .blank:
            let rect = CGRect(origin: .zero, size: reference)
            let zones = ZoneGeometry.zones(for: self, in: rect, spacing: 0)
            copy.kind = .canvas
            copy.canvas = CanvasLayout(referenceWidth: reference.width, referenceHeight: reference.height,
                                       zones: zones.map(CanvasZone.init))
        default:
            copy.kind = .customGrid
            copy.grid = gridModel
        }
        copy.zoneCount = copy.count
        return copy
    }
}

/// A free-form layout: rectangles in the coordinates of a reference display, scaled to any other.
public struct CanvasLayout: Codable, Hashable, Sendable {
    public var referenceWidth: Double
    public var referenceHeight: Double
    public var zones: [CanvasZone]

    /// A positive reference size and zones with a finite, positive size.
    public var isValid: Bool {
        referenceWidth.isFinite && referenceHeight.isFinite && referenceWidth > 0 && referenceHeight > 0
            && zones.allSatisfy { [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }
    }

    public init(referenceWidth: Double, referenceHeight: Double, zones: [CanvasZone]) {
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
        self.zones = zones
    }

    /// Zones scaled from the reference size into `rect`.
    public func zones(in rect: CGRect) -> [CGRect] {
        guard isValid else { return [] }
        let sx = rect.width / referenceWidth, sy = rect.height / referenceHeight
        return zones.map { z in
            ZoneGeometry.rounded(CGRect(x: rect.minX + z.x * sx, y: rect.minY + z.y * sy,
                                        width: z.width * sx, height: z.height * sy))
        }
    }
}

/// One canvas zone in reference coordinates (top-left origin).
public struct CanvasZone: Codable, Hashable, Sendable {
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

    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
