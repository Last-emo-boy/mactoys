import MacToysCore
import SwiftUI

@MainActor
public final class HostsEditorModule: ToyModule {
    public let info = ModuleInfo(
        id: "hosts", name: "Hosts File Editor",
        summary: "Edit /etc/hosts with validation, ping checks and automatic backups.",
        symbol: "server.rack", tint: .green, category: .advanced,
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
