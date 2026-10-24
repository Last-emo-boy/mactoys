import MacToysCore
import SwiftUI

@MainActor
public final class PeekModule: ToyModule {
    public let info = ModuleInfo(
        id: "peek", name: "Peek",
        summary: "Preview files in a quick, keyboard-driven window without opening an app.",
        symbol: "eye.fill", tint: .cyan, category: .fileManagement,
        permissions: [.automation], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
