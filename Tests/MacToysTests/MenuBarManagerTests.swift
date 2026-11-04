import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import MenuBarManager

@Suite struct MenuBarManagerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Divider lengths

    @Test func collapsedDividerIsWiderThanTwiceTheWidestDisplay() {
        #expect(MenuBarLayout.collapsedLength(screenWidths: []) == 10_000)
        #expect(MenuBarLayout.collapsedLength(screenWidths: [1440, 1512]) == 10_000)
        #expect(MenuBarLayout.collapsedLength(screenWidths: [1512, 6016]) == 12_032)
    }

    @Test func expandedDividerWidthFollowsTheStyle() {
        #expect(MenuBarLayout.expandedLength(style: .line, arranging: false) == 14)
        #expect(MenuBarLayout.expandedLength(style: .dots, arranging: false) == 14)
        #expect(MenuBarLayout.expandedLength(style: .none, arranging: false) == 0)
        // An invisible divider still shows while arranging, or nobody could drag icons across it.
        #expect(MenuBarLayout.expandedLength(style: .none, arranging: true) == 14)
    }

    // MARK: - Displays with and without a notch

    @Test func displayWithoutNotchGivesStatusItemsTheWholeWidth() {
        let bar = BarGeometry.make(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), menuBarHeight: 24,
                                   topLeftArea: nil, topRightArea: nil)
        #expect(bar.notch == nil)
        #expect(bar.statusRoom == 1440)
        #expect(bar.width == 1440)
    }

    @Test func notchFromGlobalAuxiliaryAreas() {
        let bar = BarGeometry.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), menuBarHeight: 37,
                                   topLeftArea: CGRect(x: 0, y: 945, width: 660, height: 37),
                                   topRightArea: CGRect(x: 852, y: 945, width: 660, height: 37))
        #expect(bar.notch == 660...852)
        #expect(bar.statusRoom == 660)
    }

    @Test func notchFromScreenLocalAreasOnADisplayLeftOfThePrimary() {
        let bar = BarGeometry.make(frame: CGRect(x: -1512, y: 0, width: 1512, height: 982), menuBarHeight: 37,
                                   topLeftArea: CGRect(x: 0, y: 945, width: 660, height: 37),
                                   topRightArea: CGRect(x: 852, y: 945, width: 660, height: 37))
        #expect(bar.notch == -852 ... -660)
        #expect(bar.statusRoom == 660)
    }

    @Test func notchFromScreenLocalAreasOnADisplayRightOfThePrimary() {
        let bar = BarGeometry.make(frame: CGRect(x: 1920, y: 0, width: 1728, height: 1117), menuBarHeight: 38,
                                   topLeftArea: CGRect(x: 0, y: 1079, width: 764, height: 38),
                                   topRightArea: CGRect(x: 964, y: 1079, width: 764, height: 38))
        #expect(bar.notch == 2684...2884)
        #expect(bar.statusRoom == 764)
    }

    @Test func emptyAuxiliaryAreasMeanNoNotch() {
        let bar = BarGeometry.make(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), menuBarHeight: 24,
                                   topLeftArea: .zero, topRightArea: .zero)
        #expect(bar.notch == nil)
    }

    // MARK: - Sections

    @Test func sectionsWhileCollapsed() {
        // The hidden divider's slot ends at x = 1200 and it reaches 10 000 pt to the left; the
        // hidden icons sit left of it, then the collapsed always-hidden divider, then its icons.
        let controls = ControlFrames(chevron: CGRect(x: 1200, y: 0, width: 24, height: 24),
                                     hidden: CGRect(x: 1200 - 10_000, y: 0, width: 10_000, height: 24),
                                     alwaysHidden: CGRect(x: -8_900 - 10_000, y: 0, width: 10_000, height: 24))
        #expect(MenuBarLayout.section(of: CGRect(x: 1230, y: 0, width: 30, height: 24), controls: controls) == .visible)
        #expect(MenuBarLayout.section(of: CGRect(x: -8_860, y: 0, width: 30, height: 24), controls: controls) == .hidden)
        #expect(MenuBarLayout.section(of: CGRect(x: -18_950, y: 0, width: 30, height: 24), controls: controls) == .alwaysHidden)
    }

    @Test func sectionsWhileShown() {
        let controls = ControlFrames(chevron: CGRect(x: 1000, y: 0, width: 24, height: 24),
                                     hidden: CGRect(x: 960, y: 0, width: 14, height: 24),
                                     alwaysHidden: CGRect(x: 800, y: 0, width: 14, height: 24))
        #expect(MenuBarLayout.section(of: CGRect(x: 1100, y: 0, width: 30, height: 24), controls: controls) == .visible)
        #expect(MenuBarLayout.section(of: CGRect(x: 900, y: 0, width: 30, height: 24), controls: controls) == .hidden)
        #expect(MenuBarLayout.section(of: CGRect(x: 700, y: 0, width: 30, height: 24), controls: controls) == .alwaysHidden)
        // An invisible (zero-width) divider still splits the sections.
        let zero = ControlFrames(chevron: nil, hidden: CGRect(x: 960, y: 0, width: 0, height: 24), alwaysHidden: nil)
        #expect(MenuBarLayout.section(of: CGRect(x: 961, y: 0, width: 30, height: 24), controls: zero) == .visible)
        #expect(MenuBarLayout.section(of: CGRect(x: 920, y: 0, width: 30, height: 24), controls: zero) == .hidden)
    }

    @Test func everythingIsVisibleWithoutADivider() {
        #expect(MenuBarLayout.section(of: CGRect(x: 10, y: 0, width: 30, height: 24), controls: ControlFrames()) == .visible)
    }

    @Test func orderProblemsKeepTheChevronFromBeingHidden() {
        let good = ControlFrames(chevron: CGRect(x: 1000, y: 0, width: 24, height: 24),
                                 hidden: CGRect(x: 980, y: 0, width: 14, height: 24),
                                 alwaysHidden: CGRect(x: 900, y: 0, width: 14, height: 24))
        #expect(MenuBarLayout.orderProblems(good).isEmpty)

        var chevronLeft = good
        chevronLeft.chevron = CGRect(x: 940, y: 0, width: 24, height: 24)
        #expect(MenuBarLayout.orderProblems(chevronLeft) == [.chevronLeftOfDivider])

        var ahRight = good
        ahRight.alwaysHidden = CGRect(x: 1040, y: 0, width: 14, height: 24)
        #expect(MenuBarLayout.orderProblems(ahRight) == [.alwaysHiddenRightOfDivider])

        // A collapsed divider keeps its right edge at its slot, so the check works collapsed too.
        let collapsed = ControlFrames(chevron: CGRect(x: 1000, y: 0, width: 24, height: 24),
                                      hidden: CGRect(x: 994 - 10_000, y: 0, width: 10_000, height: 24), alwaysHidden: nil)
        #expect(MenuBarLayout.orderProblems(collapsed).isEmpty)
        #expect(MenuBarLayout.orderProblems(ControlFrames()).isEmpty)
    }

    // MARK: - How many items fit

    @Test func fittingCountBesideTheNotch() {
        // 660 pt right of the notch; shown: Control Center, clock and friends take 280.
        let visible: [CGFloat] = [30, 30, 30, 30, 40, 120]
        #expect(MenuBarLayout.fittingCount(room: 660, visibleWidths: visible, hiddenWidths: Array(repeating: 30, count: 8)) == 8)
        #expect(MenuBarLayout.fittingCount(room: 660, visibleWidths: visible, hiddenWidths: Array(repeating: 30, count: 15)) == 12)
        #expect(MenuBarLayout.fittingCount(room: 200, visibleWidths: visible, hiddenWidths: [30]) == 0)
        #expect(MenuBarLayout.fittingCount(room: 660, visibleWidths: [], hiddenWidths: []) == 0)
    }

    @Test func overflowingItemsAreTheLeftmost() {
        #expect(MenuBarLayout.overflowing(room: 300, widths: [100, 100, 80, 50]) == [3])
        #expect(MenuBarLayout.overflowing(room: 300, widths: [100, 100, 80, 50], margin: 30) == [2, 3])
        #expect(MenuBarLayout.overflowing(room: 1000, widths: [100, 100]).isEmpty)
    }

    @Test func crowdedOnlyWithANotch() {
        let plain = BarGeometry(minX: 0, maxX: 1440, height: 24, notch: nil)
        #expect(!MenuBarLayout.isCrowded(bar: plain, visibleWidths: Array(repeating: 40, count: 30), hiddenWidths: [40, 40]))
        let notched = BarGeometry(minX: 0, maxX: 1512, height: 37, notch: 660...852)
        #expect(MenuBarLayout.isCrowded(bar: notched, visibleWidths: Array(repeating: 40, count: 14), hiddenWidths: [40, 40, 40]))
        #expect(!MenuBarLayout.isCrowded(bar: notched, visibleWidths: Array(repeating: 40, count: 8), hiddenWidths: [40, 40, 40]))
    }

    @Test func itemsUnderTheNotch() {
        let bar = BarGeometry(minX: 0, maxX: 1512, height: 37, notch: 660...852)
        let frames = [CGRect(x: 1400, y: 0, width: 30, height: 37), CGRect(x: 840, y: 0, width: 30, height: 37),
                      CGRect(x: 700, y: 0, width: 30, height: 37), CGRect(x: -400, y: 0, width: 30, height: 37)]
        #expect(MenuBarLayout.underNotch(frames, bar: bar) == [1, 2])
        #expect(MenuBarLayout.underNotch(frames, bar: BarGeometry(minX: 0, maxX: 1440, height: 24, notch: nil)).isEmpty)
    }

    @Test func spareSlots() {
        #expect(MenuBarLayout.spareSlots(room: 660, used: 400) == 8)
        #expect(MenuBarLayout.spareSlots(room: 300, used: 400) == 0)
    }

    // MARK: - Empty menu bar space

    @Test func emptySpaceWithoutAccessibilityIsHalfTheGap() {
        let bar = BarGeometry(minX: 0, maxX: 1440, height: 24, notch: nil)
        let ranges = MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: 1100, appMenuMaxX: nil)
        #expect(ranges == [549...1098])
    }

    @Test func emptySpaceStartsAfterTheAppMenus() {
        let bar = BarGeometry(minX: 0, maxX: 1440, height: 24, notch: nil)
        #expect(MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: 1100, appMenuMaxX: 420) == [426...1098])
        // Menus that reach the icons leave no empty space.
        #expect(MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: 1100, appMenuMaxX: 1095).isEmpty)
    }

    @Test func emptySpaceAroundTheNotch() {
        let bar = BarGeometry(minX: 0, maxX: 1512, height: 37, notch: 660...852)
        #expect(MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: 1200, appMenuMaxX: nil) == [856...1198])
        #expect(MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: 1200, appMenuMaxX: 400) == [406...656, 856...1198])
        // Menus spilling past the notch push the right-hand space over.
        #expect(MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: 1200, appMenuMaxX: 900) == [910...1198])
    }

    @Test func emptySpaceOnADisplayLeftOfThePrimary() {
        let bar = BarGeometry(minX: -1440, maxX: 0, height: 24, notch: nil)
        #expect(MenuBarLayout.emptyRanges(bar: bar, statusItemsMinX: -300, appMenuMaxX: nil) == [-871 ... -302])
    }

    @Test func itemKeys() {
        #expect(MenuBarLayout.itemKey(bundleID: "com.example.sync", ordinalFromRight: 0) == "com.example.sync#0")
    }

    // MARK: - Auto-rehide

    private func machine(after: TimeInterval? = 10, leaves: Bool = false) -> RehideMachine {
        RehideMachine(schedule: RehideSchedule(afterDelay: after, whenPointerLeaves: leaves))
    }

    @Test func manualRevealHidesAfterTheDelay() {
        var m = machine(after: 10)
        m.handle(.reveal(.manual), now: t0)
        #expect(m.isShown)
        #expect(m.deadline == t0.addingTimeInterval(10))
        let fired1 = m.tick(now: t0.addingTimeInterval(9))
        #expect(!fired1)
        let fired2 = m.tick(now: t0.addingTimeInterval(10.1))
        #expect(fired2)
        #expect(!m.isShown)
        #expect(m.deadline == nil)
    }

    @Test func noTimedRehideWithoutADelay() {
        var m = machine(after: nil)
        m.handle(.reveal(.manual), now: t0)
        #expect(m.deadline == nil)
        let fired3 = m.tick(now: t0.addingTimeInterval(3600))
        #expect(!fired3)
        #expect(m.isShown)
    }

    @Test func pointerOnTheMenuBarHoldsAndRestartsTheCountdown() {
        var m = machine(after: 10)
        m.handle(.reveal(.manual), now: t0)
        m.handle(.pointerEntered, now: t0.addingTimeInterval(2))
        #expect(m.deadline == nil)
        let fired4 = m.tick(now: t0.addingTimeInterval(20))
        #expect(!fired4)
        m.handle(.pointerLeft, now: t0.addingTimeInterval(20))
        #expect(m.deadline == t0.addingTimeInterval(30))
    }

    @Test func pointerLeavingHidesOnlyAfterItWasThere() {
        var m = machine(after: nil, leaves: true)
        m.handle(.reveal(.manual), now: t0)   // e.g. a shortcut, pointer elsewhere
        #expect(m.deadline == nil)
        m.handle(.pointerEntered, now: t0.addingTimeInterval(1))
        m.handle(.pointerLeft, now: t0.addingTimeInterval(3))
        #expect(m.deadline == t0.addingTimeInterval(3 + RehideMachine.leaveGrace))
        let fired5 = m.tick(now: t0.addingTimeInterval(4))
        #expect(fired5)
    }

    @Test func hoverRevealsHideWhenThePointerLeaves() {
        var m = machine(after: nil, leaves: false)
        m.handle(.pointerEntered, now: t0)
        m.handle(.reveal(.hover), now: t0)
        #expect(m.deadline == nil)
        m.handle(.pointerLeft, now: t0.addingTimeInterval(5))
        #expect(m.deadline == t0.addingTimeInterval(5 + RehideMachine.leaveGrace))
    }

    @Test func updatesShowBrieflyWhateverTheDelay() {
        var m = machine(after: 60)
        m.handle(.reveal(.update), now: t0)
        #expect(m.deadline == t0.addingTimeInterval(RehideMachine.updateDuration))
        var visited = machine(after: 60)
        visited.handle(.reveal(.update), now: t0)
        visited.handle(.pointerEntered, now: t0.addingTimeInterval(1))
        visited.handle(.pointerLeft, now: t0.addingTimeInterval(2))
        #expect(visited.deadline == t0.addingTimeInterval(2 + RehideMachine.leaveGrace))
    }

    @Test func openMenuHoldsItemsOpen() {
        var m = machine(after: 3)
        m.handle(.reveal(.manual), now: t0)
        m.handle(.menuOpened, now: t0.addingTimeInterval(1))
        #expect(m.isHeld)
        let fired6 = m.tick(now: t0.addingTimeInterval(10))
        #expect(!fired6)
        m.handle(.menuClosed, now: t0.addingTimeInterval(10))
        #expect(m.deadline == t0.addingTimeInterval(13))
    }

    @Test func activationHidesSoonAfterTheMenuCloses() {
        var m = machine(after: 30)
        m.handle(.reveal(.activation), now: t0)
        m.handle(.menuOpened, now: t0)
        m.handle(.menuClosed, now: t0.addingTimeInterval(8))
        #expect(m.deadline == t0.addingTimeInterval(8 + RehideMachine.leaveGrace))
    }

    @Test func arrangingNeverHidesOnItsOwn() {
        var m = machine(after: 1, leaves: true)
        m.handle(.reveal(.arranging), now: t0)
        m.handle(.pointerEntered, now: t0)
        m.handle(.pointerLeft, now: t0.addingTimeInterval(1))
        #expect(m.deadline == nil)
        let fired7 = m.tick(now: t0.addingTimeInterval(1000))
        #expect(!fired7)
    }

    @Test func deliberateRevealsOutrankPassiveOnes() {
        var m = machine()
        m.handle(.reveal(.hover), now: t0)
        m.handle(.reveal(.manual), now: t0)
        #expect(m.reason == .manual)
        m.handle(.reveal(.hover), now: t0)
        #expect(m.reason == .manual)
        var u = machine()
        u.handle(.reveal(.update), now: t0)
        u.handle(.reveal(.hover), now: t0)
        #expect(u.reason == .hover)
        u.handle(.hide, now: t0)
        u.handle(.reveal(.update), now: t0)
        #expect(u.reason == .update)
    }

    @Test func changingTheScheduleRestartsTheCountdown() {
        var m = machine(after: 30)
        m.handle(.reveal(.manual), now: t0)
        m.update(schedule: RehideSchedule(afterDelay: 5, whenPointerLeaves: false), now: t0.addingTimeInterval(2))
        #expect(m.deadline == t0.addingTimeInterval(7))
    }

    @Test func hiddenMachineIgnoresTicks() {
        var m = machine()
        let fired8 = m.tick(now: t0)
        #expect(!fired8)
        m.handle(.pointerEntered, now: t0)
        m.handle(.pointerLeft, now: t0)
        #expect(m.deadline == nil)
    }

    @Test func settingsBuildTheSchedule() {
        var s = MenuBarSettings()
        #expect(s.rehideSchedule == RehideSchedule(afterDelay: 15, whenPointerLeaves: false))
        s.rehideAfterDelay = false
        s.rehideWhenPointerLeaves = true
        #expect(s.rehideSchedule == RehideSchedule(afterDelay: nil, whenPointerLeaves: true))
        s.rehideAfterDelay = true
        s.rehideDelay = 0
        #expect(s.rehideSchedule.afterDelay == 1)
    }

    // MARK: - Order hints

    @Test func hintsReportNewItemsOnce() {
        var h = OrderHints()
        let fresh = h.record([(key: "a#0", section: .visible), (key: "b#0", section: .hidden)], now: t0)
        #expect(Set(fresh) == ["a#0", "b#0"])
        let again = h.record([(key: "a#0", section: .visible), (key: "c#0", section: .alwaysHidden)], now: t0.addingTimeInterval(60))
        #expect(again == ["c#0"])
        #expect(h.items["b#0"]?.section == .hidden)
    }

    @Test func repeatedSightingsDontRewriteHints() {
        var h = OrderHints()
        h.record([(key: "a#0", section: .hidden)], now: t0)
        let before = h
        h.record([(key: "a#0", section: .hidden)], now: t0.addingTimeInterval(60))
        #expect(h == before)
        h.record([(key: "a#0", section: .visible)], now: t0.addingTimeInterval(120))
        #expect(h.items["a#0"] == OrderHints.ItemHint(section: .visible, lastSeen: t0.addingTimeInterval(120)))
        h.record([(key: "a#0", section: .visible)], now: t0.addingTimeInterval(OrderHints.refreshInterval + 200))
        #expect(h.items["a#0"]?.lastSeen == t0.addingTimeInterval(OrderHints.refreshInterval + 200))
    }

    @Test func hintsNoticeMovedItems() {
        var h = OrderHints()
        h.record([(key: "a#0", section: .hidden), (key: "b#0", section: .visible)], now: t0)
        #expect(h.moved([(key: "a#0", section: .visible), (key: "b#0", section: .visible), (key: "new#0", section: .hidden)]) == ["a#0"])
    }

    @Test func hintsForgetOldAndExcessItems() {
        var h = OrderHints()
        h.items["old#0"] = OrderHints.ItemHint(section: .hidden, lastSeen: t0.addingTimeInterval(-OrderHints.maxAge - 10))
        h.record([(key: "a#0", section: .visible)], now: t0)
        #expect(h.items["old#0"] == nil)
        let many = (0..<(OrderHints.maxItems + 20)).map { (key: "k\($0)#0", section: MenuBarSection.hidden) }
        var big = OrderHints()
        for (i, e) in many.enumerated() { big.record([e], now: t0.addingTimeInterval(TimeInterval(i))) }
        #expect(big.items.count == OrderHints.maxItems)
        #expect(big.items["k0#0"] == nil)
        #expect(big.items["k\(OrderHints.maxItems + 19)#0"] != nil)
    }

    @Test func hintsRoundTripThroughTheSettingsStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var h = OrderHints()
        h.controlPositions = ["com.w33d.mactoys.menubar.chevron": 312, "com.w33d.mactoys.menubar.hidden": 340.5]
        h.record([(key: "com.example.sync#0", section: .hidden), (key: "com.apple.controlcenter#2", section: .visible)], now: t0)
        store.save(h, id: "hints", defaults: OrderHints())
        let loaded = store.load("hints", default: OrderHints())
        #expect(loaded == h)
        // A file from before a field existed still loads.
        try Data(#"{"controlPositions":{"x":1}}"#.utf8).write(to: store.url(for: "old"))
        #expect(store.load("old", default: OrderHints()).controlPositions == ["x": 1])
    }

    @Test func statusItemDefaultsKeepPositionsAcrossRemoval() throws {
        let suite = "mactoys.tests.menubar.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let d = StatusItemDefaults(defaults: defaults)
        let names = ControlItems.autosaveNames
        #expect(StatusItemDefaults.positionKey(names[0]) == "NSStatusItem Preferred Position com.w33d.mactoys.menubar.chevron")

        d.setPosition(412, for: names[0])
        d.setPosition(440, for: names[1])
        let cached = d.capture(names)
        #expect(cached == [names[0]: 412, names[1]: 440])

        // AppKit drops the positions when the items are removed…
        defaults.removeObject(forKey: StatusItemDefaults.positionKey(names[0]))
        defaults.removeObject(forKey: StatusItemDefaults.positionKey(names[1]))
        // …and after the user moved the chevron somewhere new, the newer value wins.
        d.setPosition(500, for: names[0])
        d.restore(cached, names: names)
        #expect(d.position(names[0]) == 500)
        #expect(d.position(names[1]) == 440)
        #expect(d.position(names[2]) == nil)

        defaults.set(false, forKey: StatusItemDefaults.visibleKey(names[0]))
        d.markVisible(names[0])
        #expect(defaults.object(forKey: StatusItemDefaults.visibleKey(names[0])) == nil)
    }

    // MARK: - Search ranking

    private func entry(_ title: String, app: String? = nil, _ section: MenuBarSection = .hidden) -> SearchEntry {
        SearchEntry(id: "\(app ?? title)/\(title)", title: title, appName: app ?? title, section: section)
    }

    private func titles(_ entries: [SearchEntry], _ query: String) -> [String] {
        MenuBarSearch.rank(entries, query: query).map(\.title)
    }

    @Test func prefixBeatsWordStartBeatsSubstringBeatsLooseLetters() {
        let entries = [entry("Docker"), entry("Hydrate"), entry("Google Drive"), entry("AirDrop", app: "Control Center"), entry("Dropbox")]
        #expect(titles(entries, "dr") == ["Dropbox", "AirDrop", "Google Drive", "Hydrate", "Docker"])
    }

    @Test func shorterTitleWinsATie() {
        let entries = [entry("Window Manager"), entry("Wi‑Fi", app: "Control Center", .visible)]
        #expect(titles(entries, "wi") == ["Wi‑Fi", "Window Manager"])
        #expect(titles(entries, "wifi") == ["Wi‑Fi"])
    }

    @Test func appNameCountsLessThanTheItemsOwnName() {
        let entries = [entry("Battery", app: "Control Center", .visible), entry("Control Center", app: "Control Center", .visible),
                       entry("Clock", app: "Control Center", .visible)]
        let ranked = titles(entries, "control")
        #expect(ranked.first == "Control Center")
        #expect(Set(ranked) == ["Battery", "Control Center", "Clock"])
    }

    @Test func everyQueryWordMustMatch() {
        let entries = [entry("Tailscale VPN", app: "Tailscale"), entry("VPN", app: "Control Center"), entry("Tailwind")]
        #expect(titles(entries, "tail vpn") == ["Tailscale VPN"])
        #expect(titles(entries, "tv") == ["Tailscale VPN"])
    }

    @Test func searchFoldsCaseAndAccents() {
        let entries = [entry("Café Timer"), entry("Résumé Sync")]
        #expect(titles(entries, "CAFE") == ["Café Timer"])
        #expect(titles(entries, "resume") == ["Résumé Sync"])
        #expect(titles(entries, "zzz").isEmpty)
    }

    @Test func emptyQueryListsByAppThenName() {
        let entries = [entry("Wi‑Fi", app: "Control Center"), entry("Sync", app: "Dropbox"), entry("Battery", app: "Control Center")]
        #expect(titles(entries, "  ") == ["Battery", "Wi‑Fi", "Sync"])
    }

    @Test func camelCaseWordsAndInitials() {
        #expect(MenuBarSearch.words("AirDrop") == ["air", "drop", "airdrop"])
        #expect(MenuBarSearch.initials("Tailscale VPN") == "tv")
        #expect(MenuBarSearch.normalize("Wi‑Fi  Status!") == "wi fi status")
    }

    @Test func withoutNamesSearchListsEachAppOnceByItsRightmostItem() {
        func item(_ bundle: String, _ n: Int, x: CGFloat) -> MenuBarItem {
            let w = StatusWindow(id: CGWindowID(x), pid: 1, ownerName: bundle, frame: CGRect(x: x, y: 0, width: 24, height: 24), isOnScreen: true)
            return MenuBarItem(id: MenuBarLayout.itemKey(bundleID: bundle, ordinalFromRight: n), window: w, bundleID: bundle,
                               appName: bundle, section: .visible)
        }
        let items = [item("cc", 2, x: 100), item("drop", 0, x: 130), item("cc", 1, x: 160), item("cc", 0, x: 190)]
        #expect(MenuBarSearch.onePerApp(items).map(\.id) == ["drop#0", "cc#0"])
    }

    // MARK: - Settings

    @Test func accessibilityOnlyForSearchAndTheSeparateBar() {
        var s = MenuBarSettings()
        #expect(!s.wantsAccessibility)
        s.showOnHover = true
        s.showOnEmptyClick = true
        #expect(!s.wantsAccessibility)
        s.barMode = .whenCrowded
        #expect(s.wantsAccessibility)
        s.barMode = .inMenuBar
        s.searchEnabled = true
        #expect(s.wantsAccessibility)
    }

    @Test func defaultsAreConservative() {
        let s = MenuBarSettings()
        #expect(s.toggleShortcut == nil && s.searchShortcut == nil && s.alwaysHiddenShortcut == nil)
        #expect(s.barMode == .inMenuBar && !s.searchEnabled && !s.appearance.enabled)
        #expect(!s.onboardingCompleted)
    }

    @Test func settingsRoundTripWithClearedShortcut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        var s = MenuBarSettings()
        s.toggleShortcut = Shortcut(11, [.control, .option, .command])
        s.chevronStyle = .ellipsis
        s.appearance.enabled = true
        s.appearance.shape = .split
        store.save(s, id: "menubar", defaults: MenuBarSettings())
        #expect(store.load("menubar", default: MenuBarSettings()) == s)
        s.toggleShortcut = nil
        store.save(s, id: "menubar", defaults: MenuBarSettings())
        #expect(store.load("menubar", default: MenuBarSettings()).toggleShortcut == nil)
    }

    @Test func chevronSymbolsDifferByState() {
        for style in ChevronStyle.allCases {
            #expect(style.symbol(collapsed: true) != style.symbol(collapsed: false))
        }
        #expect(HiddenBarMode.inMenuBar.usesBar == false)
        #expect(HiddenBarMode.separateBar.usesBar && HiddenBarMode.whenCrowded.usesBar)
    }

    @Test func appleItemsGetSymbols() {
        #expect(SystemItemSymbols.symbol(for: "com.apple.menuextra.wifi") == "wifi")
        #expect(SystemItemSymbols.symbol(for: "com.apple.menuextra.battery") == "battery.75percent")
        #expect(SystemItemSymbols.symbol(for: "com.example.wifi") == nil)
        #expect(SystemItemSymbols.symbol(for: nil) == nil)
    }
}
