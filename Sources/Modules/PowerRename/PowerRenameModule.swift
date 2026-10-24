import MacToysCore
import SwiftUI

@MainActor
public final class PowerRenameModule: ToyModule {
    public let info = ModuleInfo(
        id: "powerrename", name: "PowerRename",
        summary: "Bulk rename files with search and replace, regular expressions, numbering and undo.",
        symbol: "character.cursor.ibeam", tint: .purple, category: .fileManagement,
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
