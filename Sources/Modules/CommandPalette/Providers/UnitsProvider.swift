import AppKit
import MacToysCore

/// Unit converter: `10 km to mi`, `%% 100 f in c`, `1.5 GiB to MB`.
@MainActor
final class UnitsProvider: SearchProvider {
    let id = "units"
    let name = "Unit Converter"
    let summary = "Convert length, mass, temperature, volume, area, speed, data, time and more"
    let icon = ItemIcon.symbol("ruler", .teal)
    let defaultKeyword = "%%"
    let examples = ["10 km to mi", "100 f in c", "1.5 GiB to MB", "90 min to h", "5 sq m to sqft"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(subtitle: "Convert between units", keywords: ["convert", "units"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return [PaletteItem(id: "units:hint", title: "Type a quantity and a unit",
                                subtitle: "e.g. 10 km to mi · 100 f in c · 1.5 GiB to MB · 90 min to h",
                                icon: icon, providerID: id,
                                primary: PaletteAction(id: "none", title: "OK", symbol: "checkmark", recordsUsage: false) { .stay },
                                isPinnable: false)]
        }
        if let c = UnitConverter.convert(text) { return [item(c, score: 960)] }
        guard query.scoped else { return [] }
        return UnitConverter.suggestions(text).enumerated().map { i, c in item(c, score: 900 - Double(i)) }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("units:"), let c = UnitConverter.convert(String(id.dropFirst(6))) else { return nil }
        return item(c, score: 0)
    }

    func item(_ c: UnitConverter.Conversion, score: Double) -> PaletteItem {
        let value = UnitConverter.format(c.result)
        let withUnit = "\(value) \(c.to.symbol)"
        let copyText = engine.options.value.unitsCopyWithUnit ? withUnit : value
        let request = "\(UnitConverter.format(c.value)) \(c.from.symbol) to \(c.to.symbol)"
        return PaletteItem(
            id: "units:\(request)", title: withUnit,
            subtitle: "\(UnitConverter.format(c.value)) \(c.from.symbol) = \(withUnit) · \(c.from.category.title)",
            icon: icon, providerID: id, accessory: "Copy", score: score,
            primary: PaletteAction(id: "copy", title: "Copy", symbol: "doc.on.doc") {
                Launch.copy(copyText)
                HUD.show("Copied \(copyText)", symbol: "doc.on.doc")
                return .dismiss
            },
            actions: [
                PaletteAction(id: "copyunit", title: engine.options.value.unitsCopyWithUnit ? "Copy Number Only" : "Copy with Unit",
                              symbol: "textformat") {
                    Launch.copy(self.engine.options.value.unitsCopyWithUnit ? value : withUnit)
                    return .dismiss
                },
                PaletteAction(id: "paste", title: "Paste Result", symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                    Launch.pasteOutcome(copyText)
                },
            ],
            details: ItemDetails(icon: icon, title: withUnit, largeTitle: true, subtitle: request,
                                 rows: [DetailRow(label: "From", value: "\(UnitConverter.format(c.value)) \(c.from.symbol)"),
                                        DetailRow(label: "To", value: withUnit),
                                        DetailRow(label: "Category", value: c.from.category.title, monospaced: false)]),
            isPinnable: false)
    }
}
