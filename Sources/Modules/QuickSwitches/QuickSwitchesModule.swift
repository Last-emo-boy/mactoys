import AppKit
import MacToysCore
import SwiftUI

/// Quick Switches: hide desktop icons, show hidden files, connect AirPods and more, from the menu bar.
@MainActor
public final class QuickSwitchesModule: ToyModule {
    public let info = ModuleInfo(
        id: "switches", name: "Quick Switches",
        summary: "Hide desktop icons, show hidden files, connect AirPods and more, from the menu bar.",
        symbol: "switch.2", tint: .blue, category: .systemTools,
        permissions: [], enabledByDefault: true,
        keywords: ["toggle", "switch", "desktop icons", "hidden files", "dock", "bluetooth", "airpods"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
