import AppKit
import MacToysCore

/// Unit converter: `10 km to mi`, `%% 100 f in c`, `1.5 GiB to MB`.
@MainActor
final class UnitsProvider: SearchProvider {
    let id = "units"
    let name = String(localized: "Unit Converter")
    let summary = String(localized: "Convert length, mass, temperature, volume, area, speed, data, time and more")
    let icon = ItemIcon.symbol("ruler", .teal)
    let defaultKeyword = "%%"
    let examples = ["10 km to mi", "100 f in c", "1.5 GiB to MB", "90 min to h", "5 sq m to sqft"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Unit Converter"), subtitle: String(localized: "Convert between units"), keywords: ["convert", "units"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return [PaletteItem(id: "units:hint", title: String(localized: "Type a quantity and a unit"),
                                subtitle: String(localized: "e.g. \("10 km to mi · 100 f in c · 1.5 GiB to MB · 90 min to h")",
                                                 comment: "Hint; %@ lists example queries (not translated)"),
                                icon: icon, providerID: id,
                                primary: PaletteAction(id: "none", title: Labels.ok, symbol: "checkmark", recordsUsage: false) { .stay },
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
            icon: icon, providerID: id, accessory: Labels.copy, score: score,
            primary: PaletteAction(id: "copy", title: Labels.copy, symbol: "doc.on.doc") {
                Launch.copy(copyText)
                HUD.show("Copied \(copyText)", symbol: "doc.on.doc")
                return .dismiss
            },
            actions: [
                PaletteAction(id: "copyunit", title: engine.options.value.unitsCopyWithUnit ? String(localized: "Copy Number Only")
                                : String(localized: "Copy with Unit"),
                              symbol: "textformat") {
                    Launch.copy(self.engine.options.value.unitsCopyWithUnit ? value : withUnit)
                    return .dismiss
                },
                PaletteAction(id: "paste", title: Labels.pasteResult, symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                    Launch.pasteOutcome(copyText)
                },
            ],
            details: ItemDetails(icon: icon, title: withUnit, largeTitle: true, subtitle: request,
                                 rows: [DetailRow(label: String(localized: "From", comment: "Detail row: the quantity converted from"),
                                                  value: "\(UnitConverter.format(c.value)) \(c.from.symbol)"),
                                        DetailRow(label: String(localized: "To", comment: "Detail row: the converted quantity"), value: withUnit),
                                        DetailRow(label: Labels.category,
                                                  value: c.from.category.title, monospaced: false)]),
            isPinnable: false)
    }
}
