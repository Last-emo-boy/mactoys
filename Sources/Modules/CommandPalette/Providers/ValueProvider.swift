import AppKit
import MacToysCore

/// Value generator (`#`): UUIDs, hashes, Base64 and URL encoding.
@MainActor
final class ValueProvider: SearchProvider {
    let id = "values"
    let name = String(localized: "Value Generator")
    let summary = String(localized: "UUIDs (v1, v3, v4, v5, v7), MD5/SHA hashes, Base64 and URL encoding")
    let icon = ItemIcon.symbol("number.circle.fill", .mint)
    let defaultKeyword = "#"
    let examples = ["# uuid", "# uuidv7", "# uuidv5 ns:URL https://example.com", "# sha256 hello", "# base64 hello",
                    "# base64d aGVsbG8=", "# url a b&c", "# esc:hex z"]

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Generate Values"), subtitle: String(localized: "UUIDs, hashes, Base64 and URL encoding"),
                     keywords: ["uuid", "guid", "hash", "md5", "sha", "base64", "encode"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return examples.enumerated().map { i, e in
                let cmd = String(e.dropFirst(2))
                return PaletteItem(id: "values:example:\(cmd)", title: cmd,
                                   subtitle: String(localized: "Example", comment: "Subtitle of an example query"), icon: icon,
                                   providerID: id, section: String(localized: "Examples", comment: "Section heading: example queries"),
                                   score: 500 - Double(i),
                                   primary: PaletteAction(id: "use", title: Labels.use, symbol: "arrow.right", recordsUsage: false) {
                                       .setQuery(query.frontEnd == .run ? e : cmd + (cmd.contains(" ") ? "" : " "))
                                   }, isPinnable: false)
            }
        }
        guard let result = ValueGenerator.generate(text) else { return [] }
        switch result {
        case .success(let outputs):
            return outputs.enumerated().map { i, o in
                PaletteItem(id: "values:\(text):\(i)", title: o.value, subtitle: o.title, icon: icon, providerID: id,
                            accessory: Labels.copy, score: 980 - Double(i),
                            primary: PaletteAction(id: "copy", title: Labels.copy, symbol: "doc.on.doc") {
                                Launch.copy(o.value)
                                HUD.show("Copied \(o.title)", symbol: "doc.on.doc")
                                return .dismiss
                            },
                            actions: [PaletteAction(id: "paste", title: Labels.paste, symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                                Launch.pasteOutcome(o.value)
                            }],
                            details: ItemDetails(icon: icon, title: o.title, subtitle: text, body: o.value, bodyMonospaced: true),
                            isPinnable: false)
            }
        case .failure(let failure):
            guard query.scoped else { return [] }
            let message: String
            switch failure {
            case .missingInput(let m), .invalid(let m): message = m
            }
            return [PaletteItem(id: "values:error", title: message, subtitle: name, icon: .symbol("exclamationmark.triangle.fill", .orange),
                                providerID: id, score: 900,
                                primary: PaletteAction(id: "none", title: Labels.ok, symbol: "checkmark", recordsUsage: false) { .stay },
                                isPinnable: false)]
        }
    }
}
