import AppKit
import MacToysCore
import SwiftUI

/// Offscreen scenes for `MacToys --snapshot … --only cmdpal`, filled with realistic sample data
/// built by the real providers.
@MainActor
enum PalettePreviews {
    /// 24 October 2026, 22:41:08 in Shanghai: the moment on the design board.
    static let sampleDate = Date(timeIntervalSince1970: 1_792_852_868)
    static let sampleZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func scenes(for module: CommandPaletteModule) -> [PreviewScene] {
        [
            PreviewScene("palette", size: CGSize(width: 900, height: 640)) {
                let model = module.makeModel()
                model.showPreview(query: "time", sections: timeSections(module), shelf: module.shelfItems())
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: PaletteLayout.fullHeight))
            },
            PreviewScene("compact", size: CGSize(width: 900, height: 260)) {
                let model = module.makeModel()
                model.collapsesWhenEmpty = true
                model.showPreview(query: "", sections: [], shelf: module.shelfItems(), expanded: false)
                let height = PaletteLayout.searchHeight + PaletteLayout.shelfHeight
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: height))
            },
            PreviewScene("actions", size: CGSize(width: 900, height: 640)) {
                let model = module.makeModel()
                model.showPreview(query: "term", sections: terminalSections(module), shelf: module.shelfItems())
                model.toggleActionsMenu()
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: PaletteLayout.fullHeight))
            },
            PreviewScene("clipboard", size: CGSize(width: 900, height: 640)) {
                let model = module.makeModel()
                let page = ListPage(id: "clipboard:page", title: "Clipboard History", placeholder: "Search clipboard…",
                                    icon: .symbol("doc.on.clipboard.fill", .purple)) { _ in [] }
                model.showPreview(query: "", sections: clipboardSections(module), page: page)
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: PaletteLayout.fullHeight))
            },
        ]
    }

    static func framed<V: View>(_ view: V, height: CGFloat) -> some View {
        view.frame(width: PaletteLayout.width, height: height)
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The "time" search of the design: Time & Date, System Settings, Apps, Web.
    static func timeSections(_ module: CommandPaletteModule) -> [ResultSection] {
        let engine = module.engine
        var sections: [ResultSection] = []
        if let time = engine.provider("time") as? TimeProvider {
            let items = time.items(for: .now(.time), now: sampleDate, zone: sampleZone, locale: Locale(identifier: "en_GB"), scoped: false)
            let london = items.first { $0.id.hasSuffix("Europe/London") }
            sections.append(ResultSection(id: "time", title: "Time & Date", items: [items[0]] + (london.map { [$0] } ?? [])))
        }
        if let settings = engine.provider("settings") as? SystemSettingsProvider {
            let panes = ["screentime", "datetime"].compactMap { id in SystemSettingsProvider.panes.first { $0.id == id } }
            sections.append(ResultSection(id: "settings", title: "System Settings", items: panes.map { settings.item($0, score: 0) }))
        }
        sections.append(ResultSection(id: "apps", title: "Apps", items: [app("/Applications/Time Machine.app", name: "Time Machine",
                                                                             symbol: "clock.arrow.circlepath", tint: .green)]))
        if let web = engine.provider("web") as? WebSearchProvider, let item = web.item("time") {
            sections.append(ResultSection(id: "web", title: "Web", items: [item]))
        }
        return sections
    }

    static func terminalSections(_ module: CommandPaletteModule) -> [ResultSection] {
        let apps = module.engine.provider("apps") as? AppsProvider
        let terminal = apps?.previewItem(path: "/System/Applications/Utilities/Terminal.app")
            ?? app("/System/Applications/Utilities/Terminal.app", name: "Terminal", symbol: "terminal.fill", tint: .graphite)
        var items = [terminal]
        if let shell = module.engine.provider("shell") as? ShellProvider {
            items.append(shell.item("term", mode: .terminal, score: 0))
        }
        return [ResultSection(id: "apps", title: "Apps", items: [terminal]),
                ResultSection(id: "shell", title: "Shell", items: Array(items.dropFirst()))]
    }

    static func clipboardSections(_ module: CommandPaletteModule) -> [ResultSection] {
        guard let clip = module.engine.provider("clipboard") as? ClipboardProvider else { return [] }
        let now = Date()
        let samples: [ClipItem] = [
            sampleClip(now.addingTimeInterval(-40), .text, "https://learn.microsoft.com/windows/powertoys/command-palette/overview", app: "Safari"),
            sampleClip(now.addingTimeInterval(-300), .text, "swift build --target CommandPalette && swift test --filter CalculatorTests",
                       app: "Terminal"),
            sampleClip(now.addingTimeInterval(-1800), .text,
                       "Hi Ada,\n\nThe launcher review is moved to Thursday 14:00. I’ll send the notes afterwards.\n\nThanks!", app: "Mail"),
            sampleClip(now.addingTimeInterval(-7200), .files, "/Applications/Safari.app", app: "Finder",
                       files: [URL(fileURLWithPath: "/Applications/Safari.app")]),
            sampleClip(now.addingTimeInterval(-86400), .text, "#0A84FF", app: "MacToys"),
        ].compactMap { $0 }
        guard let pinned = sampleClip(now.addingTimeInterval(-3 * 86400), .text, "ssh debian@build.example.net -p 2222", app: "Notes",
                                      pinned: true) else { return [] }
        let items = ([pinned] + samples).enumerated().map { i, c in clip.item(c, score: 1000 - Double(i)) }
        return [ResultSection(id: "pinned", title: "Pinned", items: Array(items.prefix(1))),
                ResultSection(id: "recent", title: "Recent", items: Array(items.dropFirst()))]
    }

    /// Mirrors `ClipItem`'s stored properties so sample entries can be decoded (its initializer is internal to Core).
    private struct ClipSample: Encodable {
        var id = UUID()
        var date: Date
        var kind: ClipItem.Kind
        var text: String?
        var files: [URL]
        var sourceApp: String?
        var pinned: Bool
    }

    static func sampleClip(_ date: Date, _ kind: ClipItem.Kind, _ text: String, app: String, files: [URL] = [],
                           pinned: Bool = false) -> ClipItem? {
        let sample = ClipSample(date: date, kind: kind, text: text, files: files, sourceApp: app, pinned: pinned)
        guard let data = try? JSONEncoder().encode(sample) else { return nil }
        return try? JSONDecoder().decode(ClipItem.self, from: data)
    }

    static func app(_ path: String, name: String, symbol: String, tint: Tint) -> PaletteItem {
        let exists = FileManager.default.fileExists(atPath: path)
        return PaletteItem(id: "apps:\(path)", title: name, subtitle: path, icon: exists ? .file(path) : .symbol(symbol, tint),
                           providerID: "apps", accessory: "App",
                           primary: PaletteAction(id: "open", title: "Open", symbol: "arrow.up.forward.app") { .stay },
                           details: ItemDetails(icon: exists ? .file(path) : .symbol(symbol, tint), title: name, subtitle: "Application",
                                                rows: [DetailRow(label: "Kind", value: "Application", monospaced: false),
                                                       DetailRow(label: "Where", value: "/Applications", monospaced: false)]))
    }
}

@MainActor
enum RunPreviews {
    static func scenes(for module: RunModule) -> [PreviewScene] {
        [
            PreviewScene("run", size: CGSize(width: 760, height: 330)) {
                let model = module.makeModel()
                var items: [PaletteItem] = []
                if let calc = module.engine.provider("calc") as? CalculatorProvider,
                   let r = try? Calculator().evaluate("sqrt(2) * 100") {
                    items = Array(calc.items(for: r, expression: "sqrt(2) * 100", options: ProviderOptions(), scoped: true).prefix(2))
                }
                model.showPreview(query: "= sqrt(2) * 100", sections: [ResultSection(id: "results", title: "", items: items)])
                let hints = module.hints
                let height = RunLayout.height(model, maxRows: 4, showHints: !hints.isEmpty)
                return AnyView(
                    RunView(model: model, hints: hints, maxRows: 4)
                        .frame(width: RunLayout.width, height: height)
                        .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
            },
            PreviewScene("help", size: CGSize(width: 760, height: 420)) {
                let model = module.makeModel()
                model.showPreview(query: "?", sections: module.helpSectionsForPreview())
                let height = RunLayout.height(model, maxRows: 6, showHints: false)
                return AnyView(
                    RunView(model: model, hints: [], maxRows: 6)
                        .frame(width: RunLayout.width, height: height)
                        .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity))
            },
        ]
    }
}
