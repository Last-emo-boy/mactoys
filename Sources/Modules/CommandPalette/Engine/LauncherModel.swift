import AppKit
import Carbon.HIToolbox
import MacToysCore
import Observation

/// What a launcher window must do for its model.
@MainActor
protocol LauncherHost: AnyObject {
    /// Hide the launcher. With `restoreFocus`, give focus back to the app that was in front right away.
    func dismissLauncher(restoreFocus: Bool)
    /// The content size changed (results arrived, compact mode expanded).
    func launcherLayoutChanged()
    func openLauncherSettings()
}

/// Behavior switches that differ between Command Palette and Run.
struct LauncherBehavior {
    var escape: CommandPaletteSettings.EscapeBehavior = .clearThenBack
    var backspaceGoesBack = true
    var singleClickActivates = false
    var numberKeys: CommandPaletteSettings.NumberKeys = .run
    /// Section title for empty `item.section`s; nil hides headers.
    var showSectionHeaders = true
}

/// What the front end wants for a query at the top level.
enum RootPlan {
    /// Fixed sections (the palette's Home, Run's plugin list).
    case sections([ResultSection])
    /// Search these providers.
    case sources([SearchSession.Source], boost: Double, layout: SearchSession.Layout)
    /// Open a page with this query (an alias like `cb `).
    case push(ListPage, query: String)
}

/// The state of one launcher: query, page stack, results, selection, actions menu and
/// confirmation, plus keyboard handling. Shared by Command Palette and Run.
@MainActor
@Observable
final class LauncherModel {
    struct PageState {
        var page: ListPage
        var query: String
        var selectedID: String?
    }

    /// The text in the search field for the current level.
    var query = "" {
        didSet { if query != oldValue && !switching { queryChanged() } }
    }
    private(set) var stack: [PageState] = []
    private(set) var sections: [ResultSection] = []
    private(set) var selection = 0
    /// Index of the selected shelf item (palette), when the shelf has keyboard focus.
    var shelfSelection: Int?
    var actionsMenu: ActionsMenuState? {
        didSet { if (actionsMenu == nil) != (oldValue == nil) { host?.launcherLayoutChanged() } }
    }
    var confirmation: Confirmation? {
        didSet { if (confirmation == nil) != (oldValue == nil) { host?.launcherLayoutChanged() } }
    }
    /// 0 = Cancel, 1 = confirm, 2 = the alternate choice.
    var confirmChoice = 1
    private(set) var details: ItemDetails?
    private(set) var loading = false
    /// Provider id the palette's filter menu restricts the search to.
    var filter: String? {
        didSet { if filter != oldValue { onFilterChange?(filter); refresh() } }
    }
    /// Compact palette: collapsed to the search box until typing.
    var expanded = true {
        didSet { if expanded != oldValue { host?.launcherLayoutChanged() } }
    }
    var focusRequest = 0
    var selectOnFocus = true
    private(set) var shelfItems: [PaletteItem] = []
    /// Ids of providers that returned results (the footer count).
    private(set) var providerCount = 0

    @ObservationIgnored let engine: LauncherEngine
    @ObservationIgnored let frontEnd: FrontEnd
    @ObservationIgnored weak var host: LauncherHost?
    /// The plan for a top-level query; gets the query and the active filter.
    @ObservationIgnored var rootPlan: (String, String?) -> RootPlan = { _, _ in .sections([]) }
    @ObservationIgnored var behavior: () -> LauncherBehavior = { LauncherBehavior() }
    /// Extra actions for an item's ⌘K menu (pin, alias, hotkey, command link).
    @ObservationIgnored var metaActions: (PaletteItem) -> [PaletteAction] = { _ in [] }
    @ObservationIgnored var shelfProvider: () -> [PaletteItem] = { [] }
    @ObservationIgnored var onFilterChange: ((String?) -> Void)?
    /// Called after an action closed the launcher (Run's "clear on launch").
    @ObservationIgnored var afterRun: (() -> Void)?
    /// Run waits this long after a keystroke before searching.
    @ObservationIgnored var searchDelay: TimeInterval = 0
    /// The palette starts collapsed in compact mode.
    @ObservationIgnored var collapsesWhenEmpty = false
    @ObservationIgnored private let session: SearchSession
    @ObservationIgnored private var switching = false
    @ObservationIgnored private var userMoved = false
    @ObservationIgnored private var detailsTask: Task<Void, Never>?
    @ObservationIgnored private var delayWork: DispatchWorkItem?
    @ObservationIgnored private var rootQuery = ""

    init(engine: LauncherEngine, frontEnd: FrontEnd) {
        self.engine = engine
        self.frontEnd = frontEnd
        session = SearchSession(layout: .sections(maxPerSection: 3), usage: engine.usage)
        session.onUpdate = { [weak self] sections, pending in self?.apply(sections, pending: pending) }
        session.sectionTitle = { [weak engine] item in engine?.provider(item.providerID)?.name ?? "" }
    }

    // MARK: Derived state

    var items: [PaletteItem] { sections.flatMap(\.items) }

    var selectedItem: PaletteItem? {
        if let s = shelfSelection, s < shelfItems.count { return shelfItems[s] }
        let all = items
        return selection < all.count ? all[selection] : nil
    }

    var currentPage: ListPage? { stack.last?.page }
    var isHome: Bool { stack.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty && filter == nil }

    var placeholder: String {
        if let p = currentPage { return p.placeholder }
        if let f = filter, let p = engine.provider(f) { return "Search \(p.name)…" }
        return frontEnd == .run ? "Start typing…" : "Search apps, files, commands…"
    }

    // MARK: Lifecycle

    /// Called when the launcher appears.
    func opened(keepQuery: Bool, selectText: Bool, returnHome: Bool) {
        actionsMenu = nil
        confirmation = nil
        shelfSelection = nil
        if returnHome && !stack.isEmpty {
            switching = true
            stack.removeAll()
            query = rootQuery
            switching = false
        }
        if !keepQuery {
            switching = true
            query = ""
            rootQuery = ""
            switching = false
        }
        expanded = !collapsesWhenEmpty || !query.isEmpty || !stack.isEmpty
        reloadShelf()
        selectOnFocus = selectText
        focusRequest += 1
        refresh()
    }

    /// Called after the launcher hid.
    func closed() {
        session.cancel()
        detailsTask?.cancel()
        delayWork?.cancel()
        actionsMenu = nil
        confirmation = nil
        if stack.isEmpty { rootQuery = query }
    }

    func reloadShelf() { shelfItems = shelfProvider() }

    /// Forgets the query and pages so the next open starts empty.
    func clearForNextOpen() {
        switching = true
        stack.removeAll()
        query = ""
        rootQuery = ""
        switching = false
        sections = []
        details = nil
    }

    // MARK: Searching

    private func queryChanged() {
        if stack.isEmpty { rootQuery = query }
        shelfSelection = nil
        userMoved = false
        if collapsesWhenEmpty && stack.isEmpty { expanded = !query.isEmpty }
        if searchDelay > 0 && !query.isEmpty {
            delayWork?.cancel()
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            delayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + searchDelay, execute: work)
        } else {
            refresh()
        }
    }

    /// Searches again for the current query and level.
    func refresh() {
        if let page = currentPage {
            session.layout = .sections(maxPerSection: 500)
            session.boostWeight = 0
            session.run([SearchSession.Source(provider: PageSource(page),
                                              query: SearchQuery(text: query, scoped: true, frontEnd: frontEnd))])
            return
        }
        switch rootPlan(query, filter) {
        case .sections(let s):
            session.reset()
            apply(s, pending: false)
        case .sources(let sources, let boost, let layout):
            session.layout = layout
            session.boostWeight = boost
            session.run(sources)
        case .push(let page, let rest):
            // The alias that opened the page is consumed; going back shows an empty search.
            switching = true
            query = ""
            rootQuery = ""
            switching = false
            push(page, query: rest)
        }
    }

    private func apply(_ new: [ResultSection], pending: Bool) {
        let previousID = selectedItem?.id
        sections = new
        loading = pending
        providerCount = Set(new.flatMap { $0.items.map(\.providerID) }).count
        let all = items
        if userMoved, let previousID, let i = all.firstIndex(where: { $0.id == previousID }) {
            selection = i
        } else {
            selection = stack.last.flatMap { st in st.selectedID.flatMap { id in all.firstIndex { $0.id == id } } } ?? 0
            userMoved = false
        }
        if selection >= all.count { selection = max(0, all.count - 1) }
        if selectedItem?.id != previousID || details == nil { loadDetails() }
        host?.launcherLayoutChanged()
    }

    // MARK: Pages

    func push(_ page: ListPage, query initial: String? = nil) {
        actionsMenu = nil
        confirmation = nil
        shelfSelection = nil
        switching = true
        if stack.isEmpty { rootQuery = query } else { stack[stack.count - 1].query = query }
        if let selectedID = selectedItem?.id, !stack.isEmpty { stack[stack.count - 1].selectedID = selectedID }
        stack.append(PageState(page: page, query: initial ?? page.initialQuery))
        query = initial ?? page.initialQuery
        switching = false
        expanded = true
        userMoved = false
        session.reset()
        sections = []
        details = nil
        selectOnFocus = false
        focusRequest += 1
        refresh()
    }

    /// Back one level; false at the top.
    @discardableResult
    func pop() -> Bool {
        guard !stack.isEmpty else { return false }
        actionsMenu = nil
        confirmation = nil
        switching = true
        stack.removeLast()
        query = stack.last?.query ?? rootQuery
        switching = false
        userMoved = !stack.isEmpty
        session.reset()
        selectOnFocus = false
        focusRequest += 1
        refresh()
        return true
    }

    func popToRoot() {
        guard !stack.isEmpty else { return }
        switching = true
        stack.removeAll()
        query = rootQuery
        switching = false
        session.reset()
        refresh()
    }

    // MARK: Selection

    func select(_ index: Int, byUser: Bool = true) {
        let count = items.count
        guard count > 0 else { return }
        shelfSelection = nil
        selection = min(max(index, 0), count - 1)
        if byUser { userMoved = true }
        if !stack.isEmpty { stack[stack.count - 1].selectedID = selectedItem?.id }
        loadDetails()
    }

    func selectShelf(_ index: Int?) {
        guard let index else { shelfSelection = nil; loadDetails(); return }
        guard index >= 0, index < shelfItems.count else { return }
        shelfSelection = index
        loadDetails()
    }

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        if shelfSelection != nil { select(delta > 0 ? 0 : count - 1); return }
        select((selection + delta + count) % count)
    }

    private func loadDetails() {
        detailsTask?.cancel()
        guard let item = selectedItem else { details = nil; return }
        details = item.details ?? ItemDetails(icon: item.icon, title: item.title, subtitle: item.subtitle.isEmpty ? nil : item.subtitle)
        guard let loader = item.loadDetails else { return }
        let id = item.id
        detailsTask = Task { [weak self] in
            // Let fast arrow-key scrolling settle before touching the disk.
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            let d = await loader()
            guard let self, !Task.isCancelled, self.selectedItem?.id == id, let d else { return }
            self.details = d
        }
    }

    // MARK: Running

    /// Runs the selected item's primary action.
    func runSelected() {
        guard let item = selectedItem else { return }
        perform(item.primary, of: item)
    }

    func run(_ item: PaletteItem) { perform(item.primary, of: item) }

    func perform(_ action: PaletteAction, of item: PaletteItem?) {
        actionsMenu = nil
        if action.recordsUsage, let item, stack.isEmpty || item.isPinnable, !item.id.hasPrefix("history:") {
            engine.usage.record(item, query: stack.isEmpty ? query : (stack.first?.query ?? query))
        }
        handle(action.perform())
    }

    func handle(_ outcome: ActionOutcome) {
        switch outcome {
        case .dismiss:
            host?.dismissLauncher(restoreFocus: false)
            afterRun?()
        case .dismissThen(let work):
            host?.dismissLauncher(restoreFocus: true)
            afterRun?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { MainActor.assumeIsolated { work() } }
        case .stay:
            break
        case .refresh:
            reloadShelf()
            refresh()
        case .push(let page):
            push(page)
        case .setQuery(let q):
            query = q
            selectOnFocus = false
            focusRequest += 1
        case .back:
            pop()
        case .confirm(let c):
            confirmation = c
            confirmChoice = 1
        }
    }

    /// Answers the confirmation: 0 cancels, 1 confirms, 2 picks the alternate.
    func answerConfirmation(_ choice: Int) {
        guard let c = confirmation else { return }
        confirmation = nil
        if choice == 1 { handle(c.perform()) }
        if choice == 2, let alt = c.alternate { handle(alt()) }
    }

    // MARK: Actions menu

    func toggleActionsMenu() {
        if actionsMenu != nil { actionsMenu = nil; return }
        guard let item = selectedItem else { return }
        let actions = item.allActions() + metaActions(item)
        actionsMenu = ActionsMenuState(title: item.title, actions: actions)
    }

    private func runMenuSelection() {
        guard let menu = actionsMenu else { return }
        let visible = menu.visible
        guard menu.selection < visible.count else { return }
        perform(visible[menu.selection], of: selectedItem)
    }

    // MARK: Keyboard

    /// Handles a key press while the launcher is key; returns true when consumed.
    func handleKey(_ e: NSEvent) -> Bool {
        let code = Int(e.keyCode)
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        if confirmation != nil { return handleConfirmationKey(code) }
        if actionsMenu != nil { return handleMenuKey(e, code: code, mods: mods) }

        if code == kVK_ANSI_K && mods == .command { toggleActionsMenu(); return true }
        // Text editing in the search field wins: ⌘C with selected text, ⌘⌫ while there is text.
        if mods == .command && code == kVK_ANSI_C && textSelected() { return false }
        if mods == .command && code == kVK_Delete && !query.isEmpty { return false }
        if code == kVK_ANSI_Comma && mods == .command { host?.openLauncherSettings(); return true }
        // Action key equivalents of the selected item (⌘C, ⌘↵, ⌘⌫ …).
        if !mods.isEmpty, mods != .shift, let item = selectedItem, let shortcut = Shortcut(event: e) {
            if let a = (item.allActions() + metaActions(item)).first(where: { $0.shortcut == shortcut }) {
                perform(a, of: item)
                return true
            }
        }
        // ⌥1…⌥9 run (or select) a shelf item or a visible row; ⌥⇧1…9 select.
        if mods == .option || mods == [.option, .shift], let n = Self.digit(code) {
            numberKey(n, select: mods.contains(.shift) || behavior().numberKeys == .select)
            return true
        }
        switch code {
        case kVK_DownArrow where mods.isEmpty || mods == .control:
            if !expanded { expanded = true; host?.launcherLayoutChanged(); return true }
            move(1); return true
        case kVK_UpArrow where mods.isEmpty:
            move(-1); return true
        case kVK_ANSI_N where mods == .control:
            move(1); return true
        case kVK_ANSI_P where mods == .control:
            move(-1); return true
        case kVK_PageDown:
            select(selection + 6); return true
        case kVK_PageUp:
            select(selection - 6); return true
        case kVK_LeftArrow where shelfSelection != nil && mods.isEmpty:
            selectShelf(max(0, (shelfSelection ?? 0) - 1)); return true
        case kVK_RightArrow where shelfSelection != nil && mods.isEmpty:
            selectShelf(min(shelfItems.count - 1, (shelfSelection ?? 0) + 1)); return true
        case kVK_Tab:
            if !expanded { expanded = true; host?.launcherLayoutChanged(); return true }
            if mods.isEmpty, let ac = selectedItem?.autocomplete {
                query = ac
                selectOnFocus = false
                focusRequest += 1
                return true
            }
            move(mods.contains(.shift) ? -1 : 1); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods.isEmpty || mods == .shift { runSelected(); return true }
            return false
        case kVK_Escape:
            escape(); return true
        case kVK_Delete where query.isEmpty && mods.isEmpty:
            if behavior().backspaceGoesBack, pop() { return true }
            if filter != nil { filter = nil; return true }
            return false
        default:
            return false
        }
    }

    private func numberKey(_ n: Int, select: Bool) {
        if stack.isEmpty, !shelfItems.isEmpty, frontEnd == .palette {
            guard n - 1 < shelfItems.count else { return }
            if select { selectShelf(n - 1) } else { run(shelfItems[n - 1]) }
            return
        }
        guard n - 1 < items.count else { return }
        self.select(n - 1)
        if !select { runSelected() }
    }

    private func escape() {
        switch behavior().escape {
        case .clearThenBack:
            if shelfSelection != nil { selectShelf(nil); return }
            if !query.isEmpty { query = ""; return }
            if pop() { return }
            if filter != nil { filter = nil; return }
            host?.dismissLauncher(restoreFocus: true)
        case .back:
            if pop() { return }
            host?.dismissLauncher(restoreFocus: true)
        case .dismiss:
            host?.dismissLauncher(restoreFocus: true)
        }
    }

    private func handleConfirmationKey(_ code: Int) -> Bool {
        let choices = confirmation?.alternate == nil ? 2 : 3
        switch code {
        case kVK_Escape: confirmation = nil
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: answerConfirmation(confirmChoice)
        case kVK_LeftArrow: confirmChoice = (confirmChoice - 1 + choices) % choices
        case kVK_RightArrow, kVK_Tab: confirmChoice = (confirmChoice + 1) % choices
        default: break
        }
        return true
    }

    private func handleMenuKey(_ e: NSEvent, code: Int, mods: NSEvent.ModifierFlags) -> Bool {
        guard var menu = actionsMenu else { return false }
        let count = menu.visible.count
        switch code {
        case kVK_Escape:
            if menu.filter.isEmpty { actionsMenu = nil } else { menu.filter = ""; menu.selection = 0; actionsMenu = menu }
        case kVK_ANSI_K where mods == .command:
            actionsMenu = nil
        case kVK_DownArrow, kVK_Tab:
            if count > 0 { menu.selection = (menu.selection + 1) % count }
            actionsMenu = menu
        case kVK_UpArrow:
            if count > 0 { menu.selection = (menu.selection - 1 + count) % count }
            actionsMenu = menu
        case kVK_Return, kVK_ANSI_KeypadEnter:
            runMenuSelection()
        case kVK_Delete:
            if !menu.filter.isEmpty { menu.filter.removeLast(); menu.selection = 0 }
            actionsMenu = menu
        default:
            // Shortcuts work inside the menu too; other typing filters it.
            if !mods.isEmpty, mods != .shift, let s = Shortcut(event: e), let a = menu.actions.first(where: { $0.shortcut == s }) {
                perform(a, of: selectedItem)
                return true
            }
            if mods.subtracting(.shift).isEmpty, let chars = e.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
                menu.filter += chars
                menu.selection = 0
                actionsMenu = menu
            }
        }
        return true
    }

    /// Whether the search field has selected text (set by the window).
    @ObservationIgnored var textSelected: () -> Bool = { false }

    static func digit(_ code: Int) -> Int? {
        switch code {
        case kVK_ANSI_1: 1
        case kVK_ANSI_2: 2
        case kVK_ANSI_3: 3
        case kVK_ANSI_4: 4
        case kVK_ANSI_5: 5
        case kVK_ANSI_6: 6
        case kVK_ANSI_7: 7
        case kVK_ANSI_8: 8
        case kVK_ANSI_9: 9
        default: nil
        }
    }

    // MARK: Previews

    /// Fills the model with fixed results (preview scenes).
    func showPreview(query: String, sections: [ResultSection], selection: Int = 0, page: ListPage? = nil,
                     shelf: [PaletteItem] = [], expanded: Bool = true) {
        shelfItems = shelf
        self.expanded = expanded
        selectOnFocus = false
        switching = true
        if let page { stack = [PageState(page: page, query: query)] }
        self.query = query
        switching = false
        self.sections = sections
        self.selection = selection
        providerCount = Set(sections.flatMap { $0.items.map(\.providerID) }).count
        let item = selectedItem
        details = item?.details ?? item.map { ItemDetails(icon: $0.icon, title: $0.title, subtitle: $0.subtitle) }
    }
}
