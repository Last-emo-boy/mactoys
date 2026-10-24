import MacToysCore
import SwiftUI

@MainActor
public final class ShortcutGuideModule: ToyModule {
    public let info = ModuleInfo(
        id: "shortcutguide", name: "Shortcut Guide",
        summary: "Hold ⌘ to see every shortcut of the frontmost app, plus macOS and MacToys shortcuts.",
        symbol: "list.bullet.rectangle.fill", tint: .indigo, category: .systemTools,
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
