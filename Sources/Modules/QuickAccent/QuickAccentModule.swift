import AppKit
import Carbon.HIToolbox
import MacToysCore
import Observation
import SwiftUI

public struct QuickAccentSettings: Codable, Equatable, Sendable {
    public enum Position: String, Codable, CaseIterable, Sendable {
        case caret, topCenter, bottomCenter, left, right, topLeft, topRight, bottomLeft, bottomRight, center

        public var title: String {
            switch self {
            case .caret: String(localized: "Near the text cursor")
            case .topCenter: String(localized: "Top center", comment: "Toolbar position on the screen")
            case .bottomCenter: String(localized: "Bottom center", comment: "Toolbar position on the screen")
            case .left: String(localized: "Left", comment: "Toolbar position: middle of the screen's left edge")
            case .right: String(localized: "Right", comment: "Toolbar position: middle of the screen's right edge")
            case .topLeft: String(localized: "Top left corner", comment: "Toolbar position on the screen")
            case .topRight: String(localized: "Top right corner", comment: "Toolbar position on the screen")
            case .bottomLeft: String(localized: "Bottom left corner", comment: "Toolbar position on the screen")
            case .bottomRight: String(localized: "Bottom right corner", comment: "Toolbar position on the screen")
            case .center: String(localized: "Center", comment: "Toolbar position: center of the screen")
            }
        }
    }

    public var activation = AccentEngine.Activation.both
    /// Milliseconds the base key must be held before an activation key opens the toolbar.
    public var inputDelay: Double = 300
    /// Milliseconds of holding the base key alone in "Press and hold the letter" mode.
    public var holdDuration: Double = 500
    public var position = Position.caret
    public var showUnicode = true
    public var sortByUsage = false
    public var startFromLeft = false
    /// Offer every set; otherwise only `sets`.
    public var allSets = true
    public var sets: [String] = []
    public var excludedApps: [String] = []

    public init() {}

    public var selectedSets: [AccentSet] {
        allSets ? AccentSet.all : AccentSet.all.filter { sets.contains($0.id) }
    }

    var engineConfig: AccentEngine.Config {
        var c = AccentEngine.Config()
        c.activation = activation
        c.inputDelay = max(100, inputDelay) / 1000
        c.holdDuration = min(3000, max(100, holdDuration)) / 1000
        c.startFromLeft = startFromLeft
        return c
    }
}

/// Quick Accent: hold a letter (or `,` `.` `-` `/` `=` a digit…) and tap Space or ←/→ to pick an
/// accented character from a toolbar near the caret; releasing the letter types it.
///
/// URL actions: `settings` (or `open`), `reference` (opens the character reference).
@MainActor
public final class QuickAccentModule: ToyModule {
    public let info = ModuleInfo(
        id: "quickaccent", name: "Quick Accent",
        summary: "Hold a letter and tap Space or an arrow key to type accented characters.",
        symbol: "character", tint: .pink, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["accent", "diacritic", "unicode", "character", "currency", "ipa", "pinyin", "language"])

    public let settings = Persisted("quickaccent", default: QuickAccentSettings())
    let usage = UsageStore()
    private let toolbar = AccentToolbarPresenter()
    private let log = Log.for("quickaccent")
    private var engine = AccentEngine()
    private var running = false
    var showReferenceOnAppear = false

    // Hot-path caches, rebuilt off the hot path.
    private var keyTable = [AccentKey?](repeating: nil, count: 128)
    private var lower: [AccentKey: [String]] = [:]
    private var upper: [AccentKey: [String]] = [:]
    private var current: [String] = []
    private var frontmostExcluded = false
    private var inputMethodActive = false
    /// Activation keys whose key-down was swallowed, so their key-up is too (space, ←, →).
    private var swallowedUps: [Bool] = [false, false, false]
    private var timer: DispatchSourceTimer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {
        settings.onChange { [weak self] _ in
            guard let self, self.running else { return }
            self.rebuild()
        }
    }

    public func start() {
        guard !running else { return }
        running = true
        rebuild()
        rebuildKeyTable()
        updateFrontmost(NSWorkspace.shared.frontmostApplication)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.timerFired() } }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        self.timer = timer

        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.updateFrontmost(app) }
        }))
        let dc = DistributedNotificationCenter.default()
        observers.append((dc, dc.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildKeyTable() }
        }))

        InputTap.shared.add(info.id, priority: 50,
                            events: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        InputTap.shared.remove(info.id)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        timer?.cancel()
        timer = nil
        _ = engine.cancel()
        swallowedUps = [false, false, false]
        toolbar.dispose()
        usage.flush()
    }

    // MARK: Caches

    private func rebuild() {
        let s = settings.value
        engine.config = s.engineConfig
        let sets = s.selectedSets
        var lo: [AccentKey: [String]] = [:]
        var up: [AccentKey: [String]] = [:]
        for key in AccentKey.allCases {
            var chars = AccentLogic.characters(for: key, in: sets)
            guard !chars.isEmpty else { continue }
            if s.sortByUsage { chars = AccentLogic.sortedByUsage(chars, counts: usage.counts) }
            lo[key] = chars
            up[key] = key.isLetter ? AccentLogic.uppercased(chars) : chars
        }
        lower = lo
        upper = up
        updateFrontmost(NSWorkspace.shared.frontmostApplication)
    }

    private func rebuildKeyTable() {
        var table = [AccentKey?](repeating: nil, count: 128)
        for code in UInt16(0)..<128 where !KeyCodes.isModifier(code) && KeyCodes.special[code] == nil {
            guard let ch = KeyCodes.character(for: code, shift: false) else { continue }
            if let key = AccentKey(character: ch) {
                table[Int(code)] = key
            } else if ch.unicodeScalars.contains(where: { !$0.isASCII }), ch.first?.isLetter == true {
                // Cyrillic, Greek…: use the key's Latin position, as PowerToys does with virtual keys.
                table[Int(code)] = Self.ansiPositions[Int(code)]
            }
        }
        table[kVK_ANSI_KeypadMultiply] = .multiply
        table[kVK_ANSI_KeypadDivide] = .divide
        keyTable = table
        inputMethodActive = Self.isInputMethodActive()
    }

    /// Letter keys of the US ANSI layout by virtual key code.
    private static let ansiPositions: [Int: AccentKey] = [
        kVK_ANSI_A: .a, kVK_ANSI_B: .b, kVK_ANSI_C: .c, kVK_ANSI_D: .d, kVK_ANSI_E: .e, kVK_ANSI_F: .f, kVK_ANSI_G: .g,
        kVK_ANSI_H: .h, kVK_ANSI_I: .i, kVK_ANSI_J: .j, kVK_ANSI_K: .k, kVK_ANSI_L: .l, kVK_ANSI_M: .m, kVK_ANSI_N: .n,
        kVK_ANSI_O: .o, kVK_ANSI_P: .p, kVK_ANSI_Q: .q, kVK_ANSI_R: .r, kVK_ANSI_S: .s, kVK_ANSI_T: .t, kVK_ANSI_U: .u,
        kVK_ANSI_V: .v, kVK_ANSI_W: .w, kVK_ANSI_X: .x, kVK_ANSI_Y: .y, kVK_ANSI_Z: .z,
    ]

    /// Input methods (Japanese, Chinese…) compose text themselves; Quick Accent stays out of their way.
    private static func isInputMethodActive() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return false }
        let type = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
        return CFEqual(type, kTISTypeKeyboardInputMode)
    }

    private func updateFrontmost(_ app: NSRunningApplication?) {
        frontmostExcluded = settings.value.excludedApps.matches(app: app)
    }

    // MARK: Events (hot path: O(1), no allocation for ordinary typing)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .keyDown: return keyDown(event)
        case .keyUp: return keyUp(event)
        case .flagsChanged:
            if engine.isArmed, !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                return apply(engine.cancel(), event)
            }
            return .pass
        default:
            if engine.isArmed { _ = apply(engine.cancel(), event) }
            return .pass
        }
    }

    private func trigger(for code: Int64) -> AccentEngine.Trigger? {
        switch Int(code) {
        case kVK_Space: .space
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        default: nil
        }
    }

    private func triggerSlot(_ t: AccentEngine.Trigger) -> Int {
        switch t {
        case .space: 0
        case .left: 1
        case .right: 2
        }
    }

    private func keyDown(_ event: CGEvent) -> TapDecision {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let now = ProcessInfo.processInfo.systemUptime
        if let t = trigger(for: code) {
            guard engine.isArmed else { return .pass }
            let result = engine.trigger(t, shift: flags.contains(.maskShift), at: now)
            if result.0 == .consume { swallowedUps[triggerSlot(t)] = true }
            return apply(result, event)
        }
        if code == Int64(kVK_Escape), engine.isVisible { return apply(engine.cancel(), event) }
        guard code >= 0, code < 128, let key = keyTable[Int(code)] else {
            return engine.isArmed ? apply(engine.otherKey(), event) : .pass
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            if engine.swallowsRepeat(of: key) { return .consume }
            return engine.isArmed && key != engine.key ? apply(engine.otherKey(), event) : .pass
        }
        let modified = !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        if modified || frontmostExcluded || inputMethodActive {
            return engine.isArmed ? apply(engine.otherKey(), event) : .pass
        }
        let upperCase = flags.contains(.maskShift) || flags.contains(.maskAlphaShift)
        let chars = (upperCase ? upper[key] : lower[key]) ?? []
        current = chars
        return apply(engine.keyDown(key, candidates: chars.count, shift: flags.contains(.maskShift), at: now), event)
    }

    private func keyUp(_ event: CGEvent) -> TapDecision {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if let t = trigger(for: code), swallowedUps[triggerSlot(t)] {
            swallowedUps[triggerSlot(t)] = false
            return .consume
        }
        guard engine.isArmed, code >= 0, code < 128, let key = keyTable[Int(code)] else { return .pass }
        return apply(engine.keyUp(key, at: ProcessInfo.processInfo.systemUptime), event)
    }

    private func timerFired() {
        for output in engine.timerFired(at: ProcessInfo.processInfo.systemUptime) { perform(output) }
    }

    @discardableResult
    private func apply(_ result: (AccentEngine.Decision, [AccentEngine.Output]), _ event: CGEvent?) -> TapDecision {
        let (decision, outputs) = result
        for output in outputs { perform(output) }
        switch decision {
        case .pass: return .pass
        case .consume: return .consume
        case .replay:
            if let copy = event?.copy() { KeySynth.post(copy) }
            return .consume
        }
    }

    private func perform(_ output: AccentEngine.Output) {
        switch output {
        case .schedule(let delay):
            timer?.schedule(deadline: .now() + delay)
        case .show:
            let chars = current
            let selection = engine.selection
            let s = settings.value
            // Accessibility lookups for the caret happen outside the event tap callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.engine.isVisible else { return }
                self.toolbar.show(chars, selection: self.engine.selection ?? selection, position: s.position, showInfo: s.showUnicode)
            }
        case .select(let index):
            toolbar.select(index)
        case .hide:
            timer?.schedule(deadline: .distantFuture)
            toolbar.hide()
        case .commit(let index):
            guard current.indices.contains(index) else { return }
            let char = current[index]
            DispatchQueue.main.async { [weak self] in
                KeySynth.backspace()
                KeySynth.type(char)
                self?.recordUse(char)
            }
        case .retype(let triggers):
            for t in triggers {
                switch t {
                case .space: KeySynth.tap(kVK_Space)
                case .left: KeySynth.tap(kVK_LeftArrow)
                case .right: KeySynth.tap(kVK_RightArrow)
                }
            }
        }
    }

    private func recordUse(_ char: String) {
        usage.increment(char)
        if settings.value.sortByUsage { rebuild() }
    }

    // MARK: ToyModule

    public func settingsView() -> AnyView {
        AnyView(QuickAccentSettingsView(module: self, settings: settings))
    }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "quickaccent.toggle", title: "Quick Accent", symbol: info.symbol, tint: info.tint,
                     isOn: { ModuleRegistry.shared.isEnabled("quickaccent") },
                     detail: { [weak self] in self?.settings.value.activation.title ?? "" },
                     perform: { ModuleRegistry.shared.setEnabled("quickaccent", !ModuleRegistry.shared.isEnabled("quickaccent")) })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        let hold = String(localized: "Hold letter", comment: "Shortcut list key label: keep a letter key pressed")
        return switch settings.value.activation {
        case .both:
            [ShortcutBinding("Accented characters",
                             keys: [hold, String(localized: "Space / ← →", comment: "Shortcut list key label: the space bar or an arrow key")])]
        case .space:
            [ShortcutBinding("Accented characters",
                             keys: [hold, String(localized: "Space", comment: "Quick Accent activation: the space bar")])]
        case .arrows: [ShortcutBinding("Accented characters", keys: [hold, "← →"])]
        case .hold: [ShortcutBinding("Accented characters", keys: [hold])]
        }
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "settings", "show":
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        case "reference":
            showReferenceOnAppear = true
            ModuleRegistry.shared.showSettings?(info.id)
            return true
        default:
            return false
        }
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("toolbar", size: CGSize(width: 760, height: 160)) {
            let model = AccentToolbarModel()
            model.characters = ["é", "è", "ê", "ë", "ē", "ė", "ę", "ě", "€"]
            model.selection = 0
            return AnyView(AccentToolbarView(model: model).frame(width: model.size.width, height: model.size.height))
        }]
    }
}

/// How often each character was typed, for "Sort characters by usage frequency".
@MainActor
@Observable
final class UsageStore {
    private(set) var counts: [String: Int]
    @ObservationIgnored private let file = Paths.data(for: "quickaccent").appendingPathComponent("usage.json")
    @ObservationIgnored private var pending: DispatchWorkItem?

    init() {
        counts = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
    }

    func increment(_ c: String) {
        counts[c, default: 0] += 1
        scheduleSave()
    }

    func reset() {
        counts = [:]
        scheduleSave()
    }

    func flush() {
        pending?.cancel()
        pending = nil
        save()
    }

    private func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func save() {
        do {
            try JSONEncoder().encode(counts).write(to: file, options: .atomic)
        } catch {
            Log.for("quickaccent").error("Could not save usage: \(error.localizedDescription, privacy: .public)")
        }
    }
}
