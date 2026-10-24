import MacToysCore
import SwiftUI

@MainActor
public final class GrabAndMoveModule: ToyModule {
    public let info = ModuleInfo(
        id: "grabandmove", name: "Grab And Move",
        summary: "Hold a modifier and drag anywhere in a window to move it, or right-drag to resize.",
        symbol: "arrow.up.and.down.and.arrow.left.and.right", tint: .mint, category: .windowing,
        permissions: [.accessibility], enabledByDefault: false)

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) {
            Section { Text("Not implemented yet.").foregroundStyle(.secondary) }
        })
    }
}
