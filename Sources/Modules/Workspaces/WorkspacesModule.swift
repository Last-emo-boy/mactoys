import MacToysCore
import SwiftUI

@MainActor
public final class WorkspacesModule: ToyModule {
    public let info = ModuleInfo(
        id: "workspaces", name: "Workspaces",
        summary: "Launch a set of apps into saved window positions with one click.",
        symbol: "rectangle.split.2x2.fill", tint: .blue, category: .windowing,
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
