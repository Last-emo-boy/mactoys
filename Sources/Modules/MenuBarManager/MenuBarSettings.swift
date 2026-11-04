import Foundation
import MacToysCore

/// Where hidden items appear when they're shown.
enum HiddenBarMode: String, Codable, CaseIterable, Sendable {
    /// The divider shrinks and the items slide back into the menu bar.
    case inMenuBar
    /// A glass bar under the menu bar lists them; the menu bar itself stays as it is.
    case separateBar
    /// In the menu bar while they fit beside the notch, otherwise in the separate bar.
    case whenCrowded

    var title: String {
        switch self {
        case .inMenuBar: String(localized: "In the menu bar", comment: "Menu Bar Manager: hidden items slide back into the menu bar")
        case .separateBar: String(localized: "In a bar below the menu bar", comment: "Menu Bar Manager: hidden items appear in a separate bar")
        case .whenCrowded: String(localized: "Below it when the notch is in the way",
                                  comment: "Menu Bar Manager: use the separate bar only when the items would not fit beside the camera notch")
        }
    }

    /// Whether the separate bar (and so click forwarding through Accessibility) can be used.
    var usesBar: Bool { self != .inMenuBar }
}

/// The look of the item that shows and hides the hidden section.
enum ChevronStyle: String, Codable, CaseIterable, Sendable {
    case chevron, arrow, dot, ellipsis

    var title: String {
        switch self {
        case .chevron: String(localized: "Chevron", comment: "Menu Bar Manager toggle icon style")
        case .arrow: String(localized: "Arrow", comment: "Menu Bar Manager toggle icon style")
        case .dot: String(localized: "Dot", comment: "Menu Bar Manager toggle icon style")
        case .ellipsis: String(localized: "Ellipsis", comment: "Menu Bar Manager toggle icon style: three dots")
        }
    }

    /// SF Symbol while items are hidden and while they're shown.
    func symbol(collapsed: Bool) -> String {
        switch self {
        case .chevron: collapsed ? "chevron.left" : "chevron.right"
        case .arrow: collapsed ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill"
        case .dot: collapsed ? "circle.fill" : "circle"
        case .ellipsis: collapsed ? "ellipsis" : "ellipsis.circle"
        }
    }
}

/// The look of the dividers while the hidden section is shown.
enum DividerStyle: String, Codable, CaseIterable, Sendable {
    case line, dots, none

    var title: String {
        switch self {
        case .line: String(localized: "Line", comment: "Menu Bar Manager divider style")
        case .dots: String(localized: "Dots", comment: "Menu Bar Manager divider style")
        case .none: String(localized: "Invisible", comment: "Menu Bar Manager divider style: no divider drawn")
        }
    }
}

/// The outline of the tint drawn behind the menu bar.
enum BackdropShape: String, Codable, CaseIterable, Sendable {
    case fullWidth, rounded, split

    var title: String {
        switch self {
        case .fullWidth: String(localized: "Full width", comment: "Menu bar background shape")
        case .rounded: String(localized: "Rounded", comment: "Menu bar background shape: a rounded bar inset from the screen edges")
        case .split: String(localized: "Split at the notch", comment: "Menu bar background shape: two rounded halves left and right of the camera notch")
        }
    }

    var symbol: String {
        switch self {
        case .fullWidth: "rectangle.fill"
        case .rounded: "capsule.fill"
        case .split: "rectangle.split.2x1.fill"
        }
    }
}

/// The optional tint, shape, border and shadow drawn behind the menu bar.
struct MenuBarAppearance: Codable, Equatable, Sendable {
    var enabled = false
    var shape: BackdropShape = .rounded
    var tint = RGBA(red: 0.369, green: 0.361, blue: 0.902, alpha: 0.42)
    var gradient = false
    var secondTint = RGBA(red: 1, green: 0.176, blue: 0.333, alpha: 0.36)
    var border = false
    var borderColor = RGBA(red: 1, green: 1, blue: 1, alpha: 0.4)
    var borderWidth: Double = 1
    var shadow = true
}

struct MenuBarSettings: Codable, Equatable, Sendable {
    // Sections
    var alwaysHiddenSection = false
    var barMode: HiddenBarMode = .inMenuBar

    // Showing
    var showOnHover = false
    /// Seconds the pointer rests in empty menu bar space before hidden items appear.
    var hoverDelay: Double = 0.3
    var showOnEmptyClick = false
    var showOnUpdate = false
    var toggleShortcut: Shortcut?
    var alwaysHiddenShortcut: Shortcut?

    // Rehiding
    var rehideAfterDelay = true
    var rehideDelay: Double = 15
    var rehideWhenPointerLeaves = false

    // Notch
    var notchWarning = true

    // Search
    var searchEnabled = false
    var searchShortcut: Shortcut?

    // Appearance
    var chevronStyle: ChevronStyle = .chevron
    var dividerStyle: DividerStyle = .line
    var appearance = MenuBarAppearance()

    /// Set once the user finished (or dismissed) the arrangement card.
    var onboardingCompleted = false

    var rehideSchedule: RehideSchedule {
        RehideSchedule(afterDelay: rehideAfterDelay ? max(1, rehideDelay) : nil, whenPointerLeaves: rehideWhenPointerLeaves)
    }

    /// Whether anything needs Accessibility (the separate bar's click forwarding, search).
    var wantsAccessibility: Bool { searchEnabled || barMode.usesBar }
}
