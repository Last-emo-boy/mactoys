import AppKit
import MacToysCore
import SwiftUI

/// Auto Tiling: arranges every new window into the display's layout as it opens.
@MainActor
public final class AutoTilingModule: ToyModule {
    public let info = ModuleInfo(
        id: "autotile", name: "Auto Tiling",
        summary: "Tile every window automatically as it opens, with a layout for each display.",
        symbol: "rectangle.split.2x2.fill", tint: .indigo, category: .windowing,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["tiling", "tile", "window manager", "layout", "grid", "columns", "shoji", "aerospace", "yabai"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
