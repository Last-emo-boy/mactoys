import AppKit
import MacToysCore
import SwiftUI

/// Charge Limit: keep your MacBook's battery between limits you choose to slow its aging.
@MainActor
public final class ChargeLimitModule: ToyModule {
    public let info = ModuleInfo(
        id: "chargelimit", name: "Charge Limit",
        summary: "Keep your MacBook's battery between limits you choose to slow its aging.",
        symbol: "battery.75percent", tint: .green, category: .advanced,
        permissions: [], enabledByDefault: false,
        keywords: ["battery", "charge", "limit", "health", "charging"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
