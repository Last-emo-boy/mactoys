import MacToysCore
import SwiftUI

@MainActor
public final class MouseWithoutBordersModule: ToyModule {
    public let info = ModuleInfo(
        id: "mwb", name: "Mouse Without Borders",
        summary: "Control several Macs with one keyboard and mouse, and share the clipboard.",
        symbol: "display.2", tint: .orange, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: false)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
