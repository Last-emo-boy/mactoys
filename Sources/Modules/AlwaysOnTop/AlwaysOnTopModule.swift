import MacToysCore
import SwiftUI

@MainActor
public final class AlwaysOnTopModule: ToyModule {
    public let info = ModuleInfo(
        id: "alwaysontop", name: "Always On Top",
        summary: "Pin any window above all others with a shortcut.",
        symbol: "pin.fill", tint: .indigo, category: .windowing,
        permissions: [.accessibility, .screenRecording], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
