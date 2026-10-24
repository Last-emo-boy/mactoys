import MacToysCore
import SwiftUI

@MainActor
public final class PlistPreviewModule: ToyModule {
    public let info = ModuleInfo(
        id: "plistpreview", name: "Plist Preview",
        summary: "Inspect, edit and compare property lists and defaults domains.",
        symbol: "list.bullet.indent", tint: .brown, category: .advanced,
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
