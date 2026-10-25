import SwiftUI

extension EnvironmentValues {
    /// Set by MacToys' offscreen snapshot/export renderer. AppKit-backed controls draw their accent
    /// fill in a separate backdrop layer that `CALayer.render(in:)` can't capture, so on-state
    /// switches come out grey; with this flag `AdaptiveSwitchStyle` draws the switch in SwiftUI.
    @Entry public var drawsControlsForSnapshot = false
}

/// The system switch in the app; a SwiftUI-drawn look-alike when rendering snapshots.
/// Use `.toggleStyle(.adaptiveSwitch)` wherever you would use `.toggleStyle(.switch)`.
public struct AdaptiveSwitchStyle: ToggleStyle {
    @Environment(\.drawsControlsForSnapshot) private var drawn
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsVisibility) private var labelsVisibility

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        if drawn {
            HStack(spacing: 8) {
                if labelsVisibility != .hidden {
                    configuration.label
                    Spacer(minLength: 8)
                }
                DrawnSwitch(isOn: configuration.isOn, small: controlSize == .small || controlSize == .mini)
                    .opacity(isEnabled ? 1 : 0.5)
                    .onTapGesture { configuration.isOn.toggle() }
            }
        } else {
            Toggle(configuration).toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == AdaptiveSwitchStyle {
    public static var adaptiveSwitch: AdaptiveSwitchStyle { AdaptiveSwitchStyle() }
}

private struct DrawnSwitch: View {
    let isOn: Bool
    let small: Bool

    var body: some View {
        let w: CGFloat = small ? 32 : 38, h: CGFloat = small ? 18 : 22
        Capsule()
            .fill(isOn ? Color.accentColor : Color(nsColor: .tertiaryLabelColor).opacity(0.45))
            .frame(width: w, height: h)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.2, y: 0.6)
                    .padding(2)
            }
    }
}
