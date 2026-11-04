import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Persisted options of Focus Dimmer (`focusdimmer.json`).
public struct FocusDimmerSettings: Codable, Equatable, Sendable {
    /// Which windows stay bright.
    public enum Highlight: String, Codable, CaseIterable, Sendable {
        case frontWindow, frontApp

        public var title: String {
            switch self {
            case .frontWindow: String(localized: "The window you're working in",
                                      comment: "Focus Dimmer: keep only the focused window bright")
            case .frontApp: String(localized: "Every window of the active app",
                                   comment: "Focus Dimmer: keep all windows of the frontmost app bright")
            }
        }
    }

    /// What happens on displays that don't show the active window.
    public enum OtherDisplays: String, Codable, CaseIterable, Sendable {
        case dim, highlightFront, leave

        public var title: String {
            switch self {
            case .dim: String(localized: "Dim them completely", comment: "Focus Dimmer: other displays are dimmed entirely")
            case .highlightFront: String(localized: "Keep their front window bright",
                                         comment: "Focus Dimmer: each other display keeps its topmost window undimmed")
            case .leave: String(localized: "Leave them undimmed", comment: "Focus Dimmer: other displays are not dimmed at all")
            }
        }
    }

    /// Dimming on or off (the toggle shortcut and the quick action switch flip it).
    public var dimming = true
    public var toggle: Shortcut? = Shortcut(kVK_ANSI_H, [.control, .option, .shift])
    /// Intensity in percent while the system uses the light appearance.
    public var lightIntensity: Double = 40
    /// Intensity in percent while the system uses the dark appearance.
    public var darkIntensity: Double = 55
    public var color = RGBA.black
    public var animate = true
    /// Fade duration in seconds.
    public var fadeDuration: Double = 0.3
    public var highlight = Highlight.frontWindow
    public var otherDisplays = OtherDisplays.dim
    /// Leave the screen alone while the active window is the only one showing.
    public var onlyWithOtherWindows = true
    public var excludedApps: [String] = []

    public init() {}

    /// Intensity (percent) for an appearance.
    public func intensity(dark: Bool) -> Double { dark ? darkIntensity : lightIntensity }

    /// Fade duration in seconds, 0 when animation is off.
    public var effectiveFade: TimeInterval { animate ? min(max(fadeDuration, 0.05), 2) : 0 }

    var options: DimOptions {
        DimOptions(highlight: highlight, otherDisplays: otherDisplays, onlyWithOtherWindows: onlyWithOtherWindows)
    }
}

/// The planner's view of the settings.
public struct DimOptions: Equatable, Sendable {
    public var highlight: FocusDimmerSettings.Highlight
    public var otherDisplays: FocusDimmerSettings.OtherDisplays
    public var onlyWithOtherWindows: Bool

    public init(highlight: FocusDimmerSettings.Highlight = .frontWindow, otherDisplays: FocusDimmerSettings.OtherDisplays = .dim,
                onlyWithOtherWindows: Bool = true) {
        self.highlight = highlight
        self.otherDisplays = otherDisplays
        self.onlyWithOtherWindows = onlyWithOtherWindows
    }
}
