import MacToysCore
import SwiftUI

@MainActor
public final class WindowHopperModule: ToyModule {
    public let info = ModuleInfo(
        id: "windowhopper", name: "Window Hopper",
        summary: "Cycle through the windows of the focused app with previews.",
        symbol: "macwindow.on.rectangle", tint: .indigo, category: .windowing,
        permissions: [.accessibility, .screenRecording], enabledByDefault: false)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
