import AppKit
import MacToysCore
import SwiftUI

/// Screenshot: capture an area, window or screen, then annotate, beautify, pin or copy it.
@MainActor
public final class ScreenshotModule: ToyModule {
    public let info = ModuleInfo(
        id: "screenshot", name: "Screenshot",
        summary: "Capture an area, window or screen, then annotate, beautify, pin or copy it.",
        symbol: "camera.viewfinder", tint: .pink, category: .systemTools,
        permissions: [.screenRecording], enabledByDefault: true,
        keywords: ["screenshot", "capture", "annotate", "markup", "arrow", "blur", "pin"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
