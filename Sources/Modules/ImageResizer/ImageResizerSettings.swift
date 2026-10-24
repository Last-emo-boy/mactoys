import Foundation
import MacToysCore

public struct ImageResizerSettings: Codable, Equatable, Sendable {
    public var presets = ResizePreset.defaults
    public var custom = ResizePreset.defaultCustom
    /// Index into `presets`, or -1 for the custom size. Remembered between uses.
    public var selectedIndex = 1
    /// Defaults for the window's checkboxes, file naming and encoders.
    public var options = ResizeOptions()
    /// Read by the Finder extension (`MacToys › Resize with Image Resizer`).
    public var showInFinderMenu = true
    public var finderMenuNeedsOption = false
    /// Optional shortcut that resizes the Finder selection.
    public var activation: Shortcut?

    public init() {}

    /// The preset for `selectedIndex`, falling back to the first one.
    public var selectedPreset: ResizePreset {
        if selectedIndex == -1 { return custom }
        if presets.indices.contains(selectedIndex) { return presets[selectedIndex] }
        return presets.first ?? custom
    }
}
