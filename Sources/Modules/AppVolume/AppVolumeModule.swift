import AppKit
import MacToysCore
import SwiftUI

/// App Volume: set the volume and output device of each app on its own.
@MainActor
public final class AppVolumeModule: ToyModule {
    public let info = ModuleInfo(
        id: "appvolume", name: "App Volume",
        summary: "Set the volume and output device of each app on its own.",
        symbol: "speaker.wave.3.fill", tint: .orange, category: .inputOutput,
        permissions: [], enabledByDefault: false,
        keywords: ["volume", "audio", "sound", "per app", "output", "mixer"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
