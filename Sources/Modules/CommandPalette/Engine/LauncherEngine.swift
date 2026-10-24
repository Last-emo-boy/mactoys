import AppKit
import MacToysCore

/// The search engine shared by Command Palette and Run: the providers, their shared options and
/// usage history. Each front end retains it while running; providers activate on first use.
@MainActor
final class LauncherEngine {
    static let shared = LauncherEngine()

    let options = Persisted("cmdpal-providers", default: ProviderOptions())
    let usage = UsageStore(file: Paths.data(for: "cmdpal").appendingPathComponent("usage.json"))
    private(set) var providers: [any SearchProvider] = []
    private var users: Set<String> = []
    private var changeObservers: [String: (String) -> Void] = [:]
    private var pendingChanges: Set<String> = []

    private init() {
        providers = [
            AppsProvider(engine: self), FilesProvider(engine: self), CalculatorProvider(engine: self),
            UnitsProvider(engine: self), TimeProvider(engine: self), URLProvider(engine: self),
            WebSearchProvider(engine: self), ShellProvider(engine: self), WindowsProvider(engine: self),
            SystemCommandsProvider(engine: self), SystemSettingsProvider(), ClipboardProvider(engine: self),
            BookmarksProvider(engine: self), ProcessesProvider(engine: self), ValueProvider(),
            HomebrewProvider(engine: self), MacToysProvider(), ScriptsProvider(engine: self),
            EditorsProvider(engine: self), HistoryProvider(engine: self),
        ]
        options.onChange { [weak self] _ in
            guard let self, self.isActive else { return }
            for p in self.providers { p.optionsChanged() }
        }
    }

    var isActive: Bool { !users.isEmpty }

    func provider(_ id: String) -> (any SearchProvider)? { providers.first { $0.id == id } }

    /// Rebuilds an item from its id; the provider is the id's prefix before the first ":".
    func resolve(_ id: String) -> PaletteItem? {
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return provider(String(id[..<colon]))?.resolve(id)
    }

    /// The page behind a page command id (`clipboard:page`).
    func page(for id: String) -> ListPage? {
        guard id.hasSuffix(":page"), let p = provider(String(id.dropLast(5))) else { return nil }
        return p.page
    }

    /// Starts the providers for a launcher (`cmdpal`, `run`). Idempotent per user.
    func retain(_ user: String) {
        let first = users.isEmpty
        guard users.insert(user).inserted, first else { return }
        for p in providers { p.activate() }
    }

    func release(_ user: String) {
        guard users.remove(user) != nil, users.isEmpty else { return }
        for p in providers { p.deactivate() }
        usage.flush()
        options.flush()
    }

    func launcherWillShow() {
        for p in providers { p.launcherWillShow() }
    }

    /// Launchers observe provider data changes that happen outside a search (an index finished).
    func observeChanges(_ user: String, _ handler: ((String) -> Void)?) {
        changeObservers[user] = handler
    }

    /// Called by providers; coalesced so several changes cause one refresh.
    func notifyChange(_ providerID: String) {
        let first = pendingChanges.isEmpty
        pendingChanges.insert(providerID)
        guard first else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let changed = self.pendingChanges
                self.pendingChanges.removeAll()
                for id in changed { for o in self.changeObservers.values { o(id) } }
            }
        }
    }

    /// Every enabled provider's top-level commands, given an enabled filter.
    func commands(where enabled: (any SearchProvider) -> Bool) -> [PaletteItem] {
        providers.filter(enabled).flatMap(\.commands)
    }
}
