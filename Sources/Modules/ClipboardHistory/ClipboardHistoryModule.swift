import AppKit
import MacToysCore
import SwiftUI

/// Clipboard History: search everything you copied, pin favorites and paste it back with the keyboard.
@MainActor
public final class ClipboardHistoryModule: ToyModule {
    public let info = ModuleInfo(
        id: "clipboard", name: "Clipboard History",
        summary: "Search everything you copied, pin favorites and paste it back with the keyboard.",
        symbol: "doc.on.clipboard.fill", tint: .purple, category: .systemTools,
        permissions: [], enabledByDefault: true,
        keywords: ["clipboard", "history", "paste", "copy", "snippets", "pinboard"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
