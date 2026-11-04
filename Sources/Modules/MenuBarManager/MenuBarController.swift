import AppKit
import MacToysCore
import Observation

/// Live state for the settings page, the quick action and the panels.
@MainActor
@Observable
final class MenuBarState {
    enum Presentation: Equatable { case inMenuBar, bar }

    struct NotchStatus: Equatable {
        /// About how many more icons fit beside the notch.
        var spare: Int
        /// Names of shown items that don't fit and end up under the notch.
        var lost: [String]
    }

    var isRunning = false
    /// Hidden items are showing (in the menu bar or in the separate bar).
    var revealed = false
    var alwaysHiddenRevealed = false
    var presentation: Presentation = .inMenuBar
    var arranging = false
    var items: [MenuBarItem] = []
    var orderProblems: [OrderProblem] = []
    var notch: NotchStatus?

    func count(_ section: MenuBarSection) -> Int { items.filter { $0.section == section }.count }
}

/// Runs Menu Bar Manager: the control items, showing and hiding, the triggers (hover, click,
/// updates, shortcuts), auto-rehide, the separate bar, search, the arrangement card, the notch
/// check and the menu bar tint.
@MainActor
final class MenuBarController {
    let settings: Persisted<MenuBarSettings>
    let hints: Persisted<OrderHints>
    let state = MenuBarState()

    private let controls = ControlItems()
    private let hiddenBar = HiddenBarController()
    private let onboarding = OnboardingController()
    private let search = SearchController()
    private let backdrop = MenuBarBackdrop()
    private let log = Log.for("menubar")

    private var machine: RehideMachine
    private var running = false
    /// True right after the items were (re-)created, until macOS has laid them out and their order
    /// can be checked; nothing collapses meanwhile.
    private var settling = false
    private var forceInPlace = false
    private var settleWork: DispatchWorkItem?
    private var rehideTimer: Timer?
    private var menuPoll: Timer?
    private var updateTimer: Timer?
    private var notchTimer: Timer?
    private var arrangeTimer: Timer?
    private var hoverTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var monitoredMask: NSEvent.EventTypeMask = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    // Pointer tracking (hot path: plain values only).
    private var strip: CGRect = .null
    private var pointerInside = false
    private var pointerInStrip = false
    private var hoverRanges: [ClosedRange<CGFloat>] = []

    private var lastTransition = Date.distantPast
    private var knownWidths: [CGWindowID: CGFloat] = [:]
    private var appMenuEdge: (pid: pid_t, maxX: CGFloat?)?
    private var lastLostCount = 0
    private var warnedCrowdedThisSession = false
    private var lastShortcuts: [String: Shortcut?] = [:]
    private var describeTask: Task<Void, Never>?

    private enum HotkeyID {
        static let toggle = "menubar.toggle"
        static let alwaysHidden = "menubar.alwayshidden"
        static let search = "menubar.search"
    }

    init(settings: Persisted<MenuBarSettings>, hints: Persisted<OrderHints>) {
        self.settings = settings
        self.hints = hints
        machine = RehideMachine(schedule: settings.value.rehideSchedule)
        controls.onAction = { [weak self] role, event in self?.controlClicked(role, event) }
        hiddenBar.model.onActivate = { [weak self] id in self?.activate(id: id) }
        hiddenBar.model.onSearch = { [weak self] in self?.showSearch() }
        onboarding.model.onDone = { [weak self] in self?.finishArranging() }
        search.onChoose = { [weak self] id in self?.activate(id: id) }
        search.model.onGrant = { PermissionCenter.shared.request(.accessibility) }
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        state.isRunning = true
        let s = settings.value
        controls.install(alwaysHidden: s.alwaysHiddenSection, cached: hints.value.controlPositions)
        refreshGeometry()
        beginSettling()
        registerHotkeys()
        backdrop.update(s.appearance)
        observeSystem()
        updateMonitors()
        updateTimers()
        if !s.onboardingCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.beginArranging() }
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        settleWork?.cancel()
        settleWork = nil
        describeTask?.cancel()
        describeTask = nil
        for t in [rehideTimer, menuPoll, updateTimer, notchTimer, arrangeTimer, hoverTimer] { t?.invalidate() }
        rehideTimer = nil; menuPoll = nil; updateTimer = nil; notchTimer = nil; arrangeTimer = nil; hoverTimer = nil
        removeMonitors()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        for id in [HotkeyID.toggle, HotkeyID.alwaysHidden, HotkeyID.search] { HotkeyCenter.shared.unregister(id) }
        lastShortcuts.removeAll()
        hiddenBar.tearDown()
        onboarding.tearDown()
        search.tearDown()
        backdrop.tearDown()
        savePositions(controls.removeAll())
        machine = RehideMachine(schedule: settings.value.rehideSchedule)
        state.isRunning = false
        state.revealed = false
        state.alwaysHiddenRevealed = false
        state.arranging = false
        state.orderProblems = []
        state.items = []
        state.notch = nil
        pointerInside = false
        pointerInStrip = false
        knownWidths.removeAll()
        hints.flush()
    }

    /// Settings changed (page, CLI, restore): bring everything in line.
    func settingsChanged() {
        guard running else { return }
        let s = settings.value
        if s.alwaysHiddenSection != controls.hasAlwaysHidden {
            controls.install(alwaysHidden: s.alwaysHiddenSection, cached: hints.value.controlPositions)
            beginSettling()
        }
        if !s.alwaysHiddenSection { state.alwaysHiddenRevealed = false }
        machine.update(schedule: s.rehideSchedule, now: Date())
        scheduleRehide()
        registerHotkeys()
        backdrop.update(s.appearance)
        if state.revealed && state.presentation == .bar && !s.barMode.usesBar {
            hiddenBar.hide()
            state.presentation = .inMenuBar
        }
        hiddenBar.model.searchEnabled = s.searchEnabled
        onboarding.model.alwaysHiddenSection = s.alwaysHiddenSection
        onboarding.model.chevronStyle = s.chevronStyle
        applyControls()
        updateMonitors()
        updateTimers()
    }

    private func beginSettling() {
        settling = true
        applyControls()
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.settling = false
            self.applyControls()
            self.refreshItems()
            self.knownWidths = self.hiddenWidths(self.state.items)
            self.evaluateNotch(warn: true)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: - Showing and hiding

    func toggle(alwaysHidden: Bool = false) {
        guard running else { return }
        if state.arranging { finishArranging(); return }
        if state.revealed && (!alwaysHidden || state.alwaysHiddenRevealed || !settings.value.alwaysHiddenSection) {
            collapse()
        } else {
            reveal(.manual, alwaysHidden: alwaysHidden)
        }
    }

    func reveal(_ reason: RevealReason, alwaysHidden: Bool = false) {
        guard running, !state.arranging || reason == .arranging else { return }
        let presentation = presentation(for: reason, alwaysHidden: alwaysHidden)
        let wasShowing = state.revealed
        state.revealed = true
        state.alwaysHiddenRevealed = settings.value.alwaysHiddenSection && (alwaysHidden || (wasShowing && state.alwaysHiddenRevealed))
        state.presentation = presentation
        machine.handle(.reveal(reason), now: Date())
        lastTransition = Date()
        applyControls()
        if presentation == .bar {
            showBar()
        } else {
            hiddenBar.hide()
            if reason != .activation { warnIfCrowdedInPlace() }
        }
        scheduleRehide()
        updateMonitors()
        updateTimers()
    }

    /// Hides the items again. `automatic` for rehide timers, which stay quiet about order problems.
    func collapse(automatic: Bool = false) {
        guard running, state.revealed else { return }
        let problems = MenuBarLayout.orderProblems(controls.frames)
        if problems.contains(.chevronLeftOfDivider) && state.presentation == .inMenuBar {
            state.orderProblems = problems
            if !automatic {
                HUD.show("Move the divider to the left of the chevron to hide icons", symbol: "exclamationmark.triangle.fill", duration: 2.4)
            }
            // Hold until the user fixes the order and asks again.
            machine.handle(.reveal(.arranging), now: Date())
            scheduleRehide()
            return
        }
        machine.handle(.hide, now: Date())
        state.revealed = false
        state.alwaysHiddenRevealed = false
        state.presentation = .inMenuBar
        lastTransition = Date()
        hiddenBar.hide()
        menuPoll?.invalidate()
        menuPoll = nil
        applyControls()
        scheduleRehide()
        updateMonitors()
        updateTimers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.state.revealed else { return }
                self.refreshItems()
                self.knownWidths = self.hiddenWidths(self.state.items)
                self.savePositions(self.controls.positions())
            }
        }
    }

    /// Shows hidden items in the menu bar itself whatever the bar setting, following the rehide rules.
    private func revealInPlace(alwaysHidden: Bool) {
        forceInPlace = true
        reveal(.manual, alwaysHidden: alwaysHidden)
        forceInPlace = false
    }

    private func presentation(for reason: RevealReason, alwaysHidden: Bool) -> MenuBarState.Presentation {
        if reason == .arranging || reason == .activation || forceInPlace { return .inMenuBar }
        switch settings.value.barMode {
        case .inMenuBar: return .inMenuBar
        case .separateBar: return .bar
        case .whenCrowded: return isCrowded(alwaysHidden: alwaysHidden) ? .bar : .inMenuBar
        }
    }

    /// Whether the hidden items would land under the notch if shown in place.
    private func isCrowded(alwaysHidden: Bool) -> Bool {
        guard let screen = controls.screen else { return false }
        let bar = MenuBarGeometry.bar(for: screen)
        guard bar.notch != nil else { return false }
        let items = refreshItems()
        let onBar = items.filter { $0.frame.maxX <= bar.maxX + 0.5 }
        let visible = onBar.filter { $0.section == .visible }.map(\.frame.width)
            + [controls.frames.chevron?.width ?? 24]
        let hidden = onBar.filter { $0.section == .hidden || (alwaysHidden && $0.section == .alwaysHidden) }
            .sorted { $0.frame.minX > $1.frame.minX }.map(\.frame.width)
        return MenuBarLayout.isCrowded(bar: bar, visibleWidths: visible, hiddenWidths: hidden)
    }

    /// Lengths and glyphs of the control items for the current state.
    private func applyControls() {
        guard running else { return }
        let s = settings.value
        let problems = settling ? [] : MenuBarLayout.orderProblems(controls.frames)
        if !settling { state.orderProblems = problems }
        onboarding.model.problem = problems.first
        let inPlace = state.revealed && state.presentation == .inMenuBar
        let hold = settling || state.arranging
        let collapsed = !inPlace && !hold && !problems.contains(.chevronLeftOfDivider)
        let ahCollapsed = !(inPlace && state.alwaysHiddenRevealed) && !hold && problems.isEmpty
        let widths = NSScreen.screens.map(\.frame.width)
        controls.apply(ControlItems.Look(collapsed: collapsed, alwaysHiddenCollapsed: ahCollapsed, chevronShowsOpen: state.revealed,
                                         chevron: s.chevronStyle, divider: s.dividerStyle, arranging: state.arranging,
                                         collapsedLength: MenuBarLayout.collapsedLength(screenWidths: widths)))
    }

    // MARK: - Separate bar

    private func showBar() {
        guard let screen = controls.screen else { return }
        let items = refreshItems()
        fillBar(items)
        hiddenBar.model.canOpenDirectly = MenuBarAX.isTrusted
        hiddenBar.model.searchEnabled = settings.value.searchEnabled
        hiddenBar.show(on: screen, menuBarHeight: MenuBarGeometry.menuBarHeight(screen), anchor: controls.chevronScreenFrame)
        describe(items) { [weak self] named in
            guard let self, self.hiddenBar.isVisible else { return }
            self.fillBar(named)
            self.hiddenBar.refit()
        }
    }

    private func fillBar(_ items: [MenuBarItem]) {
        // Nearest the divider first, as they'd appear in the menu bar reading right to left.
        hiddenBar.model.hidden = items.filter { $0.section == .hidden }.map(BarEntry.init)
        hiddenBar.model.alwaysHidden = state.alwaysHiddenRevealed ? items.filter { $0.section == .alwaysHidden }.map(BarEntry.init) : []
    }

    // MARK: - Opening items (separate bar, search)

    private func activate(id: String) {
        guard running else { return }
        let items = refreshItems()
        guard let item = items.first(where: { $0.id == id }) ?? state.items.first(where: { $0.id == id }) else {
            HUD.show("That menu bar item is gone", symbol: "questionmark.circle")
            return
        }
        hiddenBar.hide()
        guard MenuBarAX.isTrusted else {
            // Asked for when the bar or search was turned on; the settings page and search offer it again.
            HUD.show("Showing it in the menu bar — allow Accessibility to open items directly", symbol: "hand.raised.fill", duration: 2.4)
            // Shown in place (the bar would only show it again), long enough to click it by hand.
            revealInPlace(alwaysHidden: item.section == .alwaysHidden)
            return
        }
        let needsReveal = item.section != .visible
        if needsReveal { reveal(.activation, alwaysHidden: item.section == .alwaysHidden) }
        machine.handle(.menuOpened, now: Date())
        scheduleRehide()
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsReveal ? 0.22 : 0.02)) { [weak self] in
            MainActor.assumeIsolated { self?.press(item) }
        }
    }

    /// Presses the item through Accessibility (off the main thread: pressing an item whose menu
    /// opens can block until the menu closes), or clicks it when it can't be pressed.
    private func press(_ item: MenuBarItem) {
        let windows = StatusItemScanner.windows()
        guard let ax = MenuBarAX.element(for: item, in: windows) else {
            log.error("No accessibility element for \(item.id, privacy: .public)")
            clickWindow(of: item, in: windows)
            startMenuPoll()
            return
        }
        let element = ax
        Task.detached(priority: .userInitiated) {
            AXUIElementSetMessagingTimeout(element.element, 1.5)
            let result = AXUIElementPerformAction(element.element, kAXPressAction as CFString)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // A timeout means the item is busy showing its menu, which is what we wanted.
                if result != .success && result != .cannotComplete {
                    self.log.notice("AXPress failed (\(result.rawValue)) for \(item.id, privacy: .public); clicking")
                    self.clickWindow(of: item, in: StatusItemScanner.windows())
                }
                self.startMenuPoll()
            }
        }
    }

    /// Clicks the item's window when it's on a screen, then puts the pointer back.
    private func clickWindow(of item: MenuBarItem, in windows: [StatusWindow]) {
        guard let window = windows.first(where: { $0.id == item.window.id }),
              NSScreen.screens.contains(where: { $0.axFrame.contains(window.frame.center) }) else {
            HUD.show("That item is behind the notch — try the separate bar", symbol: "exclamationmark.triangle.fill", duration: 2.2)
            return
        }
        let back = MouseSynth.location
        MouseSynth.button(.left, down: true, at: window.frame.center)
        MouseSynth.button(.left, down: false, at: window.frame.center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MouseSynth.warp(to: back) }
    }

    // MARK: - Arranging

    func beginArranging() {
        guard running else { return }
        if search.isVisible { search.dismiss(restoreFocus: false) }
        hiddenBar.hide()
        state.arranging = true
        reveal(.arranging, alwaysHidden: true)
        guard let screen = controls.screen else { return }
        onboarding.model.alwaysHiddenSection = settings.value.alwaysHiddenSection
        onboarding.model.chevronStyle = settings.value.chevronStyle
        refreshArrangeCounts()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.state.arranging else { return }
                self.onboarding.show(on: screen, menuBarHeight: MenuBarGeometry.menuBarHeight(screen), anchor: self.controls.chevronScreenFrame)
            }
        }
        arrangeTimer?.invalidate()
        arrangeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshArrangeCounts() }
        }
    }

    func finishArranging() {
        guard state.arranging else { return }
        arrangeTimer?.invalidate()
        arrangeTimer = nil
        onboarding.hide()
        state.arranging = false
        settings.value.onboardingCompleted = true
        applyControls()
        savePositions(controls.positions())
        collapse()
    }

    private func refreshArrangeCounts() {
        guard state.arranging else { return }
        let items = refreshItems()
        onboarding.model.hiddenCount = items.filter { $0.section == .hidden }.count
        onboarding.model.alwaysHiddenCount = items.filter { $0.section == .alwaysHidden }.count
        let problems = MenuBarLayout.orderProblems(controls.frames)
        state.orderProblems = problems
        onboarding.model.problem = problems.first
        if let screen = controls.screen {
            // The card follows the chevron as the user drags things around.
            onboarding.show(on: screen, menuBarHeight: MenuBarGeometry.menuBarHeight(screen), anchor: controls.chevronScreenFrame)
        }
    }

    /// Forgets where the dividers were: they come back at the far left, so nothing is hidden, and
    /// the arrangement card opens.
    func resetPositions() {
        guard running else { return }
        if state.arranging { finishArrangingQuietly() }
        controls.removeAll()
        controls.clearPositions()
        hints.update { $0.controlPositions = [:] }
        machine.handle(.hide, now: Date())
        state.revealed = false
        state.alwaysHiddenRevealed = false
        controls.install(alwaysHidden: settings.value.alwaysHiddenSection, cached: [:])
        beginSettling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.beginArranging() }
        }
    }

    private func finishArrangingQuietly() {
        arrangeTimer?.invalidate()
        arrangeTimer = nil
        onboarding.hide()
        state.arranging = false
    }

    // MARK: - Search

    func showSearch() {
        guard running else { return }
        hiddenBar.hide()
        let items = refreshItems()
        let trusted = MenuBarAX.isTrusted
        search.model.trusted = trusted
        // Without Accessibility items have no names of their own, so search lists each app once.
        search.model.all = (trusted ? items : MenuBarSearch.onePerApp(items)).map(BarEntry.init)
        search.model.loading = trusted
        search.show()
        describe(items) { [weak self] named in
            guard let self else { return }
            self.search.model.all = named.map(BarEntry.init)
            self.search.model.loading = false
        }
    }

    // MARK: - Items

    /// Scans the status item windows, assigns sections and records them.
    @discardableResult
    func refreshItems() -> [MenuBarItem] {
        guard running else { return state.items }
        let windows = StatusItemScanner.windows()
        var items = StatusItemScanner.items(from: windows, controls: controls.frames,
                                            ownControlIDs: controls.windowIDs)
        // Keep names already read through Accessibility.
        let names = Dictionary(state.items.map { ($0.id, ($0.name, $0.identifier)) }, uniquingKeysWith: { a, _ in a })
        for i in items.indices { if let n = names[items[i].id] { items[i].name = n.0; items[i].identifier = n.1 } }
        state.items = items
        recordHints(items)
        return items
    }

    /// Reads item names through Accessibility in the background (when allowed) and hands them back.
    private func describe(_ items: [MenuBarItem], then: @escaping @MainActor ([MenuBarItem]) -> Void) {
        guard MenuBarAX.isTrusted else { return }
        describeTask?.cancel()
        describeTask = Task { [weak self] in
            let named = await Task.detached(priority: .userInitiated) { MenuBarAX.describe(items) }.value
            guard !Task.isCancelled, let self, self.running else { return }
            let byID = Dictionary(named.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            self.state.items = self.state.items.map { item in
                guard let n = byID[item.id] else { return item }
                var copy = item
                copy.name = n.name
                copy.identifier = n.identifier
                return copy
            }
            then(named)
        }
    }

    /// Reads names for the settings page's list.
    func describeForSettings() {
        guard running else { return }
        describe(refreshItems()) { _ in }
    }

    private func recordHints(_ items: [MenuBarItem]) {
        let entries = items.map { (key: $0.id, section: $0.section) }
        var copy = hints.value
        copy.record(entries, now: Date())
        if copy != hints.value { hints.value = copy }
    }

    private func savePositions(_ positions: [String: Double]) {
        guard !positions.isEmpty else { return }
        hints.update { h in
            for (k, v) in positions { h.controlPositions[k] = v }
        }
    }

    // MARK: - Clicks on the control items

    private func controlClicked(_ role: ControlItems.Role, _ event: NSEvent?) {
        let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if rightClick {
            controls.popUp(makeMenu())
            return
        }
        let option = event?.modifierFlags.contains(.option) == true
        toggle(alwaysHidden: option)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Menu Bar Manager"))
        menu.autoenablesItems = false
        func add(_ title: String, _ key: String = "", action: @escaping @MainActor () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: key)
            let target = MenuTarget(action)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        if state.revealed {
            add(String(localized: "Hide Menu Bar Items", comment: "Chevron menu")) { [weak self] in self?.collapse() }
        } else {
            add(String(localized: "Show Hidden Items", comment: "Chevron menu")) { [weak self] in self?.reveal(.manual) }
        }
        if settings.value.alwaysHiddenSection {
            add(String(localized: "Show Always-Hidden Items", comment: "Chevron menu")) { [weak self] in self?.reveal(.manual, alwaysHidden: true) }
        }
        if settings.value.searchEnabled {
            add(String(localized: "Search Menu Bar Items…", comment: "Chevron menu")) { [weak self] in self?.showSearch() }
        }
        menu.addItem(.separator())
        add(String(localized: "Arrange Items…", comment: "Chevron menu: open the arrangement card")) { [weak self] in self?.beginArranging() }
        add(String(localized: "Menu Bar Manager Settings…", comment: "Chevron menu"), ",") {
            ModuleRegistry.shared.showSettings?("menubar")
        }
        return menu
    }

    // MARK: - Shortcuts

    private func registerHotkeys() {
        let s = settings.value
        let wanted: [String: Shortcut?] = [
            HotkeyID.toggle: s.toggleShortcut,
            HotkeyID.alwaysHidden: s.alwaysHiddenSection ? s.alwaysHiddenShortcut : nil,
            HotkeyID.search: s.searchEnabled ? s.searchShortcut : nil,
        ]
        guard wanted != lastShortcuts else { return }
        lastShortcuts = wanted
        HotkeyCenter.shared.register(HotkeyID.toggle, s.toggleShortcut) { [weak self] in self?.toggle() }
        HotkeyCenter.shared.register(HotkeyID.alwaysHidden, wanted[HotkeyID.alwaysHidden] ?? nil) { [weak self] in
            self?.toggle(alwaysHidden: true)
        }
        HotkeyCenter.shared.register(HotkeyID.search, wanted[HotkeyID.search] ?? nil) { [weak self] in self?.showSearch() }
    }

    // MARK: - Pointer: hover, clicks in empty space, holding items open

    /// Installs only the event monitors the current settings and state need.
    private func updateMonitors() {
        let s = settings.value
        var mask: NSEvent.EventTypeMask = []
        if running && (s.showOnHover || state.revealed) { mask.insert(.mouseMoved) }
        if running && (s.showOnEmptyClick || hiddenBar.isVisible || state.presentation == .bar && state.revealed) { mask.insert(.leftMouseDown) }
        guard mask != monitoredMask else { return }
        removeMonitors()
        monitoredMask = mask
        guard !mask.isEmpty else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.pointerEvent(type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.pointerEvent(type) }
            return event
        }
        if mask.contains(.mouseMoved) { pointerEvent(.mouseMoved) }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        monitoredMask = []
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// Called for every mouse move while monitoring: O(1) rectangle checks on cached geometry.
    private func pointerEvent(_ type: NSEvent.EventType) {
        guard running else { return }
        let p = NSEvent.mouseLocation
        if type == .leftMouseDown {
            pointerClicked(p)
            return
        }
        let inStrip = strip.contains(p)
        let inside = inStrip || hiddenBar.contains(p) || onboarding.contains(p)
        if inside != pointerInside {
            pointerInside = inside
            if inside {
                machine.handle(.pointerEntered, now: Date())
            } else {
                if state.revealed && StatusItemScanner.menuIsOpen(excluding: ownWindowIDs) {
                    machine.handle(.menuOpened, now: Date())
                    startMenuPoll()
                }
                machine.handle(.pointerLeft, now: Date())
            }
            scheduleRehide()
        }
        if inStrip != pointerInStrip {
            pointerInStrip = inStrip
            hoverRanges = inStrip && settings.value.showOnHover && !state.revealed ? emptyRanges() : []
        }
        guard settings.value.showOnHover, !state.revealed, inStrip, hoverRanges.contains(where: { $0.contains(p.x) }) else {
            hoverTimer?.invalidate()
            hoverTimer = nil
            return
        }
        guard hoverTimer == nil else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, settings.value.hoverDelay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverFired() }
        }
    }

    private func hoverFired() {
        hoverTimer = nil
        let p = NSEvent.mouseLocation
        guard running, !state.revealed, strip.contains(p), NSEvent.pressedMouseButtons == 0,
              hoverRanges.contains(where: { $0.contains(p.x) }),
              !StatusItemScanner.menuIsOpen(excluding: ownWindowIDs) else { return }
        reveal(.hover)
    }

    private func pointerClicked(_ p: CGPoint) {
        if state.revealed && state.presentation == .bar && !hiddenBar.contains(p) && !strip.contains(p) {
            collapse(automatic: true)
            return
        }
        guard settings.value.showOnEmptyClick, strip.contains(p) else { return }
        guard emptyRanges().contains(where: { $0.contains(p.x) }) else { return }
        if state.revealed { collapse() } else { reveal(.click) }
    }

    /// Free stretches of the status items' menu bar right now (one window list read).
    private func emptyRanges() -> [ClosedRange<CGFloat>] {
        guard let screen = controls.screen else { return [] }
        let bar = MenuBarGeometry.bar(for: screen)
        let statusMinX = StatusItemScanner.windows(onScreenOnly: true)
            .filter { $0.frame.minX >= bar.minX - 0.5 && $0.frame.maxX <= bar.maxX + 0.5 }
            .map(\.frame.minX).min()
        return MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: statusMinX, appMenuMaxX: appMenuMaxX())
    }

    /// The front app's menus' right edge, read through Accessibility only if MacToys already has it.
    private func appMenuMaxX() -> CGFloat? {
        guard MenuBarAX.isTrusted, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        if let cached = appMenuEdge, cached.pid == pid { return cached.maxX }
        let edge = MenuBarAX.appMenuMaxX(pid: pid)
        appMenuEdge = (pid, edge)
        return edge
    }

    private var ownWindowIDs: Set<CGWindowID> {
        var ids = controls.windowIDs.union(backdrop.windowIDs)
        if let id = hiddenBar.windowID { ids.insert(id) }
        if let id = onboarding.windowID { ids.insert(id) }
        return ids
    }

    // MARK: - Rehide timing

    private func scheduleRehide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
        guard running, let deadline = machine.deadline else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.rehideFired() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        rehideTimer = timer
    }

    private func rehideFired() {
        rehideTimer = nil
        guard running, state.revealed else { return }
        if StatusItemScanner.menuIsOpen(excluding: ownWindowIDs) {
            machine.handle(.menuOpened, now: Date())
            startMenuPoll()
            return
        }
        if machine.tick(now: Date()) {
            collapse(automatic: true)
        } else {
            scheduleRehide()
        }
    }

    /// Watches for the menu that holds items open to close.
    private func startMenuPoll() {
        guard menuPoll == nil else { return }
        menuPoll = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.running, self.state.revealed else {
                    self.menuPoll?.invalidate()
                    self.menuPoll = nil
                    return
                }
                if !StatusItemScanner.menuIsOpen(excluding: self.ownWindowIDs) {
                    self.menuPoll?.invalidate()
                    self.menuPoll = nil
                    self.machine.handle(.menuClosed, now: Date())
                    self.scheduleRehide()
                }
            }
        }
    }

    // MARK: - Updates and the notch

    private func updateTimers() {
        let s = settings.value
        let wantUpdates = running && s.showOnUpdate && !state.revealed
        if wantUpdates && updateTimer == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateTick() } }
            t.tolerance = 0.5
            RunLoop.main.add(t, forMode: .common)
            updateTimer = t
        } else if !wantUpdates {
            updateTimer?.invalidate()
            updateTimer = nil
        }
        let wantNotch = running && s.notchWarning && MenuBarGeometry.anyNotch
        if wantNotch && notchTimer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.evaluateNotch(warn: true) } }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            notchTimer = t
        } else if !wantNotch {
            notchTimer?.invalidate()
            notchTimer = nil
        }
    }

    /// Shows hidden items for a moment when one of them changes size (timers, counters, badges) or
    /// a new item appears in a hidden section.
    private func updateTick() {
        guard running, settings.value.showOnUpdate, !state.revealed, !state.arranging,
              Date().timeIntervalSince(lastTransition) > 2 else { return }
        let before = Set(hints.value.items.keys)
        let items = refreshItems()
        let widths = hiddenWidths(items)
        let changed = widths.contains { id, w in knownWidths[id].map { abs($0 - w) >= 2 } ?? false }
        knownWidths = widths
        let fresh = items.filter { !before.contains($0.id) && $0.section != .visible }
        guard changed || !fresh.isEmpty else { return }
        log.info("hidden item changed; showing briefly")
        reveal(.update, alwaysHidden: fresh.contains { $0.section == .alwaysHidden })
    }

    private func hiddenWidths(_ items: [MenuBarItem]) -> [CGWindowID: CGFloat] {
        var widths: [CGWindowID: CGFloat] = [:]
        for item in items where item.section == .hidden { widths[item.window.id] = item.frame.width }
        return widths
    }

    /// Works out how much room is left beside the notch and which shown items don't fit.
    func evaluateNotch(warn: Bool) {
        guard running, let screen = controls.screen else { return }
        let bar = MenuBarGeometry.bar(for: screen)
        guard bar.notch != nil else {
            state.notch = nil
            lastLostCount = 0
            return
        }
        let items = state.items.isEmpty ? refreshItems() : state.items
        let shown = items.filter { $0.section == .visible || (state.revealed && state.presentation == .inMenuBar && $0.section == .hidden) }
            .sorted { $0.frame.minX > $1.frame.minX }
        var widths = shown.map(\.frame.width)
        var names = shown.map(\.title)
        // The chevron (and a visible divider) take room too.
        if let chevron = controls.frames.chevron {
            widths.insert(chevron.width, at: 0)
            names.insert("", at: 0)
        }
        let lost = MenuBarLayout.overflowing(room: bar.statusRoom, widths: widths, margin: 8).map { names[$0] }.filter { !$0.isEmpty }
        let used = widths.reduce(0, +)
        state.notch = MenuBarState.NotchStatus(spare: MenuBarLayout.spareSlots(room: bar.statusRoom - 8, used: used), lost: lost)
        if warn && settings.value.notchWarning && lost.count > lastLostCount && !state.revealed {
            HUD.show("\(lost.count) menu bar icons don't fit beside the notch", symbol: "exclamationmark.triangle.fill", duration: 2.6)
        }
        if !state.revealed { lastLostCount = lost.count }
    }

    /// Once per session: hidden items shown in place won't all fit beside the notch.
    private func warnIfCrowdedInPlace() {
        guard settings.value.notchWarning, !warnedCrowdedThisSession, settings.value.barMode == .inMenuBar,
              isCrowded(alwaysHidden: state.alwaysHiddenRevealed) else { return }
        warnedCrowdedThisSession = true
        HUD.show("Some icons are behind the notch — the separate bar can show them", symbol: "rectangle.topthird.inset.filled", duration: 2.8)
    }

    // MARK: - System events

    private func refreshGeometry() {
        strip = controls.screen.map(MenuBarGeometry.strip(for:)) ?? .null
        pointerInStrip = false
    }

    private func observeSystem() {
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { c in
            c.relayout()
        }
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didWakeNotification) { c in c.relayout() }
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { c in
            c.refreshGeometry()
            c.backdrop.refresh()
        }
        observe(ws, NSWorkspace.didActivateApplicationNotification) { c in c.appMenuEdge = nil }
        observe(ws, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { c in c.backdrop.refresh() }
        observe(DistributedNotificationCenter.default(), SettingsStore.externalChangeNotification) { c in c.settings.reload() }
    }

    /// macOS re-laid out the menu bar (display change, wake): re-apply lengths, re-check the order.
    private func relayout() {
        refreshGeometry()
        controls.invalidate()
        beginSettling()
        backdrop.refresh()
        updateTimers()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (MenuBarController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                body(self)
            }
        }
        observers.append((center, token))
    }
}

/// Target for closure-based menu items.
@MainActor
private final class MenuTarget: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func run(_ sender: Any?) { action() }
}
