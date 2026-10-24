import MacToysCore
import SwiftUI

@MainActor
public final class ColorPickerModule: ToyModule {
    public let info = ModuleInfo(
        id: "colorpicker", name: "Color Picker",
        summary: "Pick a color from anywhere on screen and copy it in the format you need.",
        symbol: "eyedropper", tint: .pink, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
