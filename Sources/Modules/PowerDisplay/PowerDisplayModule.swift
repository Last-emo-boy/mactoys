import MacToysCore
import SwiftUI

@MainActor
public final class PowerDisplayModule: ToyModule {
    public let info = ModuleInfo(
        id: "powerdisplay", name: "Power Display",
        summary: "Control brightness, contrast, volume and input of your displays from one flyout.",
        symbol: "sun.max.fill", tint: .yellow, category: .systemTools,
        permissions: [], enabledByDefault: false)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
