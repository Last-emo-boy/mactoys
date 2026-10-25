import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// PowerToys Command Palette: one search box for apps, files, windows, commands, clipboard
/// history and more, with nested pages, a quick access shelf, aliases and command hotkeys.
@MainActor
public final class CommandPaletteModule: ToyModule {
    public let info = ModuleInfo(
        id: "cmdpal", name: "Command Palette",
        summary: "Search apps, files, windows, commands, clipboard history and more from one box.",
        symbol: "command", tint: .blue, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["launcher", "spotlight", "search", "raycast", "alfred", "quick access", "shelf", "alias"])

    let settings = Persisted("cmdpal", default: CommandPaletteSettings())
    let engine = LauncherEngine.shared
    private(set) lazy var model = makeModel()
    private lazy var window = makeWindow()
    private var running = false
    private var observing = false
    private let log = Log.for("cmdpal")

    public init() {}

    // MARK: Lifecycle

    public func start() {
        guard !running else { return }
        running = true
        engine.retain(info.id)
        if !observing {
            observing = true
            settings.onChange { [weak self] _ in self?.settingsChanged() }
            engine.options.onChange { [weak self] _ in self?.settingsChanged() }
        }
        engine.observeChanges(info.id) { [weak self] _ in
            guard let self, self.window.isVisible, self.model.currentPage == nil else { return }
            self.model.reloadShelf()
            self.model.refresh()
        }
        settingsChanged()
    }

    public func stop() {
        guard running else { return }
        running = false
        window.tearDown()
        HotkeyCenter.shared.unregister(prefix: "\(info.id).")
        ClipboardHistory.shared.release(info.id)
        engine.observeChanges(info.id, nil)
        engine.release(info.id)
        settings.flush()
    }

    private func settingsChanged() {
        guard running else { return }
        let s = settings.value
        HotkeyCenter.shared.unregister(prefix: "\(info.id).")
        HotkeyCenter.shared.register("\(info.id).activate", s.activation) { [weak self] in self?.activationPressed() }
        for (i, hk) in s.hotkeys.enumerated() {
            guard let shortcut = hk.shortcut else { continue }
            let target = hk.target
            HotkeyCenter.shared.register("\(info.id).command.\(i)", shortcut) { [weak self] in self?.runCommand(target) }
        }
        if let clip = engine.provider("clipboard"), s.toggle(for: clip).enabled {
            ClipboardHistory.shared.retain(info.id)
        } else {
            ClipboardHistory.shared.release(info.id)
        }
        model.collapsesWhenEmpty = s.openMode == .compact
        if window.isVisible { model.reloadShelf(); window.launcherLayoutChanged() }
    }

    private func activationPressed() {
        if window.isVisible { window.dismissLauncher(restoreFocus: true); return }
        if settings.value.ignoreInFullScreen, FullScreenCheck.frontmostIsFullScreen() { return }
        open()
    }

    // MARK: Opening

    /// Shows the palette at Home (or where it was, depending on settings).
    func open(query: String? = nil, page: ListPage? = nil, filter: String? = nil) {
        let s = settings.value
        let elapsed = window.closedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let returnHome = s.returnHomeAfter >= 0 && elapsed >= Double(s.returnHomeAfter)
        engine.launcherWillShow()
        model.collapsesWhenEmpty = s.openMode == .compact
        if let filter { model.filter = filter } else if !s.rememberFilter { model.filter = nil }
        model.opened(keepQuery: (s.keepQuery || !returnHome) && query == nil, selectText: s.selectQueryOnOpen,
                     returnHome: returnHome || page != nil)
        if let page {
            model.push(page, query: query)
        } else if let query {
            model.query = query
        }
        window.show()
        window.launcherLayoutChanged()
    }

    /// A configured model; the live one is `model`, previews make their own.
    func makeModel() -> LauncherModel {
        let m = LauncherModel(engine: engine, frontEnd: .palette)
        m.filter = settings.value.rememberFilter ? settings.value.lastFilter.flatMap { engine.provider($0) == nil ? nil : $0 } : nil
        m.rootPlan = { [weak self] q, filter in self?.rootPlan(q, filter: filter) ?? .sections([]) }
        m.behavior = { [weak self] in
            let s = self?.settings.value ?? CommandPaletteSettings()
            return LauncherBehavior(escape: s.escapeBehavior, backspaceGoesBack: s.backspaceGoesBack,
                                    singleClickActivates: s.singleClickActivates, numberKeys: s.numberKeys)
        }
        m.metaActions = { [weak self] item in self?.metaActions(for: item) ?? [] }
        m.shelfProvider = { [weak self] in self?.shelfItems() ?? [] }
        m.onFilterChange = { [weak self] f in
            guard let self, self.settings.value.rememberFilter else { return }
            self.settings.value.lastFilter = f
        }
        m.collapsesWhenEmpty = settings.value.openMode == .compact
        return m
    }

    private func makeWindow() -> LauncherWindow {
        let w = LauncherWindow(model: model) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(PaletteContainer(module: self))
        }
        w.size = { [weak self] in
            guard let self else { return CGSize(width: PaletteLayout.width, height: PaletteLayout.fullHeight) }
            return CGSize(width: PaletteLayout.width, height: PaletteLayout.height(self.model, showShelf: self.settings.value.showShelf))
        }
        w.screen = { [weak self] in self?.settings.value.screen ?? .mouse }
        w.hidesOnResign = { [weak self] in self?.settings.value.hideOnResign ?? true }
        w.lastOrigin = { [weak self] in
            guard let o = self?.settings.value.lastOrigin, o.count == 2 else { return nil }
            return CGPoint(x: o[0], y: o[1])
        }
        w.saveOrigin = { [weak self] p in self?.settings.value.lastOrigin = [Double(p.x), Double(p.y)] }
        w.openSettings = { [weak self] in ModuleRegistry.shared.showSettings?(self?.info.id) }
        return w
    }

    var appearance: PaletteAppearance {
        let s = settings.value
        return PaletteAppearance(showShelf: s.showShelf, showDetails: s.showDetails, backgroundOpacity: s.backgroundOpacity,
                                 singleClickActivates: s.singleClickActivates,
                                 filters: enabledProviders.filter { $0.id != "history" }.map { ($0.id, $0.name) })
    }

    // MARK: Search plan

    var enabledProviders: [any SearchProvider] {
        let s = settings.value
        return engine.providers.filter { s.toggle(for: $0).enabled }
    }

    private func rootPlan(_ raw: String, filter: String?) -> RootPlan {
        let s = settings.value
        let text = raw.trimmingCharacters(in: .whitespaces)
        if let f = filter, let p = engine.provider(f), s.toggle(for: p).enabled {
            return .sources([SearchSession.Source(provider: p, query: SearchQuery(text: text, scoped: true, frontEnd: .palette))],
                            boost: 1, layout: .sections(maxPerSection: 300))
        }
        if text.isEmpty { return .sections(homeSections()) }

        var extra: [PaletteItem] = []
        let lead = String(raw.drop { $0 == " " })
        let entries = s.aliases.filter { !$0.alias.isEmpty }.map { KeywordParser.Entry(target: $0.target, keyword: $0.alias, direct: $0.direct) }
        if let m = KeywordParser.match(lead, entries) {
            let page = engine.page(for: m.target).flatMap { p -> ListPage? in
                guard let provider = engine.provider(String(m.target.dropLast(5))), s.toggle(for: provider).enabled else { return nil }
                return p
            }
            let typedSeparator = lead.count > m.keyword.count
            if let page, typedSeparator || s.aliases.first(where: { $0.target == m.target && $0.alias == m.keyword })?.direct == true {
                return .push(page, query: m.rest)
            }
            if var item = engine.resolve(m.target), m.rest.isEmpty {
                item.score = 5000
                item.section = String(localized: "Alias", comment: "Section heading: the command an alias points to")
                extra.append(item)
            }
        }

        let query = SearchQuery(text: text, scoped: false, frontEnd: .palette)
        var sources = enabledProviders.filter { s.toggle(for: $0).global }.map { SearchSession.Source(provider: $0, query: query) }
        let enabledIDs = Set(enabledProviders.map(\.id))
        let commands = CommandsSource { [weak self] in
            guard let self else { return [] }
            return self.engine.commands { enabledIDs.contains($0.id) }
        }
        sources.insert(SearchSession.Source(provider: commands, query: query), at: 0)
        if !extra.isEmpty { sources.insert(SearchSession.Source(provider: FixedSource(id: "alias", items: extra), query: query), at: 0) }
        return .sources(sources, boost: 1, layout: .sections(maxPerSection: max(1, s.resultsPerSection)))
    }

    private func homeSections() -> [ResultSection] {
        let s = settings.value
        var out: [ResultSection] = []
        if !s.showShelf {
            let pins = resolvedPins()
            if !pins.isEmpty { out.append(ResultSection(id: "home:pinned", title: Labels.pinned, items: pins)) }
        }
        if s.homeRecents == .afterPinned {
            let pinned = Set(s.pins.map(\.id))
            let recent = recentItems(limit: s.maxRecents, excluding: pinned)
            if !recent.isEmpty { out.append(ResultSection(id: "home:recent", title: Labels.recent, items: recent)) }
        }
        let enabledIDs = Set(enabledProviders.map(\.id))
        let commands = engine.commands { enabledIDs.contains($0.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        out.append(ResultSection(id: "home:commands", title: Labels.commands, items: commands))
        return out
    }

    func recentItems(limit: Int, excluding: Set<String>) -> [PaletteItem] {
        var out: [PaletteItem] = []
        for e in engine.usage.history where !excluding.contains(e.id) {
            guard out.count < limit else { break }
            guard var item = engine.resolve(e.id), item.isPinnable else { continue }
            item.section = Labels.recent
            out.append(item)
        }
        return out
    }

    private func resolvedPins() -> [PaletteItem] {
        settings.value.pins.prefix(max(0, settings.value.maxPins)).map { pin in
            if var item = engine.resolve(pin.id) {
                // The pin keeps the (short) title it was pinned with.
                item.section = Labels.pinned
                item.title = pin.title
                return item
            }
            return PaletteItem(id: pin.id, title: pin.title, subtitle: String(localized: "Not available", comment: "A pinned command that can't be found"),
                               icon: pin.icon, providerID: "cmdpal", section: Labels.pinned,
                               primary: PaletteAction(id: "none", title: String(localized: "Unavailable", comment: "Action of a pinned command that can't be found"),
                                                      symbol: "exclamationmark.triangle", recordsUsage: false) {
                                   HUD.show("“\(pin.title)” isn’t available", symbol: "exclamationmark.triangle")
                                   return .stay
                               })
        }
    }

    func shelfItems() -> [PaletteItem] {
        let s = settings.value
        guard s.showShelf else { return [] }
        var items = resolvedPins()
        if s.shelfRecents == .afterPinned {
            items += recentItems(limit: s.maxRecents, excluding: Set(s.pins.map(\.id)))
        }
        return items
    }

    // MARK: Pins, aliases, hotkeys, links

    private func metaActions(for item: PaletteItem) -> [PaletteAction] {
        guard item.isPinnable, !item.id.hasPrefix("history:") else { return [] }
        var out: [PaletteAction] = []
        let s = settings.value
        let id = item.id
        if let index = s.pins.firstIndex(where: { $0.id == id }) {
            out.append(PaletteAction(id: "meta.unpin", title: String(localized: "Unpin from Quick Access"), symbol: "pin.slash", shortcut: ActionKeys.pin,
                                     recordsUsage: false) { [weak self] in
                self?.settings.value.pins.removeAll { $0.id == id }
                return .refresh
            })
            if index > 0 {
                out.append(PaletteAction(id: "meta.left", title: String(localized: "Move Pin Left"), symbol: "arrow.left", recordsUsage: false) { [weak self] in
                    self?.settings.value.pins.swapAt(index, index - 1)
                    return .refresh
                })
            }
            if index < s.pins.count - 1 {
                out.append(PaletteAction(id: "meta.right", title: String(localized: "Move Pin Right"), symbol: "arrow.right", recordsUsage: false) { [weak self] in
                    self?.settings.value.pins.swapAt(index, index + 1)
                    return .refresh
                })
            }
        } else {
            out.append(PaletteAction(id: "meta.pin", title: String(localized: "Pin to Quick Access"), symbol: "pin", shortcut: ActionKeys.pin,
                                     recordsUsage: false) { [weak self] in
                self?.settings.value.pins.append(PinnedCommand(id: id, title: item.title, icon: item.icon))
                HUD.show("Pinned “\(item.title)”", symbol: "pin.fill")
                return .refresh
            })
        }
        if engine.usage.history.contains(where: { $0.id == id }) {
            out.append(PaletteAction(id: "meta.forget", title: String(localized: "Remove from Recent"), symbol: "clock.badge.xmark",
                                     recordsUsage: false) { [weak self] in
                self?.engine.usage.remove(id)
                return .refresh
            })
        }
        out.append(PaletteAction(id: "meta.alias", title: String(localized: "Add Alias…"), symbol: "character.cursor.ibeam",
                                 recordsUsage: false) { [weak self] in
            guard let self else { return .stay }
            return .push(self.aliasPage(for: item))
        })
        out.append(PaletteAction(id: "meta.hotkey",
                                 title: s.hotkeys.contains { $0.target == id } ? String(localized: "Change Hotkey…") : String(localized: "Assign Hotkey…"),
                                 symbol: "keyboard", recordsUsage: false) { [weak self] in
            guard let self else { return .stay }
            if !self.settings.value.hotkeys.contains(where: { $0.target == id }) {
                self.settings.value.hotkeys.append(CommandHotkey(target: id, title: item.title, icon: item.icon, shortcut: nil))
            }
            let moduleID = self.info.id
            return .dismissThen { ModuleRegistry.shared.showSettings?(moduleID) }
        })
        out.append(PaletteAction(id: "meta.link", title: String(localized: "Copy Command Link"), symbol: "link", recordsUsage: false) {
            Launch.copy(AppCommand(module: "cmdpal", action: "run", parameters: ["id": id]).url.absoluteString)
            HUD.show("Command link copied", symbol: "link")
            return .dismiss
        })
        return out
    }

    private func aliasPage(for item: PaletteItem) -> ListPage {
        ListPage(id: "cmdpal:alias:\(item.id)", title: String(localized: "Alias for \(item.title)", comment: "Page title; %@ is a command"),
                 placeholder: String(localized: "Type an alias, e.g. \("cb")", comment: "%@ is an example alias"),
                 icon: .symbol("character.cursor.ibeam", .blue)) { [weak self] text in
            guard let self else { return [] }
            let alias = text.trimmingCharacters(in: .whitespaces)
            let existing = self.settings.value.aliases.filter { $0.target == item.id }.map(\.alias)
            guard !alias.isEmpty, !alias.contains(" ") else {
                return [PaletteItem(id: "cmdpal:alias:hint",
                                    title: alias.contains(" ") ? String(localized: "An alias can’t contain spaces") : String(localized: "Type the alias"),
                                    subtitle: existing.isEmpty
                                        ? String(localized: "Typing it in the palette jumps to “\(item.title)”", comment: "%@ is a command")
                                        : String(localized: "Current: \(existing.formatted(.list(type: .and, width: .narrow)))", comment: "%@ lists the command's aliases"),
                                    icon: .symbol("character.cursor.ibeam", .blue), providerID: "cmdpal",
                                    primary: PaletteAction(id: "none", title: Labels.ok, symbol: "checkmark", recordsUsage: false) { .stay },
                                    isPinnable: false)]
            }
            let clash = self.settings.value.aliases.first { $0.alias.lowercased() == alias.lowercased() && $0.target != item.id }
            let direct = KeywordParser.isSymbolic(alias)
            return [PaletteItem(
                id: "cmdpal:alias:set",
                title: String(localized: "Use “\(alias)” for \(item.title)", comment: "%1$@ is the alias typed, %2$@ the command"),
                subtitle: clash.map { String(localized: "Replaces the alias of \($0.title)", comment: "%@ is another command") }
                    ?? (direct ? String(localized: "Direct alias: works without a space")
                        : String(localized: "Type “\(alias) ” to jump there", comment: "%@ is the alias; keep the space before the closing quote")),
                icon: item.icon, providerID: "cmdpal", accessory: String(localized: "Save", comment: "Result row label: ↵ saves the alias"),
                primary: PaletteAction(id: "save", title: String(localized: "Save Alias"), symbol: "checkmark", recordsUsage: false) { [weak self] in
                    self?.settings.update { s in
                        s.aliases.removeAll { $0.alias.lowercased() == alias.lowercased() }
                        s.aliases.append(CommandAlias(alias: alias, target: item.id, title: item.title, direct: direct))
                    }
                    HUD.show("Alias “\(alias)” saved", symbol: "character.cursor.ibeam")
                    return .back
                },
                isPinnable: false)]
        }
    }

    /// Runs a command by id: a hotkey, a pin or a command link.
    func runCommand(_ id: String) {
        if let page = engine.page(for: id) {
            open(page: page)
            return
        }
        guard let item = engine.resolve(id) else {
            HUD.show("Command not found", symbol: "questionmark.circle")
            log.error("No command \(id, privacy: .public)")
            return
        }
        engine.usage.record(item, query: "")
        switch item.primary.perform() {
        case .dismiss, .stay, .refresh, .back:
            break
        case .dismissThen(let work):
            work()
        case .push(let page):
            open(page: page)
        case .setQuery(let q):
            open(query: q)
        case .confirm(let c):
            open()
            model.handle(.confirm(c))
        }
    }

    /// A command link from outside: confirmed unless the user allowed it before.
    private func runLink(_ id: String) -> Bool {
        let s = settings.value
        guard s.enableCommandLinks else { return false }
        if s.allowedLinks.contains(id) {
            runCommand(id)
            return true
        }
        let title = engine.resolve(id)?.title ?? engine.page(for: id).map(\.title) ?? id
        open()
        model.handle(.confirm(Confirmation(
            title: String(localized: "Run “\(title)”?", comment: "Confirmation prompt; %@ is a command"),
            message: String(localized: "A link or another app asked to run this command. Continue only if you expected it."),
            confirmTitle: String(localized: "Run Once", comment: "Confirmation button: run the linked command this time"), destructive: false,
            perform: { [weak self] in
                self?.window.dismissLauncher(restoreFocus: true)
                self?.runCommand(id)
                return .stay
            },
            alternateTitle: String(localized: "Always Allow", comment: "Confirmation button: run this command from links without asking"),
            alternate: { [weak self] in
                self?.settings.value.allowedLinks.append(id)
                self?.window.dismissLauncher(restoreFocus: true)
                self?.runCommand(id)
                return .stay
            })))
        return true
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(CommandPaletteSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [
            QuickAction(id: "cmdpal.open", title: "Command Palette", symbol: "command", tint: .blue,
                        shortcut: settings.value.activation) { [weak self] in self?.open() },
            QuickAction(id: "cmdpal.clipboard", title: "Clipboard History", symbol: "doc.on.clipboard.fill", tint: .purple) { [weak self] in
                guard let self, let page = self.engine.page(for: "clipboard:page") else { return }
                self.open(page: page)
            },
        ]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list = [ShortcutBinding("Open Command Palette", s.activation),
                    ShortcutBinding("Run pinned command 1–9", keys: ["⌥", "1…9"]),
                    ShortcutBinding("Select pinned command 1–9", keys: ["⌥", "⇧", "1…9"]),
                    ShortcutBinding("More actions", keys: ["⌘", "K"])]
        for hk in s.hotkeys where hk.shortcut != nil { list.append(ShortcutBinding(hk.title, hk.shortcut)) }
        return list
    }

    /// `mactoys://cmdpal/show?query=…&page=clipboard:page&filter=apps`, `toggle`, `hide`,
    /// `run?id=<command id>`, `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "show", "open":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            let page = command.parameters["page"].flatMap { engine.page(for: $0) }
            open(query: command.parameters["query"], page: page, filter: command.parameters["filter"])
            return true
        case "toggle":
            guard isEnabled else { return false }
            window.isVisible ? window.dismissLauncher(restoreFocus: true) : open()
            return true
        case "hide":
            window.dismissLauncher(restoreFocus: true)
            return true
        case "run":
            guard isEnabled, let id = command.parameters["id"], !id.isEmpty else { return false }
            return runLink(id)
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] { PalettePreviews.scenes(for: self) }
}

/// Observes settings so the palette redraws when they change.
struct PaletteContainer: View {
    let module: CommandPaletteModule
    @State private var settings: Persisted<CommandPaletteSettings>

    init(module: CommandPaletteModule) {
        self.module = module
        _settings = State(initialValue: module.settings)
    }

    var body: some View {
        _ = settings.value
        return PaletteView(model: module.model, appearance: module.appearance)
    }
}
