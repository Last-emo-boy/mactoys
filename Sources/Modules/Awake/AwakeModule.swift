import MacToysCore
import SwiftUI

@MainActor
public final class AwakeModule: ToyModule {
    public let info = ModuleInfo(
        id: "awake", name: "Awake",
        summary: "Keep your Mac awake on demand, without touching Energy settings.",
        symbol: "cup.and.saucer.fill", tint: .orange, category: .systemTools,
        permissions: [], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
