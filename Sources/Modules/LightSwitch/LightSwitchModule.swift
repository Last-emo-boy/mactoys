import MacToysCore
import SwiftUI

@MainActor
public final class LightSwitchModule: ToyModule {
    public let info = ModuleInfo(
        id: "lightswitch", name: "Light Switch",
        summary: "Switch between light and dark appearance on a schedule or at sunrise and sunset.",
        symbol: "circle.lefthalf.filled", tint: .yellow, category: .systemTools,
        permissions: [.automation], enabledByDefault: false)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
