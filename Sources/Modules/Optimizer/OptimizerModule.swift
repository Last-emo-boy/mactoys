import AppKit
import MacToysCore
import SwiftUI

/// Optimizer: shrink images, videos and PDFs you drop or copy, and resize or convert them.
@MainActor
public final class OptimizerModule: ToyModule {
    public let info = ModuleInfo(
        id: "optimizer", name: "Optimizer",
        summary: "Shrink images, videos and PDFs you drop or copy, and resize or convert them.",
        symbol: "arrow.down.right.and.arrow.up.left", tint: .green, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["compress", "optimize", "shrink", "image", "video", "pdf", "clipboard"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
