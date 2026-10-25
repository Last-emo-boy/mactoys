import AppKit
import MacToysCore

/// MacToys (`@`): every utility's settings page and every quick action.
@MainActor
final class MacToysProvider: SearchProvider {
    let id = "mactoys"
    let name = "MacToys"
    let summary = String(localized: "Open any utility's settings, run quick actions, turn utilities on or off")
    let icon = ItemIcon.symbol("puzzlepiece.extension.fill", .indigo)
    let defaultKeyword = "@"
    var examples: [String] {
        ["@ color picker", "@ fancyzones",
         String(localized: "\("@")  (every utility)", comment: "Run help example: %@ is what to type, the parentheses explain it")]
    }

    /// Quick actions of these modules are not offered (the launchers' own "open" actions).
    static let ownModules: Set<String> = ["cmdpal", "run"]

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("MacToys Utilities"), subtitle: String(localized: "Settings and quick actions of every utility"),
                     keywords: ["mactoys", "powertoys", "utilities"])]
    }

    private var registry: ModuleRegistry { ModuleRegistry.shared }

    func allItems() -> [PaletteItem] {
        var out: [PaletteItem] = []
        for m in registry.modules where !Self.ownModules.contains(m.info.id) && registry.isEnabled(m.info.id) {
            for action in m.quickActions { out.append(quickActionItem(action, module: m)) }
        }
        out += registry.modules.sorted { $0.info.name.localizedStandardCompare($1.info.name) == .orderedAscending }.map(settingsItem)
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
        if id.hasPrefix("mactoys:open:") {
            return registry.module(String(id.dropFirst(13))).map(openItem)
        }
        if id.hasPrefix("mactoys:action:") {
            let actionID = String(id.dropFirst(15))
            for m in registry.modules where registry.isEnabled(m.info.id) {
                if let a = m.quickActions.first(where: { $0.id == actionID }) { return quickActionItem(a, module: m) }
            }
        }
        return nil
    }

    /// Opens a utility through its `open` command (its editor or picker), or its settings when it has none.
    private func openItem(_ m: any ToyModule) -> PaletteItem {
        let moduleID = m.info.id
        var item = settingsItem(m)
        item.id = "mactoys:open:\(moduleID)"
        item.subtitle = "MacToys · \(m.info.summary)"
        item.accessory = String(localized: "Utility", comment: "Result row label: a MacToys utility")
        item.primary = PaletteAction(id: "open", title: String(localized: "Open \(m.info.name)", comment: "Action: open something; %@ is an app, utility, website or address"),
                                     symbol: m.info.symbol) {
            .dismissThen {
                let registry = ModuleRegistry.shared
                if !registry.isEnabled(moduleID) || !registry.dispatch(AppCommand(module: moduleID, action: "open")) {
                    registry.showSettings?(moduleID)
                }
            }
        }
        item.actions.insert(PaletteAction(id: "settings", title: Self.settingsTitle(m), symbol: "gearshape") {
            .dismissThen { ModuleRegistry.shared.showSettings?(moduleID) }
        }, at: 0)
        return item
    }

    private func settingsItem(_ m: any ToyModule) -> PaletteItem {
        let moduleID = m.info.id
        let enabled = registry.isEnabled(moduleID)
        return PaletteItem(
            id: "mactoys:settings:\(moduleID)", title: m.info.name,
            subtitle: enabled ? String(localized: "MacToys settings · On") : String(localized: "MacToys settings · Off"),
            icon: .symbol(m.info.symbol, m.info.tint), providerID: id, section: "MacToys",
            accessory: String(localized: "Settings", comment: "Row label: opens a utility's settings; Run keyword chip: System Settings"),
            primary: PaletteAction(id: "open", title: Labels.openSettings, symbol: "gearshape") {
                .dismissThen { ModuleRegistry.shared.showSettings?(moduleID) }
            },
            actions: [PaletteAction(id: "toggle",
                                    title: enabled ? String(localized: "Turn Off \(m.info.name)", comment: "%@ is a utility such as Color Picker")
                                        : String(localized: "Turn On \(m.info.name)", comment: "%@ is a utility such as Color Picker"),
                                    symbol: enabled ? "power.circle" : "power.circle.fill") {
                ModuleRegistry.shared.setEnabled(moduleID, !enabled)
                HUD.show(Self.stateMessage(m.info.name, on: !enabled), symbol: m.info.symbol)
                return .refresh
            }],
            details: ItemDetails(icon: .symbol(m.info.symbol, m.info.tint), title: m.info.name, subtitle: m.info.summary,
                                 rows: [DetailRow(label: String(localized: "Status", comment: "Detail row: whether the utility is on"),
                                                  value: enabled ? Labels.on : Labels.off, monospaced: false),
                                        DetailRow(label: Labels.category,
                                                  value: m.info.category.title, monospaced: false)]
                                     + m.shortcutBindings.filter { !$0.keys.isEmpty }.prefix(6).map {
                                         DetailRow(label: $0.title, value: $0.keys.joined(separator: " "))
                                     }),
            keywords: m.info.keywords + [m.info.id])
    }

    private func quickActionItem(_ a: QuickAction, module m: any ToyModule) -> PaletteItem {
        let state = a.isOn.map { $0() ? Labels.on : Labels.off }
        var subtitle = m.info.name
        if let detail = a.detail?() { subtitle += " · \(detail)" } else if let state { subtitle += " · \(state)" }
        let perform = a.perform
        return PaletteItem(
            id: "mactoys:action:\(a.id)", title: a.title, subtitle: subtitle, icon: .symbol(a.symbol, a.tint), providerID: id,
            section: "MacToys", accessory: state ?? String(localized: "Action", comment: "Result row label: a utility's quick action"),
            primary: PaletteAction(id: "run", title: a.isOn == nil ? Labels.run : String(localized: "Toggle", comment: "Action: turn the option on or off"),
                                   symbol: a.symbol) {
                if a.isOn != nil {
                    perform()
                    HUD.show(Self.stateMessage(a.title, on: a.isOn?() == true), symbol: a.symbol)
                    return .dismiss
                }
                return .dismissThen(perform)
            },
            actions: [PaletteAction(id: "settings", title: Self.settingsTitle(m), symbol: "gearshape") {
                let moduleID = m.info.id
                return .dismissThen { ModuleRegistry.shared.showSettings?(moduleID) }
            }],
            keywords: [m.info.name] + m.info.keywords)
    }

    private static func settingsTitle(_ m: any ToyModule) -> String {
        String(localized: "\(m.info.name) Settings", comment: "Action: open a utility's settings; %@ is a utility such as Color Picker")
    }

    /// "Awake · on" after toggling.
    private static func stateMessage(_ name: String, on: Bool) -> String {
        on ? String(localized: "\(name) · on", comment: "HUD after turning something on; %@ is a utility or option")
            : String(localized: "\(name) · off", comment: "HUD after turning something off; %@ is a utility or option")
    }
}
