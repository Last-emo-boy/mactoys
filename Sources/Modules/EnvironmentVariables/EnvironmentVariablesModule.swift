import MacToysCore
import SwiftUI

@MainActor
public final class EnvironmentVariablesModule: ToyModule {
    public let info = ModuleInfo(
        id: "envvars", name: "Environment Variables",
        summary: "Manage environment variables for zsh and GUI apps, grouped into profiles.",
        symbol: "curlybraces", tint: .graphite, category: .advanced,
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
