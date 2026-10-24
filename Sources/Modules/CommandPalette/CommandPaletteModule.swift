import MacToysCore
import SwiftUI

@MainActor
public final class CommandPaletteModule: ToyModule {
    public let info = ModuleInfo(
        id: "cmdpal", name: "Command Palette",
        summary: "Search apps, files, windows, commands, clipboard history and more from one box.",
        symbol: "command", tint: .blue, category: .systemTools,
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
