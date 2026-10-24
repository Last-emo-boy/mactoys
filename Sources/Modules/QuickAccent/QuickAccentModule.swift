import MacToysCore
import SwiftUI

@MainActor
public final class QuickAccentModule: ToyModule {
    public let info = ModuleInfo(
        id: "quickaccent", name: "Quick Accent",
        summary: "Hold a letter and tap Space or an arrow key to type accented characters.",
        symbol: "character", tint: .pink, category: .inputOutput,
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
