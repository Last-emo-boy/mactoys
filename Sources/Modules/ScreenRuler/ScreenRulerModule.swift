import MacToysCore
import SwiftUI

@MainActor
public final class ScreenRulerModule: ToyModule {
    public let info = ModuleInfo(
        id: "screenruler", name: "Screen Ruler",
        summary: "Measure pixels on screen with edge detection.",
        symbol: "ruler.fill", tint: .teal, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
