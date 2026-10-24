import MacToysCore
import SwiftUI

@MainActor
public final class CropAndLockModule: ToyModule {
    public let info = ModuleInfo(
        id: "cropandlock", name: "Crop And Lock",
        summary: "Crop part of a window into a live thumbnail that stays on top.",
        symbol: "crop", tint: .teal, category: .windowing,
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
