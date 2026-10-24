import MacToysCore
import SwiftUI

/// PowerToys Run: the compact launcher driven by plugin keywords. Shares the search
/// engine with Command Palette.
@MainActor
public final class RunModule: ToyModule {
    public let info = ModuleInfo(
        id: "run", name: "Run",
        summary: "A quick launcher with plugin keywords: = calculator, > shell, // URLs, < windows and more.",
        symbol: "magnifyingglass.circle.fill", tint: .blue, category: .systemTools,
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

extension CommandPaletteModule {
    /// Extra modules that live in this target.
    public static var companions: [any ToyModule] { [RunModule()] }
}
