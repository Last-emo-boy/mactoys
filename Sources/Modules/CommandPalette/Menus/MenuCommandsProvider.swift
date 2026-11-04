import AppKit
import ApplicationServices
import MacToysCore

/// The app whose menus are searched.
struct MenuTarget: Equatable, Sendable {
    var pid: pid_t
    var name: String
    var bundleID: String?
    var bundlePath: String?

    /// Key for usage, hidden commands and the item ids.
    var key: String { bundleID ?? name }

    @MainActor init(_ app: NSRunningApplication) {
        pid = app.processIdentifier
        name = app.localizedName ?? app.bundleIdentifier ?? "?"
        bundleID = app.bundleIdentifier
        bundlePath = app.bundleURL?.path
    }

    init(pid: pid_t, name: String, bundleID: String?, bundlePath: String?) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.bundlePath = bundlePath
    }
}

/// Which menu commands were run in each app, for ranking and the Recent section.
@MainActor
final class MenuUsageStore {
    private(set) var apps: [String: [String: MenuRanker.Usage]] = [:]
    private let file: URL?
    private var pendingSave: DispatchWorkItem?
    static let limitPerApp = 200

    /// `file` nil keeps everything in memory (previews, tests).
    init(file: URL?) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        apps = (try? JSONDecoder().decode([String: [String: MenuRanker.Usage]].self, from: data)) ?? [:]
    }

    func usage(for app: String) -> [String: MenuRanker.Usage] { apps[app] ?? [:] }

    func record(_ commandID: String, in app: String, at date: Date = Date()) {
        var list = apps[app] ?? [:]
        var u = list[commandID] ?? MenuRanker.Usage(count: 0, last: date)
        u.count += 1
        u.last = date
        list[commandID] = u
        if list.count > Self.limitPerApp, let oldest = list.min(by: { $0.value.last < $1.value.last })?.key {
            list[oldest] = nil
        }
        apps[app] = list
        scheduleSave()
    }

    func forget(_ app: String) {
        apps[app] = nil
        scheduleSave()
    }

    func clear() {
        apps.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        guard let file else { return }
        pendingSave?.cancel()
        let snapshot = apps
        let work = DispatchWorkItem {
            do {
                try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            } catch {
                Log.for("cmdpal").error("Could not save menu usage: \(error.localizedDescription, privacy: .public)")
            }
        }
        pendingSave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flush() {
        guard let work = pendingSave else { return }
        pendingSave = nil
        work.perform()
        work.cancel()   // the scheduled copy doesn't write again
    }
}

/// Menu Commands: the menu bar of the app in front as a searchable list. Each command shows its
/// path and shortcut; ↵ brings the app back and presses the item.
@MainActor
final class MenuCommandsProvider: SearchProvider {
    let id = "menus"
    let name = String(localized: "Menu Commands", comment: "Provider name: the menu bar commands of the front app")
    let summary = String(localized: "Search and run the menu bar commands of the app you’re using")
    let icon = ItemIcon.symbol("menubar.rectangle", .indigo)
    let defaultKeyword = "menu"
    let globalByDefault = false
    var examples: [String] { ["menu export", "menu new tab"] }

    /// The keyword the palette's alias uses (it's added once for existing settings too).
    nonisolated static let keyword = "menu"
    nonisolated static let pageID = "menus:page"

    private let engine: LauncherEngine
    let usage: MenuUsageStore
    /// The app the next search reads: the front app when a launcher opened.
    private(set) var target: MenuTarget?
    /// The last app other than MacToys that was active (for launches from the menu bar flyout).
    private var lastApp: NSRunningApplication?
    private var cache: [pid_t: Task<MenuReader.Snapshot, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Overrides reading menus (previews).
    var snapshotOverride: ((MenuTarget) -> MenuReader.Snapshot)?

    init(engine: LauncherEngine, usage: MenuUsageStore? = nil) {
        self.engine = engine
        self.usage = usage ?? MenuUsageStore(file: Paths.data(for: "cmdpal").appendingPathComponent("menu-usage.json"))
    }

    // MARK: Lifecycle

    func activate() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let own = ProcessInfo.processInfo.processIdentifier
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier != own else { return }
                self.lastApp = app
                // Coming back to the app may change its menus (another document, another tab).
                self.cache[app.processIdentifier] = nil
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cache[app.processIdentifier]?.cancel()
                self.cache[app.processIdentifier] = nil
                if self.lastApp == app { self.lastApp = nil }
            }
        })
    }

    func deactivate() {
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers.removeAll()
        for task in cache.values { task.cancel() }
        cache.removeAll()
        target = nil
        lastApp = nil
        usage.flush()
    }

    func launcherWillShow() { captureTarget() }

    /// Remembers the app in front (before a launcher takes focus) and starts reading its menus.
    func captureTarget() {
        let own = NSRunningApplication.current
        var app = NSWorkspace.shared.frontmostApplication
        if app == nil || app == own { app = lastApp }
        guard let app, app != own, !app.isTerminated else { target = nil; return }
        target = MenuTarget(app)
        if AXIsProcessTrusted(), !isExcluded(app) { _ = snapshotTask(for: MenuTarget(app)) }
    }

    func isExcluded(_ app: NSRunningApplication?) -> Bool {
        engine.options.value.menusExcludedApps.matches(app: app)
    }

    // MARK: Reading

    private func snapshotTask(for target: MenuTarget) -> Task<MenuReader.Snapshot, Never> {
        if let task = cache[target.pid] { return task }
        let pid = target.pid
        let task = Task.detached(priority: .userInitiated) { MenuReader.read(pid: pid) }
        cache[target.pid] = task
        return task
    }

    func snapshot(for target: MenuTarget) async -> MenuReader.Snapshot {
        if let snapshotOverride { return snapshotOverride(target) }
        return await snapshotTask(for: target).value
    }

    // MARK: SearchProvider

    var page: ListPage {
        let app = target?.name
        return ListPage(id: Self.pageID,
                        title: app.map { String(localized: "\($0) Menus", comment: "Page title: the menu commands of an app; %@ is the app name") } ?? name,
                        placeholder: app.map { String(localized: "Search the menus of \($0)…", comment: "Search field placeholder; %@ is an app name") }
                            ?? String(localized: "Search menu commands…"),
                        icon: target?.bundlePath.map { .file($0) } ?? icon) { [weak self] text in
            guard let self else { return [] }
            return await self.search(SearchQuery(text: text, scoped: true, frontEnd: .palette))
        }
    }

    var commands: [PaletteItem] {
        let subtitle = target.map { String(localized: "Commands in the menu bar of \($0.name)", comment: "%@ is an app name") } ?? summary
        return [pageCommand(title: Phrase("Search Menu Commands"), subtitle: subtitle,
                            keywords: ["menu", "menus", "menu bar", "commands"])]
    }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        if !query.scoped && text.count < 2 { return [] }
        guard snapshotOverride != nil || AXIsProcessTrusted() else { return query.scoped ? [permissionItem()] : [] }
        guard let target else {
            return query.scoped ? [hint("menus:hint:none", String(localized: "No app in front"),
                                        String(localized: "Open Command Palette from an app to search its menus."))] : []
        }
        if snapshotOverride == nil, isExcluded(NSRunningApplication(processIdentifier: target.pid)) {
            return query.scoped ? [hint("menus:hint:excluded",
                                        String(localized: "Menu commands are turned off for \(target.name)", comment: "%@ is an app name"),
                                        String(localized: "Change it in Command Palette settings › Extensions › Menu Commands."))] : []
        }
        let snapshot = await snapshot(for: target)
        guard !Task.isCancelled else { return [] }
        return items(snapshot, query: text, scoped: query.scoped, target: target)
    }

    /// Result rows for a snapshot (also used by the preview scene).
    func items(_ snapshot: MenuReader.Snapshot, query text: String, scoped: Bool, target: MenuTarget,
               options: ProviderOptions? = nil, now: Date = Date()) -> [PaletteItem] {
        let options = options ?? engine.options.value
        let hidden = Set(options.menusHidden[target.key] ?? [])
        let commands = snapshot.commands.filter { !hidden.contains($0.id) && (options.menusShowDisabled || $0.enabled) }
        let used = usage.usage(for: target.key)
        var out: [PaletteItem] = []
        if text.isEmpty {
            let recent = MenuRanker.recent(commands, usage: used, limit: 5)
            let recentIDs = Set(recent.map(\.id))
            out += recent.enumerated().map { i, c in item(c, target: target, score: 100_000 - Double(i), section: Labels.recent, usage: used[c.id]) }
            out += commands.enumerated().filter { !recentIDs.contains($0.element.id) }.map { i, c in
                item(c, target: target, score: 50_000 - Double(i), section: c.menu, usage: used[c.id])
            }
        } else {
            let ranked = MenuRanker.rank(commands, query: text, usage: used, now: now)
            let section = scoped ? "" : String(localized: "\(target.name) Menus", comment: "Page title: the menu commands of an app; %@ is the app name")
            out = ranked.prefix(scoped ? 300 : 6).map { r in
                item(r.command, target: target, score: scoped ? r.score : r.score * 0.9, section: section, usage: used[r.command.id])
            }
        }
        guard scoped else { return out }
        if commands.isEmpty {
            out.append(hint("menus:hint:empty", String(localized: "\(target.name) shows no menu commands", comment: "%@ is an app name"),
                            String(localized: "Some apps draw their own menus, which Accessibility can’t read.")))
        } else if snapshot.truncated {
            var more = hint("menus:hint:truncated", String(localized: "Some menus took too long to read"),
                            String(localized: "\(target.name) answered slowly; the commands found so far are listed.", comment: "%@ is an app name"))
            more.isFallback = true
            out.append(more)
        }
        return out
    }

    private func item(_ c: MenuCommand, target: MenuTarget, score: Double, section: String, usage: MenuRanker.Usage?) -> PaletteItem {
        let icon = Self.icon(for: c, target: target)
        let key = target.key
        let commandID = c.id
        var rows: [DetailRow] = []
        if !c.keys.isEmpty {
            rows.append(DetailRow(label: String(localized: "Shortcut", comment: "Detail row: a menu command's keyboard shortcut"),
                                  value: c.keys.joined(separator: " ")))
        }
        rows.append(DetailRow(label: String(localized: "Status", comment: "Detail row: whether the utility is on"),
                              value: c.enabled ? String(localized: "Available", comment: "A menu command that can run now")
                                  : String(localized: "Not available right now", comment: "A dimmed menu command"),
                              monospaced: false))
        if c.checked {
            rows.append(DetailRow(label: String(localized: "Checked", comment: "Detail row: the menu item shows a check mark"),
                                  value: "✓", monospaced: false))
        }
        if let usage {
            rows.append(DetailRow(label: String(localized: "Used", comment: "Detail row: how often a menu command was run"),
                                  value: String(localized: "\(usage.count) times", comment: "How often a menu command was run"),
                                  monospaced: false))
        }
        let primary: PaletteAction
        if c.enabled {
            primary = PaletteAction(id: "run", title: String(localized: "Run Command", comment: "Action: press the menu item"),
                                    symbol: "return", recordsUsage: false) { [weak self] in
                self?.usage.record(commandID, in: key)
                return .dismissThen { MenuCommandsProvider.run(c, in: target) }
            }
        } else {
            primary = PaletteAction(id: "run", title: String(localized: "Not Available", comment: "Action of a dimmed menu command: it can't run now"),
                                    symbol: "nosign", recordsUsage: false) {
                NSSound.beep()
                return .stay
            }
        }
        var actions = [PaletteAction(id: "copy-path", title: String(localized: "Copy Menu Path", comment: "Action: copy File › Export To › PDF…"),
                                     symbol: "doc.on.doc", recordsUsage: false) {
            Launch.copy(c.fullPath)
            return .dismiss
        }]
        actions.append(PaletteAction(id: "hide", title: String(localized: "Hide This Command", comment: "Action: don't list this menu command any more"),
                                     symbol: "eye.slash", recordsUsage: false) { [weak self] in
            self?.engine.options.update { o in
                var list = o.menusHidden[key] ?? []
                if !list.contains(commandID) { list.append(commandID) }
                o.menusHidden[key] = list
            }
            return .refresh
        })
        actions.append(PaletteAction(id: "exclude",
                                     title: String(localized: "Turn Off Menu Commands for \(target.name)", comment: "Action; %@ is an app name"),
                                     symbol: "slash.circle", recordsUsage: false) { [weak self] in
            self?.engine.options.update { o in
                if !o.menusExcludedApps.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { o.menusExcludedApps.append(key) }
            }
            HUD.show("Menu commands off for \(target.name)", symbol: "menubar.rectangle")
            return .back
        })
        return PaletteItem(
            id: "menus:\(key):\(c.id)", title: c.title, subtitle: c.parentPath, icon: icon, providerID: id, section: section,
            score: score, primary: primary, actions: actions,
            details: ItemDetails(icon: target.bundlePath.map { .file($0) } ?? icon, title: c.title, subtitle: c.parentPath, rows: rows),
            isPinnable: false, keywords: [c.path.joined(separator: " ")],
            isDimmed: !c.enabled, keycaps: c.keys)
    }

    private func hint(_ id: String, _ title: String, _ subtitle: String) -> PaletteItem {
        PaletteItem(id: id, title: title, subtitle: subtitle, icon: .symbol("menubar.rectangle", .graphite), providerID: self.id,
                    primary: PaletteAction(id: "none", title: Labels.ok, symbol: "checkmark", recordsUsage: false) { .stay },
                    isPinnable: false)
    }

    private func permissionItem() -> PaletteItem {
        PaletteItem(id: "menus:hint:permission", title: String(localized: "Allow Accessibility to search menus"),
                    subtitle: String(localized: "MacToys reads the front app’s menu bar through Accessibility."),
                    icon: .symbol("lock.shield", .orange), providerID: id,
                    primary: PaletteAction(id: "grant", title: String(localized: "Grant Access"), symbol: "lock.open", recordsUsage: false) {
                        .dismissThen { PermissionCenter.shared.request(.accessibility) }
                    },
                    isPinnable: false)
    }

    // MARK: Running

    /// Brings the app back to the front, waits until it is, then presses the item off the main thread.
    static func run(_ command: MenuCommand, in target: MenuTarget) {
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            HUD.show("\(target.name) isn’t running any more", symbol: "exclamationmark.triangle")
            return
        }
        if !app.isActive { app.activate() }
        Task { @MainActor in
            for _ in 0..<20 where !app.isActive { try? await Task.sleep(nanoseconds: 25_000_000) }
            let pid = target.pid
            let result = await Task.detached(priority: .userInitiated) { MenuReader.press(command, pid: pid) }.value
            switch result {
            case .pressed: break
            case .disabled:
                HUD.show("“\(command.title)” isn’t available right now", symbol: "nosign")
            case .notFound:
                HUD.show("“\(command.title)” is no longer in the menu", symbol: "questionmark.circle")
            }
        }
    }

    // MARK: Icons

    /// A tinted symbol for the top-level menu the command is in; the app's own menu shows its icon.
    static func icon(for command: MenuCommand, target: MenuTarget) -> ItemIcon {
        if command.checked { return .symbol("checkmark", .green) }
        if command.menu == target.name, let path = target.bundlePath { return .file(path) }
        let key = command.menu.lowercased()
        for (names, symbol, tint) in menuIcons where names.contains(key) { return .symbol(symbol, tint) }
        return .symbol("filemenu.and.selection", .graphite)
    }

    /// Common menu titles in English and a few other languages, with their symbols.
    static let menuIcons: [(Set<String>, String, Tint)] = [
        (["file", "ablage", "datei", "fichier", "archivo", "文件", "檔案", "ファイル", "파일", "arquivo", "файл"], "doc", .blue),
        (["edit", "bearbeiten", "édition", "edición", "modifica", "编辑", "編輯", "編集", "편집", "editar", "правка"], "pencil", .orange),
        (["view", "darstellung", "ansicht", "présentation", "affichage", "visualización", "ver", "vista", "显示", "顯示", "表示", "보기", "visualizar", "вид"],
         "eye", .purple),
        (["window", "fenster", "fenêtre", "ventana", "finestra", "窗口", "視窗", "ウインドウ", "윈도우", "janela", "окно"], "macwindow", .indigo),
        (["help", "hilfe", "aide", "ayuda", "aiuto", "帮助", "輔助說明", "ヘルプ", "도움말", "ajuda", "справка"], "questionmark.circle", .green),
        (["format", "formatieren", "formato", "格式", "フォーマット", "포맷", "формат"], "textformat", .pink),
        (["insert", "einfügen", "insertion", "insertar", "插入", "挿入", "삽입", "вставка"], "plus.square", .teal),
        (["go", "gehe zu", "aller", "ir", "前往", "移動", "이동", "переход"], "arrow.forward.circle", .cyan),
        (["history", "verlauf", "historique", "historial", "历史记录", "瀏覽記錄", "履歴", "방문 기록", "история"], "clock.arrow.circlepath", .brown),
        (["bookmarks", "lesezeichen", "signets", "marcadores", "书签", "書籤", "ブックマーク", "책갈피", "закладки"], "book", .red),
        (["tools", "werkzeuge", "outils", "herramientas", "工具", "ツール", "도구"], "wrench.and.screwdriver", .graphite),
        (["debug", "develop", "entwickler", "développement", "desarrollo", "开发", "開發", "開発"], "hammer", .graphite),
        (["arrange", "anordnen", "disposition", "organizar", "排列", "配置", "정렬"], "square.3.layers.3d", .yellow),
        (["table", "tabelle", "tableau", "tabla", "表格", "表", "표"], "tablecells", .green),
        (["image", "bild", "imagen", "图像", "影像", "イメージ", "이미지"], "photo", .mint),
        (["navigate", "product", "editor", "source control"], "chevron.left.forwardslash.chevron.right", .indigo),
        (["text", "font", "schrift", "police", "fuente", "字体", "字體", "フォント"], "textformat.size", .pink),
        (["controls", "playback", "steuerung", "commandes", "controles", "控制", "コントロール"], "playpause", .red),
        (["shell", "terminal"], "terminal", .graphite),
        (["mailbox", "postfach", "boîte aux lettres", "buzón", "message", "nachricht"], "envelope", .blue),
    ]
}
