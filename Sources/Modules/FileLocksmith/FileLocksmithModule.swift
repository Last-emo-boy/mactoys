import MacToysCore
import SwiftUI

@MainActor
public final class FileLocksmithModule: ToyModule {
    public let info = ModuleInfo(
        id: "filelocksmith", name: "File Locksmith",
        summary: "See which processes are using a file or folder, and end them.",
        symbol: "lock.doc.fill", tint: .yellow, category: .fileManagement,
        permissions: [], enabledByDefault: true)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
