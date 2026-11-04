import AppKit
import MacToysCore
import SwiftUI

/// Privacy Screen: blur or lock the screen, the windows around the one you're using, or private apps.
@MainActor
public final class PrivacyScreenModule: ToyModule {
    public let info = ModuleInfo(
        id: "privacyscreen", name: "Privacy Screen",
        summary: "Blur or lock your screen in place, keep private apps blurred and hide everything but the window you're using.",
        symbol: "eye.slash.fill", tint: .purple, category: .systemTools,
        permissions: [], enabledByDefault: true,
        keywords: ["privacy", "blur", "lock", "screen lock", "touch id", "focus", "hide", "shoji"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
