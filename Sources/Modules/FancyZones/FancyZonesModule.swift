import MacToysCore
import SwiftUI

@MainActor
public final class FancyZonesModule: ToyModule {
    public let info = ModuleInfo(
        id: "fancyzones", name: "FancyZones",
        summary: "Create window layouts and snap windows into zones by dragging with ⇧ held, or with the keyboard.",
        symbol: "rectangle.3.group.fill", tint: .blue, category: .windowing,
        permissions: [.accessibility], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
