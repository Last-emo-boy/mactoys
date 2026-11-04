import AppKit
import MacToysCore
import SwiftUI

/// Menu Bar Manager: hide menu bar icons you rarely need and bring them back with a click.
@MainActor
public final class MenuBarManagerModule: ToyModule {
    public let info = ModuleInfo(
        id: "menubar", name: "Menu Bar Manager",
        summary: "Hide menu bar icons you rarely need and bring them back with a click.",
        symbol: "menubar.rectangle", tint: .graphite, category: .systemTools,
        permissions: [], enabledByDefault: false,
        keywords: ["menu bar", "status items", "hide icons", "notch", "clutter"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
