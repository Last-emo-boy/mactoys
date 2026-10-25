import AppKit
import MacToysCore
import SwiftUI

/// PowerToys Run: the compact launcher driven by plugin keywords. Shares the search
/// engine with Command Palette.
@MainActor
public final class RunModule: ToyModule {
    public let info = ModuleInfo(
        id: "run", name: "Run",
        summary: "A quick launcher with plugin keywords: = calculator, > shell, // URLs, < windows and more.",
        symbol: "magnifyingglass.circle.fill", tint: .blue, category: .systemTools,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["launcher", "powertoys run", "plugins", "calculator", "keywords"])

    let settings = Persisted("run", default: RunSettings())
    let engine = LauncherEngine.shared
    private(set) lazy var model = makeModel()
    private lazy var window = makeWindow()
    private var running = false
    private var observing = false

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        engine.retain(info.id)
        if !observing {
            observing = true
            settings.onChange { [weak self] _ in self?.settingsChanged() }
        }
        engine.observeChanges(info.id) { [weak self] _ in
            guard let self, self.window.isVisible, self.model.currentPage == nil, !self.model.query.isEmpty else { return }
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
        HotkeyCenter.shared.register("\(info.id).activate", s.activation) { [weak self] in self?.activationPressed() }
        if let clip = engine.provider("clipboard"), s.plugin(for: clip).enabled {
            ClipboardHistory.shared.retain(info.id)
        } else {
            ClipboardHistory.shared.release(info.id)
        }
        model.searchDelay = s.searchDelay / 1000
        if window.isVisible { model.refresh() }
    }

    private func activationPressed() {
        if window.isVisible { window.dismissLauncher(restoreFocus: true); return }
        if settings.value.ignoreInFullScreen, FullScreenCheck.frontmostIsFullScreen() { return }
        open()
    }

    func open(query: String? = nil) {
        let s = settings.value
        engine.launcherWillShow()
        model.searchDelay = s.searchDelay / 1000
        model.opened(keepQuery: !s.clearOnOpen && query == nil, selectText: true, returnHome: true)
        if let query { model.query = query }
        window.show()
        window.launcherLayoutChanged()
    }

    /// A configured model; the live one is `model`, previews make their own.
    func makeModel() -> LauncherModel {
        let m = LauncherModel(engine: engine, frontEnd: .run)
        m.rootPlan = { [weak self] q, _ in self?.rootPlan(q) ?? .sections([]) }
        m.behavior = { LauncherBehavior(escape: .back, backspaceGoesBack: true, singleClickActivates: false, numberKeys: .run) }
        m.afterRun = { [weak self, weak m] in
            guard let self, self.settings.value.clearOnLaunch else { return }
            m?.clearForNextOpen()
        }
        return m
    }

    private func makeWindow() -> LauncherWindow {
        let w = LauncherWindow(model: model) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(RunContainer(module: self))
        }
        w.verticalFraction = 0.24
        w.size = { [weak self] in
            guard let self else { return CGSize(width: RunLayout.width, height: RunLayout.searchHeight) }
            let s = self.settings.value
            return CGSize(width: RunLayout.width,
                          height: RunLayout.height(self.model, maxRows: s.maxResults, showHints: s.showPluginHints && !self.hints.isEmpty))
        }
        w.screen = { [weak self] in self?.settings.value.screen ?? .mouse }
        w.openSettings = { [weak self] in ModuleRegistry.shared.showSettings?(self?.info.id) }
        return w
    }

    // MARK: Search plan

    var enabledProviders: [any SearchProvider] {
        let s = settings.value
        return engine.providers.filter { s.plugin(for: $0).enabled }
    }

    /// Keyword chips for the symbolic keywords of enabled plugins, plus `?` help.
    var hints: [RunHint] {
        guard settings.value.showPluginHints else { return [] }
        let short: [String: String] = [
            "calc": String(localized: "Calc", comment: "Run keyword chip: short for Calculator"),
            "shell": String(localized: "Shell", comment: "Provider name: shell commands"),
            "url": String(localized: "URL", comment: "A web address (row label, Run keyword chip)"),
            "windows": String(localized: "Windows", comment: "Provider name: open windows"),
            "units": String(localized: "Units", comment: "Run keyword chip: short for Unit Converter"),
            "settings": String(localized: "Settings", comment: "Row label: opens a utility's settings; Run keyword chip: System Settings"),
            "history": String(localized: "History", comment: "Provider name: results selected before"),
            "files": String(localized: "Files", comment: "Provider name: file search; also the kind of a clipboard entry with several files"),
            "values": String(localized: "Values", comment: "Run keyword chip: short for Value Generator"),
        ]
        let order = ["calc", "shell", "url", "windows", "units", "settings", "history"]
        var out: [RunHint] = order.compactMap { id in
            guard let p = engine.provider(id), let kw = Optional(settings.value.plugin(for: p)), kw.enabled, !kw.keyword.isEmpty else { return nil }
            return RunHint(keyword: kw.keyword, label: short[id] ?? p.name)
        }
        out.append(RunHint(keyword: "?", label: String(localized: "Help", comment: "Run keyword chip: ? lists every plugin")))
        return out
    }

    private func rootPlan(_ raw: String) -> RootPlan {
        let s = settings.value
        let lead = String(raw.drop { $0 == " " })
        guard !lead.isEmpty else { return .sections([]) }
        let enabled = enabledProviders
        var entries = enabled.map { KeywordParser.Entry(target: $0.id, keyword: s.plugin(for: $0).keyword) }
        entries.append(KeywordParser.Entry(target: "run:help", keyword: "?"))
        let boost = s.usageWeight / 5
        if let m = KeywordParser.match(lead, entries) {
            if m.target == "run:help" { return .sections(helpSections(m.rest)) }
            if let p = engine.provider(m.target) {
                let q = SearchQuery(text: m.rest, scoped: true, frontEnd: .run)
                return .sources([SearchSession.Source(provider: p, query: q)], boost: boost, layout: .flat(limit: 200))
            }
        }
        let text = lead.trimmingCharacters(in: .whitespaces)
        let q = SearchQuery(text: text, scoped: false, frontEnd: .run)
        let sources = enabled.filter { s.plugin(for: $0).global }.map { SearchSession.Source(provider: $0, query: q) }
        return .sources(sources, boost: boost, layout: .flat(limit: 40))
    }

    /// `?`: every enabled plugin with its keyword; ↵ puts the keyword in the box.
    private func helpSections(_ filter: String) -> [ResultSection] {
        let s = settings.value
        let items = enabledProviders.compactMap { p -> PaletteItem? in
            let kw = s.plugin(for: p).keyword
            let subtitle = p.examples.first.map {
                String(localized: "\(p.summary) · e.g. \($0)", comment: "Run help: %1$@ describes a plugin, %2$@ is an example query")
            } ?? p.summary
            let exampleLabel = String(localized: "Example", comment: "Subtitle of an example query")
            let item = PaletteItem(
                id: "run:help:\(p.id)", title: kw.isEmpty ? p.name : "\(kw)   \(p.name)",
                subtitle: subtitle, icon: p.icon, providerID: "run", score: 0,
                primary: PaletteAction(id: "use", title: String(localized: "Use Keyword"), symbol: "arrow.right", recordsUsage: false) {
                    kw.isEmpty ? .stay : .setQuery(kw + " ")
                },
                details: ItemDetails(icon: p.icon, title: p.name, subtitle: p.summary,
                                     rows: [DetailRow(label: String(localized: "Keyword", comment: "Detail row: the plugin's Run keyword"),
                                                      value: kw.isEmpty ? "—" : kw),
                                            DetailRow(label: String(localized: "Global results", comment: "Detail row: whether results show without the keyword"),
                                                      value: s.plugin(for: p).global ? String(localized: "Yes") : String(localized: "No"),
                                                      monospaced: false)]
                                         + p.examples.map { DetailRow(label: exampleLabel, value: $0) }),
                isPinnable: false, keywords: [kw, p.summary])
            return item
        }
        let filtered = fuzzyFilter(items, filter)
        return filtered.isEmpty ? [] : [ResultSection(id: "help", title: "", items: filtered)]
    }

    func helpSectionsForPreview() -> [ResultSection] { helpSections("") }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(RunSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "run.open", title: "Run", symbol: "magnifyingglass.circle.fill", tint: .blue,
                     shortcut: settings.value.activation) { [weak self] in self?.open() }]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Open Run", settings.value.activation),
         ShortcutBinding("Run result 1–9", keys: ["⌥", "1…9"]),
         ShortcutBinding("Result actions", keys: ["⌘", "K"])]
    }

    /// `mactoys://run/show?query=…`, `toggle`, `hide`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "show", "open":
            guard isEnabled else { ModuleRegistry.shared.showSettings?(info.id); return true }
            open(query: command.parameters["query"])
            return true
        case "toggle":
            guard isEnabled else { return false }
            window.isVisible ? window.dismissLauncher(restoreFocus: true) : open()
            return true
        case "hide":
            window.dismissLauncher(restoreFocus: true)
            return true
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] { RunPreviews.scenes(for: self) }
}

/// Redraws the Run bar when settings change.
struct RunContainer: View {
    let module: RunModule
    @State private var settings: Persisted<RunSettings>

    init(module: RunModule) {
        self.module = module
        _settings = State(initialValue: module.settings)
    }

    var body: some View {
        let s = settings.value
        return RunView(model: module.model, hints: module.hints, maxRows: s.maxResults)
    }
}

extension CommandPaletteModule {
    /// Extra modules that live in this target.
    public static var companions: [any ToyModule] { [RunModule()] }
}
