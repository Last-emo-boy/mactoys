import AppKit
import MacToysCore

/// Homebrew (`brew`): search, inspect, install, upgrade and uninstall formulae and casks.
@MainActor
final class HomebrewProvider: SearchProvider {
    let id = "brew"
    let name = "Homebrew"
    let summary = "Search, install, upgrade and uninstall Homebrew formulae and casks"
    let icon = ItemIcon.symbol("mug.fill", .yellow)
    let defaultKeyword = "brew"
    let globalByDefault = false
    let examples = ["brew ripgrep", "brew  (installed packages)"]

    private let engine: LauncherEngine
    private var installedFormulae: [String: String] = [:]
    private var installedCasks: [String: String] = [:]
    private var installedAt: Date?

    init(engine: LauncherEngine) { self.engine = engine }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var commands: [PaletteItem] {
        [pageCommand(title: "Homebrew", subtitle: Self.brewPath == nil ? "Homebrew is not installed" : "Search and install packages",
                     keywords: ["brew", "install", "package", "cask", "formula"])]
    }

    func launcherWillShow() { installedAt = nil }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        guard query.scoped else { return [] }
        guard let brew = Self.brewPath else {
            return [PaletteItem(id: "brew:missing", title: "Homebrew is not installed", subtitle: "Open brew.sh to install it",
                                icon: icon, providerID: id, score: 1000,
                                primary: PaletteAction(id: "open", title: "Open brew.sh", symbol: "safari") {
                                    if let url = URL(string: "https://brew.sh") { Launch.open(url) }
                                    return .dismiss
                                }, isPinnable: false)]
        }
        await loadInstalled(brew)
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            var out = maintenanceItems()
            out += installedFormulae.sorted { $0.key < $1.key }.enumerated().map { i, kv in
                item(kv.key, cask: false, version: kv.value, score: 500 - Double(i) / 100, section: "Installed Formulae")
            }
            if engine.options.value.brewIncludeCasks {
                out += installedCasks.sorted { $0.key < $1.key }.enumerated().map { i, kv in
                    item(kv.key, cask: true, version: kv.value, score: 400 - Double(i) / 100, section: "Installed Casks")
                }
            }
            return out
        }
        // Debounce: brew is slow to start, so wait until typing pauses.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return [] }
        let includeCasks = engine.options.value.brewIncludeCasks
        async let formulae = AsyncProcess.run(brew, ["search", "--formula", text], timeout: 20)
        async let casks: AsyncProcess.Output? = includeCasks ? AsyncProcess.run(brew, ["search", "--cask", text], timeout: 20) : nil
        let f = await formulae, c = await casks
        guard !Task.isCancelled else { return [] }
        func names(_ o: AsyncProcess.Output?) -> [String] {
            guard let o, o.ok else { return [] }
            return o.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("==>") && !$0.contains(" ") }
        }
        let formulaItems = names(f).map { n in
            item(n, cask: false, version: installedFormulae[n], score: FuzzyMatcher.score(text, n) ?? 100, section: "Formulae")
        }
        let caskItems = names(c).map { n in
            item(n, cask: true, version: installedCasks[n], score: (FuzzyMatcher.score(text, n) ?? 100) - 1, section: "Casks")
        }
        if formulaItems.isEmpty && caskItems.isEmpty {
            return [PaletteItem(id: "brew:none", title: "No packages match “\(text)”", subtitle: "brew search \(text)", icon: icon,
                                providerID: id, score: 1,
                                primary: PaletteAction(id: "none", title: "OK", symbol: "checkmark", recordsUsage: false) { .stay },
                                isPinnable: false)]
        }
        return formulaItems + caskItems
    }

    private func loadInstalled(_ brew: String) async {
        if let at = installedAt, Date().timeIntervalSince(at) < 60 { return }
        async let f = AsyncProcess.run(brew, ["list", "--formula", "--versions"], timeout: 20)
        async let c = AsyncProcess.run(brew, ["list", "--cask", "--versions"], timeout: 20)
        func parse(_ o: AsyncProcess.Output) -> [String: String] {
            var d: [String: String] = [:]
            for line in o.stdout.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if let n = parts.first { d[String(n)] = parts.dropFirst().joined(separator: " ") }
            }
            return d
        }
        let (fo, co) = await (f, c)
        installedFormulae = parse(fo)
        installedCasks = parse(co)
        installedAt = Date()
    }

    private func maintenanceItems() -> [PaletteItem] {
        let o = engine.options.value
        func command(_ id: String, _ title: String, _ subtitle: String, _ symbol: String, _ cmd: String) -> PaletteItem {
            PaletteItem(id: "brew:\(id)", title: title, subtitle: subtitle, icon: .symbol(symbol, .yellow), providerID: self.id,
                        section: "Homebrew", accessory: "Terminal", score: 900,
                        primary: PaletteAction(id: "run", title: "Run in \(o.terminal.title)", symbol: "terminal") {
                            Launch.runInTerminal(cmd, app: o.terminal, keepOpen: true)
                            return .dismiss
                        }, isPinnable: false)
        }
        return [command("update", "Update Homebrew", "brew update", "arrow.down.circle.fill", "brew update"),
                command("upgrade", "Upgrade All Packages", "brew upgrade", "arrow.up.circle.fill", "brew upgrade"),
                command("outdated", "List Outdated Packages", "brew outdated", "clock.badge.exclamationmark", "brew outdated"),
                command("cleanup", "Clean Up", "brew cleanup", "sparkles", "brew cleanup")]
    }

    func item(_ pkg: String, cask: Bool, version: String?, score: Double, section: String) -> PaletteItem {
        let o = engine.options.value
        let flag = cask ? " --cask" : ""
        let installed = version != nil
        func terminal(_ verb: String) -> ActionOutcome {
            Launch.runInTerminal("brew \(verb)\(flag) \(Shell.quote(pkg))", app: o.terminal, keepOpen: true)
            installedAt = nil
            return .dismiss
        }
        var actions: [PaletteAction] = []
        if installed {
            actions.append(PaletteAction(id: "upgrade", title: "Upgrade", symbol: "arrow.up.circle") { terminal("upgrade") })
            actions.append(PaletteAction(id: "uninstall", title: "Uninstall", symbol: "trash", shortcut: ActionKeys.trash, destructive: true) {
                .confirm(Confirmation(title: "Uninstall \(pkg)?", message: "brew uninstall\(flag) \(pkg)", confirmTitle: "Uninstall") {
                    terminal("uninstall")
                })
            })
        }
        let page = URL(string: "https://formulae.brew.sh/\(cask ? "cask" : "formula")/\(pkg)")
        actions += [
            PaletteAction(id: "homepage", title: "Open on formulae.brew.sh", symbol: "safari", shortcut: ActionKeys.secondary) {
                if let page { Launch.open(page) }
                return .dismiss
            },
            PaletteAction(id: "copy", title: "Copy Install Command", symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
                Launch.copy("brew install\(flag) \(pkg)")
                return .dismiss
            },
        ]
        let primary = installed
            ? PaletteAction(id: "info", title: "Show Info", symbol: "info.circle") {
                .push(OutputPage.make(id: "brew:info:\(pkg)", title: "brew info \(pkg)", icon: self.icon, providerID: self.id) {
                    await AsyncProcess.run(Self.brewPath ?? "brew", ["info"] + (cask ? ["--cask"] : []) + [pkg], timeout: 30)
                })
            }
            : PaletteAction(id: "install", title: "Install", symbol: "arrow.down.circle") { terminal("install") }
        if installed { actions.insert(PaletteAction(id: "reinstall", title: "Reinstall", symbol: "arrow.clockwise") { terminal("reinstall") }, at: 1) }
        return PaletteItem(
            id: "brew:\(cask ? "cask" : "formula"):\(pkg)", title: pkg,
            subtitle: (cask ? "Cask" : "Formula") + (version.map { " · installed \($0)" } ?? ""),
            icon: .symbol(cask ? "shippingbox.fill" : "mug.fill", .yellow), providerID: id, section: section,
            accessory: installed ? "Installed" : (cask ? "Cask" : "Formula"), score: score, primary: primary, actions: actions,
            loadDetails: { await Self.details(pkg, cask: cask, version: version) }, isPinnable: false)
    }

    /// `brew info --json=v2` → description, homepage and version.
    static func details(_ pkg: String, cask: Bool, version: String?) async -> ItemDetails? {
        guard let brew = brewPath else { return nil }
        let out = await AsyncProcess.run(brew, ["info", "--json=v2"] + (cask ? ["--cask"] : []) + [pkg], timeout: 20)
        guard out.ok, let data = out.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let entry = ((json[cask ? "casks" : "formulae"] as? [[String: Any]]) ?? []).first ?? [:]
        let desc = entry["desc"] as? String
        let homepage = entry["homepage"] as? String ?? ""
        let latest = cask ? entry["version"] as? String : (entry["versions"] as? [String: Any])?["stable"] as? String
        let displayName = cask ? ((entry["name"] as? [String])?.first ?? pkg) : pkg
        var rows = [DetailRow(label: "Latest", value: latest ?? "—")]
        if let version { rows.append(DetailRow(label: "Installed", value: version)) }
        if !homepage.isEmpty { rows.append(DetailRow(label: "Homepage", value: homepage)) }
        if let license = entry["license"] as? String { rows.append(DetailRow(label: "License", value: license, monospaced: false)) }
        return ItemDetails(icon: .symbol(cask ? "shippingbox.fill" : "mug.fill", .yellow), title: displayName,
                           subtitle: desc ?? (cask ? "Cask" : "Formula"), rows: rows)
    }
}
