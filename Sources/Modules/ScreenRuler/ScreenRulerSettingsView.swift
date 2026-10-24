import MacToysCore
import SwiftUI

struct ScreenRulerSettingsView: View {
    let module: ScreenRulerModule
    @Bindable var settings: Persisted<ScreenRulerSettings>

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .teal) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Measure anything on screen").font(.headline)
                        Text("Spacing tools stop at edges; ⇧-click keeps a measurement, scroll changes the tolerance.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Screen Ruler") { module.open(tool: settings.value.defaultMode.tool) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Activation") {
                ShortcutRow("Activation shortcut", subtitle: "Shows or hides the toolbar.",
                            shortcut: $settings.value.activationShortcut)
                Picker(selection: $settings.value.defaultMode) {
                    ForEach(RulerDefaultMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Default mode", subtitle: "The tool that's selected when the toolbar opens.")
                }
            }
            Section("Behavior") {
                Toggle(isOn: $settings.value.continuousCapture) {
                    RowLabel("Capture screen continuously during measuring",
                             subtitle: "Measures live content instead of one snapshot. Uses more power.")
                }
                Toggle(isOn: $settings.value.perChannelDetection) {
                    RowLabel("Per color channel edge detection",
                             subtitle: "Every channel must be within the tolerance; otherwise their summed difference must be.")
                }
                SliderRow("Pixel tolerance for edge detection",
                          subtitle: "Higher values forgive gradients and shadows.",
                          value: $settings.value.pixelTolerance, in: 0...255, step: 1)
            }
            Section("Appearance") {
                Picker(selection: $settings.value.extraUnit) {
                    ForEach(RulerUnit.allCases) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("Extra units of measurement",
                             subtitle: "Shown under pixels. Points follow each display's scaling; inches and centimeters use its physical size.")
                }
                Toggle(isOn: $settings.value.drawFeet) {
                    RowLabel("Draw feet on cross", subtitle: "Small serifs at the ends of each measuring line.")
                }
                ColorRow("Line color", color: $settings.value.lineColor, supportsOpacity: false)
            }
        }
    }
}
