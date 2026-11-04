import AppKit
import MacToysCore
import SwiftUI

/// Keystroke Overlay: show the keys and shortcuts you press, for recordings and presentations.
@MainActor
public final class KeystrokeOverlayModule: ToyModule {
    public let info = ModuleInfo(
        id: "keystrokes", name: "Keystroke Overlay",
        summary: "Show the keys and shortcuts you press, for recordings and presentations.",
        symbol: "keyboard.fill", tint: .yellow, category: .inputOutput,
        permissions: [.inputMonitoring], enabledByDefault: true,
        keywords: ["keystroke", "keys", "shortcut", "presentation", "screencast", "overlay"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
