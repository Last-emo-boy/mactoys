import AppKit
import MacToysCore

/// MacToys (`@`): every utility's settings page and every quick action.
@MainActor
final class MacToysProvider: SearchProvider {
    let id = "mactoys"
    let name = "MacToys"
    let summary = "Open any utility's settings, run quick actions, turn utilities on or off"
    let icon = ItemIcon.symbol("puzzlepiece.extension.fill", .indigo)
    let defaultKeyword = "@"
    let examples = ["@ color picker", "@ fancyzones", "@  (every utility)"]

    /// Quick actions of these modules are not offered (the launchers' own "open" actions).
    static let ownModules: Set<String> = ["cmdpal", "run"]

    var commands: [PaletteItem] {
        [pageCommand(title: "MacToys Utilities", subtitle: "Settings and quick actions of every utility",
                     keywords: ["mactoys", "powertoys", "utilities"])]
    }

    private var registry: ModuleRegistry { ModuleRegistry.shared }

    func allItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        for m in registry.modules where !Self.ownModules.contains(m.info.id) && registry.isEnabled(m.info.id) {
            for action in m.quickActions { out.append(quickActionItem(action, module: m)) }
        }
        out += registry.modules.sorted { $0.info.name < $1.info.name }.map(settingsItem)
        return out
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return allItems().enumerated().map { i, item in
                var it = item
                it.score = 500 - Double(i)
                return it
            }
        }
        guard query.scoped || text.count >= 2 else { return [] }
        return fuzzyFilter(allItems(), text).map { item in
            var it = item
            if !query.scoped { it.score *= 0.95 }
            return it
        }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        if id.hasPrefix("mactoys:settings:") {
            let moduleID = String(id.dropFirst(17))
            return registry.module(moduleID).map(settingsItem)
        }
        if id.hasPrefix("mactoys:action:") {
            let actionID = String(id.dropFirst(15))
            for m in registry.modules where registry.isEnabled(m.info.id) {
                if let a = m.quickActions.first(where: { $0.id == actionID }) { return quickActionItem(a, module: m) }
            }
        }
        return nil
    }

    private func settingsItem(_ m: any ToyModule) -> PaletteItem {
        let moduleID = m.info.id
        let enabled = registry.isEnabled(moduleID)
        return PaletteItem(
            id: "mactoys:settings:\(moduleID)", title: m.info.name, subtitle: "MacToys settings · \(enabled ? "On" : "Off")",
            icon: .symbol(m.info.symbol, m.info.tint), providerID: id, section: "MacToys", accessory: "Settings",
            primary: PaletteAction(id: "open", title: "Open Settings", symbol: "gearshape") {
                .dismissThen { ModuleRegistry.shared.showSettings?(moduleID) }
            },
            actions: [PaletteAction(id: "toggle", title: enabled ? "Turn Off \(m.info.name)" : "Turn On \(m.info.name)",
                                    symbol: enabled ? "power.circle" : "power.circle.fill") {
                ModuleRegistry.shared.setEnabled(moduleID, !enabled)
                HUD.show("\(m.info.name) · \(enabled ? "off" : "on")", symbol: m.info.symbol)
                return .refresh
            }],
            details: ItemDetails(icon: .symbol(m.info.symbol, m.info.tint), title: m.info.name, subtitle: m.info.summary,
                                 rows: [DetailRow(label: "Status", value: enabled ? "On" : "Off", monospaced: false),
                                        DetailRow(label: "Category", value: m.info.category.title, monospaced: false)]
                                     + m.shortcutBindings.filter { !$0.keys.isEmpty }.prefix(6).map {
                                         DetailRow(label: $0.title, value: $0.keys.joined(separator: " "))
                                     }),
            keywords: m.info.keywords + [m.info.id])
    }

    private func quickActionItem(_ a: QuickAction, module m: any ToyModule) -> PaletteItem {
        let state = a.isOn.map { $0() ? "On" : "Off" }
        var subtitle = m.info.name
        if let detail = a.detail?() { subtitle += " · \(detail)" } else if let state { subtitle += " · \(state)" }
        let perform = a.perform
        return PaletteItem(
            id: "mactoys:action:\(a.id)", title: a.title, subtitle: subtitle, icon: .symbol(a.symbol, a.tint), providerID: id,
            section: "MacToys", accessory: state ?? "Action",
            primary: PaletteAction(id: "run", title: a.isOn == nil ? "Run" : "Toggle", symbol: a.symbol) {
                if a.isOn != nil {
                    perform()
                    HUD.show("\(a.title) · \(a.isOn?() == true ? "on" : "off")", symbol: a.symbol)
                    return .dismiss
                }
                return .dismissThen(perform)
            },
            actions: [PaletteAction(id: "settings", title: "\(m.info.name) Settings", symbol: "gearshape") {
                let moduleID = m.info.id
                return .dismissThen { ModuleRegistry.shared.showSettings?(moduleID) }
            }],
            keywords: [m.info.name] + m.info.keywords)
    }
}
