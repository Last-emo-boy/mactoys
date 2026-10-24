import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Every FancyZones option, grouped like the PowerToys settings page.
public struct FancyZonesSettings: Codable, Equatable, Sendable {
    public enum EditorDisplay: String, Codable, CaseIterable, Sendable {
        case mouse, activeWindow
        public var title: String { self == .mouse ? "Display under the pointer" : "Display with the active window" }
    }

    public enum MoveMode: String, Codable, CaseIterable, Sendable {
        case zoneIndex, relativePosition
        public var title: String { self == .zoneIndex ? "Zone index" : "Relative position" }
    }

    public enum ZoneColors: String, Codable, CaseIterable, Sendable {
        case system, custom
        public var title: String { self == .system ? "System accent" : "Custom colors" }
    }

    public enum IndicatorPosition: String, Codable, CaseIterable, Sendable {
        case topLeft, topCenter, topRight, center, bottomLeft, bottomCenter, bottomRight
        public var title: String {
            switch self {
            case .topLeft: "Top left"
            case .topCenter: "Top center"
            case .topRight: "Top right"
            case .center: "Center"
            case .bottomLeft: "Bottom left"
            case .bottomCenter: "Bottom center"
            case .bottomRight: "Bottom right"
            }
        }
    }

    // Activation
    @Clearable public var editorShortcut: Shortcut? = Shortcut(kVK_ANSI_Grave, [.control, .option])
    public var editorDisplay: EditorDisplay = .mouse
    public var holdShiftToActivate = true
    public var nonPrimaryButtonToggles = false
    public var middleButtonSpansZones = false
    public var mouseWheelSwitchesLayouts = true
    public var showZonesOnAllDisplays = true
    public var spanAcrossDisplays = false
    public var overlapAlgorithm: OverlapAlgorithm = .smallest

    // Zone appearance
    public var zoneColors: ZoneColors = .custom
    public var showZoneNumber = true
    /// Percent, 0…100.
    public var opacity = 50.0
    public var highlightColor = RGBA(hex: "#0A84FF") ?? .accent
    public var inactiveColor = RGBA(hex: "#F4F4F7") ?? .white
    public var borderColor = RGBA(hex: "#FFFFFF") ?? .white
    public var numberColor = RGBA(hex: "#1D1D1F") ?? .black

    // Layout name indicator
    public var showLayoutName = true
    public var layoutNamePosition: IndicatorPosition = .topCenter
    public var layoutNameTextColor = RGBA(hex: "#FFFFFF") ?? .white
    public var layoutNameBackground = RGBA(hex: "#262626") ?? .black
    public var layoutNameTextSize = 36.0
    public var layoutNamePadding = 12.0
    /// Milliseconds.
    public var layoutNameDuration = 1500.0

    // Window behavior
    public var keepWindowsOnDisplayChange = true
    public var keepWindowsOnLayoutChange = true
    public var moveNewWindowsToLastZone = true
    public var moveNewWindowsToActiveDisplay = false
    public var restoreSizeOnUnsnap = true
    public var allowChildWindows = false
    public var allowPopupWindows = false

    // Window switching
    public var switchWindowsInZone = true
    @Clearable public var nextWindowShortcut: Shortcut? = Shortcut(kVK_PageDown, [.control, .option])
    @Clearable public var previousWindowShortcut: Shortcut? = Shortcut(kVK_PageUp, [.control, .option])

    // Keyboard moves
    public var moveWithKeyboard = true
    public var moveMode: MoveMode = .relativePosition
    public var moveAcrossDisplays = false
    public var wrapAround = true
    @Clearable public var moveLeft: Shortcut? = Shortcut(kVK_LeftArrow, [.control, .option])
    @Clearable public var moveRight: Shortcut? = Shortcut(kVK_RightArrow, [.control, .option])
    @Clearable public var moveUp: Shortcut? = Shortcut(kVK_UpArrow, [.control, .option])
    @Clearable public var moveDown: Shortcut? = Shortcut(kVK_DownArrow, [.control, .option])
    @Clearable public var extendLeft: Shortcut? = Shortcut(kVK_LeftArrow, [.control, .option, .shift])
    @Clearable public var extendRight: Shortcut? = Shortcut(kVK_RightArrow, [.control, .option, .shift])
    @Clearable public var extendUp: Shortcut? = Shortcut(kVK_UpArrow, [.control, .option, .shift])
    @Clearable public var extendDown: Shortcut? = Shortcut(kVK_DownArrow, [.control, .option, .shift])

    // Layouts
    public var quickLayoutSwitch = true
    public var flashZonesOnLayoutSwitch = true
    public var defaultHorizontalLayout = ZoneLayout.Kind.priorityGrid.rawValue
    public var defaultVerticalLayout = ZoneLayout.Kind.rows.rawValue

    // Excluded apps
    public var excludedApps: [String] = []

    public init() {}

    public func moveShortcut(_ d: ZoneDirection) -> Shortcut? {
        switch d {
        case .left: moveLeft
        case .right: moveRight
        case .up: moveUp
        case .down: moveDown
        }
    }

    public func extendShortcut(_ d: ZoneDirection) -> Shortcut? {
        switch d {
        case .left: extendLeft
        case .right: extendRight
        case .up: extendUp
        case .down: extendDown
        }
    }
}

/// The ⌃⌥⇧ digit shortcut that applies the layout with quick key `n`.
func quickLayoutShortcut(_ n: Int) -> Shortcut {
    let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
    return Shortcut(codes[max(1, min(9, n)) - 1], [.control, .option, .shift])
}

/// Encodes nil as JSON `null`. `SettingsStore` overlays saved JSON on the encoded defaults, and
/// synthesized `Codable` omits nil optionals — so without this a cleared shortcut would come back
/// as the default on the next launch.
@propertyWrapper
public struct Clearable<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : try c.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let wrappedValue { try c.encode(wrappedValue) } else { try c.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    /// A missing key decodes as nil instead of failing.
    public func decode<V>(_ type: Clearable<V>.Type, forKey key: Key) throws -> Clearable<V> {
        try decodeIfPresent(type, forKey: key) ?? Clearable(wrappedValue: nil)
    }
}
