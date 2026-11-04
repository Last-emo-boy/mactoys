import AppKit
import MacToysCore
import SwiftUI

/// Focus Dimmer: dim the windows behind the one you're working in.
@MainActor
public final class FocusDimmerModule: ToyModule {
    public let info = ModuleInfo(
        id: "focusdimmer", name: "Focus Dimmer",
        summary: "Dim the windows behind the one you're working in.",
        symbol: "moon.haze.fill", tint: .indigo, category: .windowing,
        permissions: [], enabledByDefault: false,
        keywords: ["dim", "focus", "background", "distraction", "fade"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
