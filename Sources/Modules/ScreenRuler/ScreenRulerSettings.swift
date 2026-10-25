import Foundation
import MacToysCore

/// The measuring tools on the toolbar, in toolbar order (⌘1…⌘4).
public enum RulerTool: String, Codable, CaseIterable, Sendable, Identifiable {
    case bounds, spacing, horizontal, vertical

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bounds: String(localized: "Bounds", comment: "Screen Ruler tool: measure a dragged box")
        case .spacing: String(localized: "Spacing", comment: "Screen Ruler tool: measure the space between edges")
        case .horizontal: String(localized: "Horizontal spacing")
        case .vertical: String(localized: "Vertical spacing")
        }
    }

    public var symbol: String {
        switch self {
        case .bounds: "rectangle.dashed"
        case .spacing: "arrow.left.and.right"
        case .horizontal: "arrow.left.arrow.right"
        case .vertical: "arrow.up.arrow.down"
        }
    }

    /// Which spacing lines the tool draws.
    var measuresWidth: Bool { self == .spacing || self == .horizontal }
    var measuresHeight: Bool { self == .spacing || self == .vertical }
}

/// The tool selected when the toolbar opens.
public enum RulerDefaultMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, bounds, spacing, horizontal, vertical
    public var id: String { rawValue }
    public var tool: RulerTool? { RulerTool(rawValue: rawValue) }
    public var title: String { tool?.title ?? String(localized: "None", comment: "Screen Ruler default mode: no tool selected") }
}

public struct ScreenRulerSettings: Codable, Equatable, Sendable {
    public var activationShortcut: Shortcut? = Shortcut(46, [.control, .option])   // ⌃⌥M
    public var defaultMode: RulerDefaultMode = .none
    /// Re-capture while measuring instead of measuring one frozen snapshot.
    public var continuousCapture = false
    public var perChannelDetection = false
    /// 0…255.
    public var pixelTolerance: Double = 30
    public var extraUnit: RulerUnit = .none
    public var drawFeet = true
    public var lineColor = RGBA(hex: "#FF2D55") ?? .accent

    public init() {}
}
