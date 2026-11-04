import AppKit
import MacToysCore
import SwiftUI

/// Camera Mirror: check your camera from the menu bar before a call, in a small window you can keep on top.
@MainActor
public final class CameraMirrorModule: ToyModule {
    public let info = ModuleInfo(
        id: "mirror", name: "Camera Mirror",
        summary: "Check your camera from the menu bar before a call, in a small window you can keep on top.",
        symbol: "web.camera.fill", tint: .mint, category: .systemTools,
        permissions: [.camera], enabledByDefault: true,
        keywords: ["camera", "webcam", "mirror", "video call", "preview"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
