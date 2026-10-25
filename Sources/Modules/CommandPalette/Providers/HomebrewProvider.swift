import AppKit
import MacToysCore

/// Homebrew (`brew`): search, inspect, install, upgrade and uninstall formulae and casks.
@MainActor
final class HomebrewProvider: SearchProvider {
    let id = "brew"
    let name = "Homebrew"
    let summary = String(localized: "Search, install, upgrade and uninstall Homebrew formulae and casks")
    let icon = ItemIcon.symbol("mug.fill", .yellow)
    let defaultKeyword = "brew"
    let globalByDefault = false
    var examples: [String] {
        ["brew ripgrep",
         String(localized: "\("brew")  (installed packages)", comment: "Run help example: %@ is what to type, the parentheses explain it")]
    }

    private let engine: LauncherEngine
    private var installedFormulae: [String: String] = [:]
    private var installedCasks: [String: String] = [:]
    private var installedAt: Date?

    init(engine: LauncherEngine) { self.engine = engine }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Homebrew"),
                     subtitle: Self.brewPath == nil ? String(localized: "Homebrew is not installed") : String(localized: "Search and install packages"),
                     keywords: ["brew", "install", "package", "cask", "formula"])]
    }

    func launcherWillShow() { installedAt = nil }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        guard query.scoped else { return [] }
        guard let brew = Self.brewPath else {
            return [PaletteItem(id: "brew:missing", title: String(localized: "Homebrew is not installed"),
                                subtitle: String(localized: "Open \("brew.sh") to install it", comment: "%@ is the Homebrew website"),
                                icon: icon, providerID: id, score: 1000,
                                primary: PaletteAction(id: "open", title: String(localized: "Open \("brew.sh")", comment: "Action: open something; %@ is an app, utility, website or address"), symbol: "safari") {
                                    if let url = URL(string: "https://brew.sh") { Launch.open(url) }
                                    return .dismiss
                                }, isPinnable: false)]
        }
        await loadInstalled(brew)
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            var out = maintenanceItems()
            out += installedFormulae.sorted { $0.key < $1.key }.enumerated().map { i, kv in
                item(kv.key, cask: false, version: kv.value, score: 500 - Double(i) / 100,
                     section: String(localized: "Installed Formulae", comment: "Section heading: installed Homebrew formulae"))
            }
            if engine.options.value.brewIncludeCasks {
                out += installedCasks.sorted { $0.key < $1.key }.enumerated().map { i, kv in
                    item(kv.key, cask: true, version: kv.value, score: 400 - Double(i) / 100,
                         section: String(localized: "Installed Casks", comment: "Section heading: installed Homebrew casks (apps)"))
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
            item(n, cask: false, version: installedFormulae[n], score: FuzzyMatcher.score(text, n) ?? 100,
                 section: String(localized: "Formulae", comment: "Section heading: Homebrew formulae (command-line packages)"))
        }
        let caskItems = names(c).map { n in
            item(n, cask: true, version: installedCasks[n], score: (FuzzyMatcher.score(text, n) ?? 100) - 1,
                 section: String(localized: "Casks", comment: "Section heading: Homebrew casks (apps)"))
        }
        if formulaItems.isEmpty && caskItems.isEmpty {
            return [PaletteItem(id: "brew:none", title: String(localized: "No packages match “\(text)”", comment: "%@ is the search text"),
                                subtitle: "brew search \(text)", icon: icon, providerID: id, score: 1,
                                primary: PaletteAction(id: "none", title: Labels.ok, symbol: "checkmark", recordsUsage: false) { .stay },
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
                        section: "Homebrew", accessory: TerminalApp.terminal.title, score: 900,
                        primary: PaletteAction(id: "run", title: Labels.runIn(o.terminal.title), symbol: "terminal") {
                            Launch.runInTerminal(cmd, app: o.terminal, keepOpen: true)
                            return .dismiss
                        }, isPinnable: false)
        }
        return [command("update", String(localized: "Update Homebrew"), "brew update", "arrow.down.circle.fill", "brew update"),
                command("upgrade", String(localized: "Upgrade All Packages"), "brew upgrade", "arrow.up.circle.fill", "brew upgrade"),
                command("outdated", String(localized: "List Outdated Packages"), "brew outdated", "clock.badge.exclamationmark", "brew outdated"),
                command("cleanup", String(localized: "Clean Up", comment: "Homebrew command: remove old package versions"), "brew cleanup",
                        "sparkles", "brew cleanup")]
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
            actions.append(PaletteAction(id: "upgrade", title: String(localized: "Upgrade", comment: "Action: upgrade the Homebrew package"),
                                         symbol: "arrow.up.circle") { terminal("upgrade") })
            actions.append(PaletteAction(id: "uninstall", title: String(localized: "Uninstall", comment: "Action: uninstall the Homebrew package"),
                                         symbol: "trash", shortcut: ActionKeys.trash, destructive: true) {
                .confirm(Confirmation(title: String(localized: "Uninstall \(pkg)?", comment: "Confirmation prompt; %@ is a package name"),
                                      message: "brew uninstall\(flag) \(pkg)",
                                      confirmTitle: String(localized: "Uninstall", comment: "Action: uninstall the Homebrew package")) {
                    terminal("uninstall")
                })
            })
        }
        let page = URL(string: "https://formulae.brew.sh/\(cask ? "cask" : "formula")/\(pkg)")
        actions += [
            PaletteAction(id: "homepage", title: String(localized: "Open on \("formulae.brew.sh")", comment: "%@ is the Homebrew package website"),
                          symbol: "safari", shortcut: ActionKeys.secondary) {
                if let page { Launch.open(page) }
                return .dismiss
            },
            PaletteAction(id: "copy", title: String(localized: "Copy Install Command"), symbol: "doc.on.doc", shortcut: ActionKeys.copy) {
                Launch.copy("brew install\(flag) \(pkg)")
                return .dismiss
            },
        ]
        let primary = installed
            ? PaletteAction(id: "info", title: String(localized: "Show Info", comment: "Action: show `brew info` for the package"), symbol: "info.circle") {
                .push(OutputPage.make(id: "brew:info:\(pkg)", title: "brew info \(pkg)", icon: self.icon, providerID: self.id) {
                    await AsyncProcess.run(Self.brewPath ?? "brew", ["info"] + (cask ? ["--cask"] : []) + [pkg], timeout: 30)
                })
            }
            : PaletteAction(id: "install", title: String(localized: "Install", comment: "Action: install the Homebrew package"),
                            symbol: "arrow.down.circle") { terminal("install") }
        if installed {
            actions.insert(PaletteAction(id: "reinstall", title: String(localized: "Reinstall", comment: "Action: reinstall the Homebrew package"),
                                         symbol: "arrow.clockwise") { terminal("reinstall") }, at: 1)
        }
        let kind = cask ? Self.caskLabel : Self.formulaLabel
        return PaletteItem(
            id: "brew:\(cask ? "cask" : "formula"):\(pkg)", title: pkg,
            subtitle: version.map { String(localized: "\(kind) · installed \($0)", comment: "%1$@ is Formula or Cask, %2$@ the installed version") } ?? kind,
            icon: .symbol(cask ? "shippingbox.fill" : "mug.fill", .yellow), providerID: id, section: section,
            accessory: installed ? String(localized: "Installed", comment: "A Homebrew package is installed (row label), or its installed version (detail row)") : kind,
            score: score, primary: primary, actions: actions,
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
        var rows = [DetailRow(label: String(localized: "Latest", comment: "Detail row: the newest version of the package"), value: latest ?? "—")]
        if let version {
            rows.append(DetailRow(label: String(localized: "Installed", comment: "A Homebrew package is installed (row label), or its installed version (detail row)"), value: version))
        }
        if !homepage.isEmpty { rows.append(DetailRow(label: String(localized: "Homepage", comment: "Detail row: the package's website"), value: homepage)) }
        if let license = entry["license"] as? String {
            rows.append(DetailRow(label: String(localized: "License", comment: "Detail row: the package's software license"), value: license, monospaced: false))
        }
        return ItemDetails(icon: .symbol(cask ? "shippingbox.fill" : "mug.fill", .yellow), title: displayName,
                           subtitle: desc ?? (cask ? caskLabel : formulaLabel), rows: rows)
    }

    static var formulaLabel: String { String(localized: "Formula", comment: "A Homebrew command-line package") }
    static var caskLabel: String { String(localized: "Cask", comment: "A Homebrew app package") }
}
