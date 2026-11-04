import AppKit
import MacToysCore
import SwiftUI

/// Window Gestures: swipe, pinch and tap on a title bar with the trackpad to tile, minimize, close or move windows.
@MainActor
public final class WindowGesturesModule: ToyModule {
    public let info = ModuleInfo(
        id: "gestures", name: "Window Gestures",
        summary: "Swipe, pinch and tap on a title bar with the trackpad to tile, minimize, close or move windows.",
        symbol: "hand.draw.fill", tint: .cyan, category: .windowing,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["gesture", "trackpad", "swipe", "pinch", "title bar", "window"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
