import MacToysCore
import SwiftUI

@MainActor
public final class TextExtractorModule: ToyModule {
    public let info = ModuleInfo(
        id: "textextractor", name: "Text Extractor",
        summary: "Copy text from anywhere on screen with on-device OCR.",
        symbol: "text.viewfinder", tint: .mint, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
