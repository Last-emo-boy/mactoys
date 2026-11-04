import AppKit
import MacToysCore
import SwiftUI

/// Menu Bar Calendar: a calendar, world clocks and your next meeting in the menu bar.
@MainActor
public final class MenuBarCalendarModule: ToyModule {
    public let info = ModuleInfo(
        id: "calendar", name: "Menu Bar Calendar",
        summary: "A calendar, world clocks and your next meeting in the menu bar.",
        symbol: "calendar", tint: .red, category: .systemTools,
        permissions: [.calendar], enabledByDefault: false,
        keywords: ["calendar", "date", "week number", "time zone", "world clock", "meeting", "events"])

    public init() {}

    public func start() {}
    public func stop() {}

    public func settingsView() -> AnyView {
        AnyView(SettingsPage(module: self) { EmptyView() })
    }
}
