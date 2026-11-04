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
                let page = ListPage(id: "clipboard:page", title: String(localized: "Clipboard History"),
                                    placeholder: String(localized: "Search \(String(localized: "Clipboard History"))…",
                                                        comment: "Search field placeholder; %@ is a provider name such as “Calculator”"),
                                    icon: .symbol("doc.on.clipboard.fill", .purple)) { _ in [] }
                model.showPreview(query: "", sections: clipboardSections(module), page: page)
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: PaletteLayout.fullHeight))
            },
            PreviewScene("menus", size: CGSize(width: 900, height: 640)) {
                let model = module.makeModel()
                let (page, sections) = menuSections(module, query: "tab")
                model.showPreview(query: "tab", sections: sections, page: page)
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: PaletteLayout.fullHeight))
            },
            PreviewScene("menus-browse", size: CGSize(width: 900, height: 640)) {
                let model = module.makeModel()
                let (page, sections) = menuSections(module, query: "")
                model.showPreview(query: "", sections: sections, page: page)
                return AnyView(framed(PaletteView(model: model, appearance: module.appearance), height: PaletteLayout.fullHeight))
            },
        ]
    }

    /// Safari's menus, searched the way the Menu Commands page does.
    static func menuSections(_ module: CommandPaletteModule, query: String) -> (ListPage, [ResultSection]) {
        let usage = MenuUsageStore(file: nil)
        let provider = MenuCommandsProvider(engine: module.engine, usage: usage)
        let safari = URL(fileURLWithPath: "/Applications/Safari.app").resolvingSymlinksInPath().path
        let target = MenuTarget(pid: 0, name: "Safari", bundleID: "com.apple.Safari",
                                bundlePath: FileManager.default.fileExists(atPath: safari) ? safari : nil)
        let commands = MenuFlattener.flatten(sampleSafariMenus)
        let now = Date()
        for (title, minutesAgo, times) in [("Reopen Last Closed Tab", 12.0, 9), ("Show All Tabs", 180.0, 3), ("Export as PDF…", 2000.0, 2)] {
            guard let c = commands.first(where: { $0.title == title }) else { continue }
            for i in 0..<times { usage.record(c.id, in: target.key, at: now.addingTimeInterval(-minutesAgo * 60 - Double(i))) }
        }
        let items = provider.items(MenuReader.Snapshot(menus: sampleSafariMenus, commands: commands, truncated: false),
                                   query: query, scoped: true, target: target, options: ProviderOptions(), now: now)
        var sections: [ResultSection] = []
        for item in items {
            let title = item.section ?? ""
            if let i = sections.firstIndex(where: { $0.title == title }) {
                sections[i].items.append(item)
            } else {
                sections.append(ResultSection(id: "s:\(title)", title: title, items: [item]))
            }
        }
        let page = ListPage(id: MenuCommandsProvider.pageID,
                            title: String(localized: "\("Safari") Menus", comment: "Page title: the menu commands of an app; %@ is the app name"),
                            placeholder: String(localized: "Search the menus of \("Safari")…", comment: "Search field placeholder; %@ is an app name"),
                            icon: target.bundlePath.map { .file($0) } ?? .symbol("safari", .blue)) { _ in [] }
        return (page, sections)
    }

    /// A believable slice of Safari's menu bar.
    static var sampleSafariMenus: [MenuNode] {
        func n(_ title: String, _ keys: [String] = [], enabled: Bool = true, checked: Bool = false) -> MenuNode {
            MenuNode(title: title, enabled: enabled, keys: keys, checked: checked)
        }
        func menu(_ title: String, _ items: [MenuNode]) -> MenuNode { MenuNode(title: title, children: items) }
        return [
            menu("Safari", [n("About Safari"), n("Settings…", ["⌘", ","]), n("Clear History…"), n("Hide Safari", ["⌘", "H"])]),
            menu("File", [n("New Window", ["⌘", "N"]), n("New Private Window", ["⇧", "⌘", "N"]), n("New Tab", ["⌘", "T"]),
                          n("Open File…", ["⌘", "O"]), n("Close Tab", ["⌘", "W"]), n("Close Other Tabs", ["⌥", "⌘", "W"], enabled: false),
                          menu("Export", [n("Export as PDF…"), n("Bookmarks…")]), n("Share…"), n("Print…", ["⌘", "P"])]),
            menu("Edit", [n("Undo Typing", ["⌘", "Z"]), n("Copy", ["⌘", "C"]), n("Paste", ["⌘", "V"]), n("Find…", ["⌘", "F"])]),
            menu("View", [n("Show All Tabs", ["⇧", "⌘", "\\"]), n("Always Show Tab Bar", checked: true),
                          n("Show Sidebar", ["⌃", "⌘", "S"]), n("Reload Page", ["⌘", "R"]), n("Enter Full Screen", ["fn", "F"])]),
            menu("History", [n("Show All History", ["⌘", "Y"]), n("Reopen Last Closed Tab", ["⇧", "⌘", "T"]),
                             n("Reopen All Windows from Last Session")]),
            menu("Bookmarks", [n("Add Bookmark…", ["⌘", "D"]), n("Add Bookmark Folder", enabled: false)]),
            menu("Window", [n("Minimize", ["⌘", "M"]), n("Show Previous Tab", ["⌃", "⇧", "⇥"]),
                            n("Move Tab to New Window", enabled: false), n("Pin Tab"), n("Merge All Windows", enabled: false)]),
            menu("Help", [n("Safari Help")]),
        ]
    }

    static func framed<V: View>(_ view: V, height: CGFloat) -> some View {
        view.frame(width: PaletteLayout.width, height: height)
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The design board's formats in English; the user's own in other languages.
    static var sampleLocale: Locale {
        Locale.current.language.languageCode == .english ? Locale(identifier: "en_GB") : .current
    }

    static func title(_ module: CommandPaletteModule, _ providerID: String) -> String {
        module.engine.provider(providerID)?.name ?? providerID
    }

    /// The "time" search of the design: Time & Date, System Settings, Apps, Web.
    static func timeSections(_ module: CommandPaletteModule) -> [ResultSection] {
        let engine = module.engine
        var sections: [ResultSection] = []
        if let time = engine.provider("time") as? TimeProvider {
            let items = time.items(for: .now(.time), now: sampleDate, zone: sampleZone, locale: sampleLocale, scoped: false)
            let london = items.first { $0.id.hasSuffix("Europe/London") }
            sections.append(ResultSection(id: "time", title: time.name, items: [items[0]] + (london.map { [$0] } ?? [])))
        }
        if let settings = engine.provider("settings") as? SystemSettingsProvider {
            let panes = ["screentime", "datetime"].compactMap { id in SystemSettingsProvider.panes.first { $0.id == id } }
            sections.append(ResultSection(id: "settings", title: settings.name, items: panes.map { settings.item($0, score: 0) }))
        }
        sections.append(ResultSection(id: "apps", title: title(module, "apps"), items: [app("/Applications/Time Machine.app", name: "Time Machine",
                                                                                            symbol: "clock.arrow.circlepath", tint: .green)]))
        if let web = engine.provider("web") as? WebSearchProvider, let item = web.item("time") {
            sections.append(ResultSection(id: "web", title: web.name, items: [item]))
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
        return [ResultSection(id: "apps", title: title(module, "apps"), items: [terminal]),
                ResultSection(id: "shell", title: title(module, "shell"), items: Array(items.dropFirst()))]
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
        return [ResultSection(id: "pinned", title: Labels.pinned, items: Array(items.prefix(1))),
                ResultSection(id: "recent", title: Labels.recent, items: Array(items.dropFirst()))]
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
                           providerID: "apps", accessory: Labels.app,
                           primary: PaletteAction(id: "open", title: Labels.open, symbol: "arrow.up.forward.app") { .stay },
                           details: ItemDetails(icon: exists ? .file(path) : .symbol(symbol, tint), title: name,
                                                subtitle: String(localized: "Application", comment: "Kind of a file: an app, like Finder shows it"),
                                                rows: [DetailRow(label: Labels.kind,
                                                                 value: String(localized: "Application", comment: "Kind of a file: an app, like Finder shows it"),
                                                                 monospaced: false),
                                                       DetailRow(label: Labels.location, value: "/Applications", monospaced: false)]))
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
