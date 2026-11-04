import AppKit
import MacToysCore
import SwiftUI

/// File Shelf: hold files on a floating shelf while you switch apps, then drop them all at once.
@MainActor
public final class FileShelfModule: ToyModule {
    public let info = ModuleInfo(
        id: "shelf", name: "File Shelf",
        summary: "Hold files on a floating shelf while you switch apps, then drop them all at once.",
        symbol: "tray.full.fill", tint: .teal, category: .fileManagement,
        permissions: [], enabledByDefault: true,
        keywords: ["shelf", "drag", "drop", "stash", "files", "clipboard"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
