import AppKit
import Carbon.HIToolbox
import MacToysCore

/// Calculator: evaluates expressions as you type; ↵ copies the result.
@MainActor
final class CalculatorProvider: SearchProvider {
    let id = "calc"
    let name = String(localized: "Calculator")
    let summary = String(localized: "Evaluate math expressions: \("sqrt(2) * 100, 0xFF + 1, 2^10, 15% of 80")",
                         comment: "%@ lists example expressions (not translated)")
    let icon = ItemIcon.symbol("plus.forwardslash.minus", .graphite)
    let defaultKeyword = "="
    let examples = ["sqrt(2) * 100", "2(3+4)^2", "0xFF + 0b1010 in hex", "sin(pi/2)", "200 + 15%", "max(3, 7, 2)"]

    private let engine: LauncherEngine
    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Calculator"), subtitle: String(localized: "Evaluate math expressions"),
                     keywords: ["math", "calc", "compute"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return [hint(String(localized: "Type an expression"),
                         String(localized: "e.g. \("sqrt(2) * 100, 2^10, 0xFF in bin, 15% of 80 → 80 * 15%")",
                                comment: "Hint; %@ lists example queries (not translated)"))]
        }
        let o = engine.options.value
        let calc = Calculator(angleUnit: o.angleUnit)
        do {
            let r = try calc.evaluate(text)
            guard query.scoped || !r.isTrivial else { return [] }
            return items(for: r, expression: text, options: o, scoped: query.scoped)
        } catch let error as CalcError {
            guard query.scoped else { return [] }
            return [hint(String(localized: "Invalid expression"), error.localizedDescription)]
        } catch {
            return []
        }
    }

    func resolve(_ id: String) -> PaletteItem? {
        if let c = commands.first(where: { $0.id == id }) { return c }
        guard id.hasPrefix("calc:") else { return nil }
        let expression = String(id.dropFirst(5))
        let o = engine.options.value
        guard let r = try? Calculator(angleUnit: o.angleUnit).evaluate(expression) else { return nil }
        return items(for: r, expression: expression, options: o, scoped: true).first
    }

    func items(for r: Calculator.Result, expression: String, options o: ProviderOptions, scoped: Bool) -> [PaletteItem] {
        let main: String
        if r.base != .decimal, let s = CalcFormatter.integer(r.value, base: r.base) {
            main = s
        } else {
            main = CalcFormatter.decimal(r.value)
        }
        var out = [resultItem(id: "calc:\(expression)", value: main, subtitle: String(localized: "Calculator · ↵ copies the result"),
                              expression: expression, score: 950, rows: detailRows(r.value, options: o))]
        if o.calcShowScientific, scoped || r.value.magnitude >= 1e6 || (r.value.magnitude < 1e-4 && r.value != 0) {
            let sci = CalcFormatter.scientific(r.value)
            if sci != main {
                out.append(resultItem(id: "calc:sci:\(expression)", value: sci, subtitle: String(localized: "Scientific notation"),
                                      expression: expression, score: 940, copyValue: String(format: "%.14e", r.value),
                                      symbol: "sum"))
            }
        }
        if o.calcShowBases, r.value == r.value.rounded(), r.value.magnitude < 9e15, r.value.magnitude >= 2 || scoped {
            for base in [NumberBase.hex, .binary, .octal, .decimal] where base != r.base {
                guard let s = CalcFormatter.integer(r.value, base: base), s != main else { continue }
                if base == .decimal && r.base == .decimal { continue }
                out.append(resultItem(id: "calc:\(base.rawValue):\(expression)", value: s, subtitle: base.title,
                                      expression: expression, score: 930, symbol: "number"))
            }
        }
        for i in out.indices { out[i].isPinnable = false }
        return out
    }

    private func detailRows(_ v: Double, options o: ProviderOptions) -> [DetailRow] {
        var rows = [DetailRow(label: NumberBase.decimal.title, value: CalcFormatter.decimal(v)),
                    DetailRow(label: String(localized: "Scientific", comment: "Detail row: the result in scientific notation"),
                              value: CalcFormatter.scientific(v))]
        if v == v.rounded(), v.magnitude < 9e15 {
            for base in [NumberBase.hex, .binary, .octal] {
                if let s = CalcFormatter.integer(v, base: base) { rows.append(DetailRow(label: base.title, value: s)) }
            }
        }
        rows.append(DetailRow(label: String(localized: "Angles", comment: "Detail row: the angle unit trigonometry uses"),
                              value: o.angleUnit.title, monospaced: false))
        return rows
    }

    private func resultItem(id: String, value: String, subtitle: String, expression: String, score: Double,
                            copyValue: String? = nil, symbol: String = "equal", rows: [DetailRow] = []) -> PaletteItem {
        let copyText = copyValue ?? value
        return PaletteItem(
            id: id, title: value, subtitle: subtitle, icon: .symbol(symbol == "equal" ? "plus.forwardslash.minus" : symbol, .graphite),
            providerID: self.id, accessory: Labels.copy, score: score,
            primary: PaletteAction(id: "copy", title: Labels.copy, symbol: "doc.on.doc") {
                Launch.copy(copyText)
                HUD.show("Copied \(copyText)", symbol: "doc.on.doc")
                return .dismiss
            },
            actions: [
                PaletteAction(id: "paste", title: Labels.pasteResult, symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                    Launch.pasteOutcome(copyText)
                },
                PaletteAction(id: "copyequation", title: String(localized: "Copy Equation"), symbol: "equal.square") {
                    Launch.copy("\(expression) = \(copyText)")
                    return .dismiss
                },
                PaletteAction(id: "usequery", title: String(localized: "Calculate with Result"), symbol: "arrow.uturn.backward",
                              shortcut: Shortcut.cmd(kVK_Return, shift: true)) { .setQuery(copyText) },
            ],
            details: ItemDetails(icon: .symbol("plus.forwardslash.minus", .graphite), title: value, largeTitle: true,
                                 subtitle: expression, rows: rows))
    }

    private func hint(_ title: String, _ subtitle: String) -> PaletteItem {
        PaletteItem(id: "calc:hint", title: title, subtitle: subtitle, icon: icon, providerID: id,
                    primary: PaletteAction(id: "none", title: Labels.ok, symbol: "checkmark", recordsUsage: false) { .stay },
                    isPinnable: false)
    }
}

