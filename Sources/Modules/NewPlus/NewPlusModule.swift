import MacToysCore
import SwiftUI

@MainActor
public final class NewPlusModule: ToyModule {
    public let info = ModuleInfo(
        id: "newplus", name: "New+",
        summary: "Create files and folders from your own templates in Finder.",
        symbol: "doc.badge.plus", tint: .green, category: .fileManagement,
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
