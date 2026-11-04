import AppKit
import MacToysCore
import SwiftUI

/// Window Controls: resize windows from the zoom button, the keyboard or saved layouts you restore in one click.
@MainActor
public final class WindowControlsModule: ToyModule {
    public let info = ModuleInfo(
        id: "windowcontrols", name: "Window Controls",
        summary: "Resize windows from the zoom button, the keyboard or saved layouts you restore in one click.",
        symbol: "macwindow.on.rectangle", tint: .green, category: .windowing,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["window", "resize", "move", "zoom button", "halves", "thirds", "layout", "snapshot"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
