import MacToysCore
import SwiftUI

@MainActor
public final class KeyboardManagerModule: ToyModule {
    public let info = ModuleInfo(
        id: "keyboardmanager", name: "Keyboard Manager",
        summary: "Remap keys and shortcuts, globally or per app.",
        symbol: "keyboard.fill", tint: .orange, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
