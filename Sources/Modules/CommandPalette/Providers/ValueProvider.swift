import AppKit
import MacToysCore

/// Value generator (`#`): UUIDs, hashes, Base64 and URL encoding.
@MainActor
final class ValueProvider: SearchProvider {
    let id = "values"
    let name = "Value Generator"
    let summary = "UUIDs (v1, v3, v4, v5, v7), MD5/SHA hashes, Base64 and URL encoding"
    let icon = ItemIcon.symbol("number.circle.fill", .mint)
    let defaultKeyword = "#"
    let examples = ["# uuid", "# uuidv7", "# uuidv5 ns:URL https://example.com", "# sha256 hello", "# base64 hello",
                    "# base64d aGVsbG8=", "# url a b&c", "# esc:hex z"]

    var commands: [PaletteItem] {
        [pageCommand(title: "Generate Values", subtitle: "UUIDs, hashes, Base64 and URL encoding",
                     keywords: ["uuid", "guid", "hash", "md5", "sha", "base64", "encode"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            guard query.scoped else { return [] }
            return examples.enumerated().map { i, e in
                let cmd = String(e.dropFirst(2))
                return PaletteItem(id: "values:example:\(cmd)", title: cmd, subtitle: "Example", icon: icon, providerID: id,
                                   section: "Examples", score: 500 - Double(i),
                                   primary: PaletteAction(id: "use", title: "Use", symbol: "arrow.right", recordsUsage: false) {
                                       .setQuery(query.frontEnd == .run ? e : cmd + (cmd.contains(" ") ? "" : " "))
                                   }, isPinnable: false)
            }
        }
        guard let result = ValueGenerator.generate(text) else { return [] }
        switch result {
        case .success(let outputs):
            return outputs.enumerated().map { i, o in
                PaletteItem(id: "values:\(text):\(i)", title: o.value, subtitle: o.title, icon: icon, providerID: id,
                            accessory: "Copy", score: 980 - Double(i),
                            primary: PaletteAction(id: "copy", title: "Copy", symbol: "doc.on.doc") {
                                Launch.copy(o.value)
                                HUD.show("Copied \(o.title)", symbol: "doc.on.doc")
                                return .dismiss
                            },
                            actions: [PaletteAction(id: "paste", title: "Paste", symbol: "doc.on.clipboard", shortcut: ActionKeys.paste) {
                                Launch.pasteOutcome(o.value)
                            }],
                            details: ItemDetails(icon: icon, title: o.title, subtitle: text, body: o.value, bodyMonospaced: true),
                            isPinnable: false)
            }
        case .failure(let failure):
            guard query.scoped else { return [] }
            let message: String
            switch failure {
            case .missingInput(let what): message = "Type \(what)"
            case .invalid(let why): message = why
            }
            return [PaletteItem(id: "values:error", title: message, subtitle: name, icon: .symbol("exclamationmark.triangle.fill", .orange),
                                providerID: id, score: 900,
                                primary: PaletteAction(id: "none", title: "OK", symbol: "checkmark", recordsUsage: false) { .stay },
                                isPinnable: false)]
        }
    }
}
