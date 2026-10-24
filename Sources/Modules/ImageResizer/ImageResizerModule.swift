import MacToysCore
import SwiftUI

@MainActor
public final class ImageResizerModule: ToyModule {
    public let info = ModuleInfo(
        id: "imageresizer", name: "Image Resizer",
        summary: "Resize one or many images from Finder with presets.",
        symbol: "photo.on.rectangle.angled", tint: .green, category: .fileManagement,
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
