import AppKit
import MacToysCore
import SwiftUI

/// Text Actions: select text anywhere to get a bar of actions: copy, search, translate, transform and your own.
@MainActor
public final class TextActionsModule: ToyModule {
    public let info = ModuleInfo(
        id: "textactions", name: "Text Actions",
        summary: "Select text anywhere to get a bar of actions: copy, search, translate, transform and your own.",
        symbol: "text.cursor", tint: .orange, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["selection", "popup", "search", "translate", "copy", "actions"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
