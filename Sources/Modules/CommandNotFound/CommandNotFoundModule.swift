import MacToysCore
import SwiftUI

@MainActor
public final class CommandNotFoundModule: ToyModule {
    public let info = ModuleInfo(
        id: "cmdnotfound", name: "Command Not Found",
        summary: "Suggests the Homebrew package to install when a zsh command is missing.",
        symbol: "terminal.fill", tint: .graphite, category: .systemTools,
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
