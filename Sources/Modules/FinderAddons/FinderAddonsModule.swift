import MacToysCore
import SwiftUI

@MainActor
public final class FinderAddonsModule: ToyModule {
    public let info = ModuleInfo(
        id: "finderaddons", name: "Finder Add-ons",
        summary: "Quick Look previews and thumbnails for Markdown, source code, SVG, G-code, STL, QOI and more.",
        symbol: "doc.viewfinder.fill", tint: .cyan, category: .fileManagement,
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
