import MacToysCore
import SwiftUI

@MainActor
public final class MouseUtilitiesModule: ToyModule {
    public let info = ModuleInfo(
        id: "mouseutils", name: "Mouse Utilities",
        summary: "Find, highlight, lock, hide, jump, wrap and crosshair your pointer.",
        symbol: "cursorarrow.rays", tint: .red, category: .inputOutput,
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
