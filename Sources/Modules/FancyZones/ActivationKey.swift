import CoreGraphics
import Foundation

/// The key held while dragging a window to show zones (⌘ is taken: it spans several zones).
public enum ActivationKey: String, Codable, CaseIterable, Sendable {
    case shift, function, option, control
    /// Zones show for every drag; holding ⇧ drags freely.
    case none

    /// The modifier flag of the key; empty for `.none`.
    public var flag: CGEventFlags {
        switch self {
        case .shift: .maskShift
        case .function: .maskSecondaryFn
        case .option: .maskAlternate
        case .control: .maskControl
        case .none: []
        }
    }

    /// Keycap glyph for the Shortcut Guide (not localized: keycaps read the same everywhere).
    public var glyph: String? {
        switch self {
        case .shift: "⇧"
        case .function: "fn"
        case .option: "⌥"
        case .control: "⌃"
        case .none: nil
        }
    }

    /// Localized name for the settings picker.
    public var title: String {
        switch self {
        case .shift: String(localized: "⇧ Shift", comment: "FancyZones activation key choice: the Shift key")
        case .function: String(localized: "fn 🌐 Globe", comment: "FancyZones activation key choice: the fn / Globe key")
        case .option: String(localized: "⌥ Option", comment: "FancyZones activation key choice: the Option key")
        case .control: String(localized: "⌃ Control", comment: "FancyZones activation key choice: the Control key")
        case .none: String(localized: "No key, zones always on",
                           comment: "FancyZones activation key choice: zones show for every window drag")
        }
    }

    /// Whether zones show for the modifier `flags` of a drag. `toggled` is the non-primary mouse
    /// button toggle, which flips the result. Without an activation key zones are on, and ⇧ turns
    /// them off for free dragging. Allocation-free: it runs for every drag tick.
    public func zonesActive(flags: CGEventFlags, toggled: Bool) -> Bool {
        switch self {
        case .none: flags.contains(.maskShift) == toggled
        default: flags.contains(flag) != toggled
        }
    }
}

extension FancyZonesSettings {
    /// The activation key in effect. Settings saved before the choice existed only have
    /// `holdShiftToActivate`: true meant ⇧, false meant zones always on. Setting a key keeps that
    /// flag in step, so an older version reading the file still behaves close to the choice.
    public var activation: ActivationKey {
        get { activationKey ?? (holdShiftToActivate ? .shift : .none) }
        set {
            activationKey = newValue
            holdShiftToActivate = newValue != .none
        }
    }
}
