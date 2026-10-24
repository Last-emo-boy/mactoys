import MacToysCore
import SwiftUI

@MainActor
public final class ZoomItModule: ToyModule {
    public let info = ModuleInfo(
        id: "zoomit", name: "ZoomIt",
        summary: "Zoom, annotate, time breaks and record the screen for presentations.",
        symbol: "plus.magnifyingglass", tint: .red, category: .systemTools,
        permissions: [.screenRecording, .accessibility], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
