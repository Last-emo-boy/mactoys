import MacToysCore
import SwiftUI

@MainActor
public final class AdvancedPasteModule: ToyModule {
    public let info = ModuleInfo(
        id: "advancedpaste", name: "Advanced Paste",
        summary: "Paste clipboard content as plain text, Markdown, JSON, files or through your own AI actions.",
        symbol: "doc.on.clipboard.fill", tint: .purple, category: .systemTools,
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
