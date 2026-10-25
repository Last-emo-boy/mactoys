import Foundation

/// A key Quick Accent listens to, identified by the character it types (layout independent).
public enum AccentKey: String, CaseIterable, Codable, Sendable {
    case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit0, digit1, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9
    /// `,` `.` `-` `/` `=` `\`, and the keypad's `*` and `/`.
    case comma, period, minus, slash, plus, backslash, multiply, divide

    /// The unshifted character that selects this key.
    public init?(character: String) {
        switch character {
        case ",": self = .comma
        case ".": self = .period
        case "-": self = .minus
        case "/": self = .slash
        case "=": self = .plus
        case "\\": self = .backslash
        default:
            guard character.count == 1, let c = character.lowercased().first, c.isASCII else { return nil }
            if c.isLetter, let key = AccentKey(rawValue: String(c)) { self = key; return }
            if c.isNumber, let key = AccentKey(rawValue: "digit\(c)") { self = key; return }
            return nil
        }
    }

    public var isLetter: Bool { rawValue.count == 1 }

    /// Keycap label for the reference browser.
    public var label: String {
        switch self {
        case .comma: ","
        case .period: "."
        case .minus: "-"
        case .slash: "/"
        case .plus: "="
        case .backslash: "\\"
        case .multiply: String(localized: "Num *", comment: "Keycap label: the numeric keypad's * key")
        case .divide: String(localized: "Num /", comment: "Keycap label: the numeric keypad's / key")
        default: isLetter ? rawValue.uppercased() : String(rawValue.dropFirst(5))
        }
    }
}

/// One language or symbol set: the characters offered for each key.
public struct AccentSet: Identifiable, Sendable {
    public enum Group: String, Sendable { case language, special }

    public let id: String
    /// Display name in the UI language.
    public let name: String
    public let group: Group
    public let characters: [AccentKey: [String]]

    /// A language's set, named by the system in the UI language; `language` is a BCP 47 code such as `be-Latn`.
    init(id: String, language: String, characters: [AccentKey: [String]]) {
        let locale = Locale.current
        let name = locale.localizedString(forIdentifier: language)
            ?? Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        self.init(id: id, displayName: name.prefix(1).uppercased(with: locale) + name.dropFirst(), group: .language,
                  characters: characters)
    }

    /// A set whose name isn't a language the system can name (Pinyin, Currency, IPA…).
    init(id: String, name: LocalizedStringResource, group: Group, characters: [AccentKey: [String]]) {
        self.init(id: id, displayName: String(localized: name), group: group, characters: characters)
    }

    private init(id: String, displayName: String, group: Group, characters: [AccentKey: [String]]) {
        self.id = id
        self.name = displayName
        self.group = group
        self.characters = characters
    }

    public static func named(_ id: String) -> AccentSet? { all.first { $0.id == id } }
}

public enum AccentLogic {
    /// Characters for `key` across `sets` in display order (languages before special sets), without duplicates.
    public static func characters(for key: AccentKey, in sets: [AccentSet]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let ordered = sets.filter { $0.group == .language } + sets.filter { $0.group == .special }
        for set in ordered {
            for c in set.characters[key] ?? [] where seen.insert(c).inserted { out.append(c) }
        }
        return out
    }

    /// Upper-case variants for a shifted or Caps Lock letter. Characters without a single
    /// upper-case form (symbols, `ŉ`) stay as they are; `ß` becomes `ẞ`.
    public static func uppercased(_ chars: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in chars {
            var u = c.uppercased()
            if u.count != c.count { u = c == "ß" ? "ẞ" : c }
            if seen.insert(u).inserted { out.append(u) }
        }
        return out
    }

    /// Most used first; ties keep their set order.
    public static func sortedByUsage(_ chars: [String], counts: [String: Int]) -> [String] {
        chars.enumerated()
            .sorted { a, b in
                let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The next selection, wrapping around.
    public static func step(_ index: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return ((index + (forward ? 1 : -1)) % count + count) % count
    }

    /// The window of `capacity` cells shown around the selection.
    public static func visibleRange(count: Int, selected: Int?, capacity: Int) -> Range<Int> {
        guard count > capacity, capacity > 0 else { return 0..<count }
        let sel = selected ?? 0
        let start = min(max(0, sel - capacity / 2), count - capacity)
        return start..<(start + capacity)
    }

    /// `("U+00E9", "Latin small letter e with acute")`.
    public static func unicodeInfo(_ s: String) -> (code: String, name: String) {
        let scalars = Array(s.unicodeScalars)
        let code = scalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
        let names = scalars.map { scalar -> String in
            guard let name = scalar.properties.name ?? scalar.properties.nameAlias else { return "" }
            let lower = name.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return (code, names.filter { !$0.isEmpty }.joined(separator: " + "))
    }

    /// Lone combining marks are shown on a dotted circle so they're visible.
    public static func display(_ s: String) -> String {
        guard let first = s.unicodeScalars.first, first.properties.generalCategory == .nonspacingMark
                || first.properties.generalCategory == .enclosingMark else { return s }
        return "◌" + s
    }
}

/// The press–cycle–release state machine, free of events and UI so it can be tested.
///
/// Trigger modes: hold a base key and press Space/←/→ (the activation key); if both stay down for the
/// input delay the toolbar opens. Press again to cycle (⇧Space and ← go back), release the base key to
/// type the selection. Releasing before the delay is a false start: the swallowed activation keys are
/// typed again, as in fast typing ("e" + Space). Hold mode opens the toolbar after holding the key alone.
public struct AccentEngine: Sendable {
    public enum Activation: String, Codable, CaseIterable, Sendable {
        case both, space, arrows, hold

        public var title: String {
            switch self {
            case .both: String(localized: "Left, Right or Space", comment: "Quick Accent activation: the arrow keys or the space bar")
            case .space: String(localized: "Space", comment: "Quick Accent activation: the space bar")
            case .arrows: String(localized: "Left/Right Arrow", comment: "Quick Accent activation: the left or right arrow key")
            case .hold: String(localized: "Press and hold the letter", comment: "Quick Accent activation: no extra key")
            }
        }
    }

    public enum Trigger: Equatable, Sendable { case space, left, right }

    public struct Config: Equatable, Sendable {
        public var activation: Activation = .both
        public var inputDelay: TimeInterval = 0.3
        public var holdDuration: TimeInterval = 0.5
        public var startFromLeft = false
        public init() {}
    }

    public enum Output: Equatable, Sendable {
        /// Show the toolbar with the current selection.
        case show
        case select(Int?)
        case hide
        /// Replace the typed base character with candidate `index`.
        case commit(Int)
        /// Type these activation keys that were held back.
        case retype([Trigger])
        /// Call `timerFired` after this many seconds.
        case schedule(TimeInterval)
    }

    public enum Decision: Equatable, Sendable {
        case pass, consume
        /// Hold this event back, `retype` first, then post it again (keeps typing order).
        case replay
    }

    public var config: Config
    public private(set) var key: AccentKey?
    public private(set) var count = 0
    public private(set) var selection: Int?
    public private(set) var isVisible = false
    /// An activation key was accepted (trigger modes) or the hold elapsed: the toolbar is open or about to be.
    public private(set) var isActive = false
    private var downAt: TimeInterval = 0
    private var triggerAt: TimeInterval = 0
    private var shiftAtDown = false
    private var swallowed: [Trigger] = []

    public init(config: Config = Config()) {
        self.config = config
    }

    public var isArmed: Bool { key != nil }

    /// Whether auto-repeat of the held key should be swallowed: once an activation key was pressed
    /// (repeats would type under the toolbar), and in hold mode, where holding is the trigger.
    /// Otherwise repeats pass, so holding a key to repeat it keeps working.
    public func swallowsRepeat(of key: AccentKey) -> Bool {
        key == self.key && (isActive || config.activation == .hold)
    }

    /// A base key went down (not a repeat). `candidates` is how many characters it offers.
    public mutating func keyDown(_ key: AccentKey, candidates: Int, shift: Bool, at time: TimeInterval) -> (Decision, [Output]) {
        var outputs: [Output] = []
        if isVisible { outputs.append(.hide) }
        reset()
        guard candidates > 0 else { return (.pass, outputs) }
        self.key = key
        count = candidates
        downAt = time
        shiftAtDown = shift
        if config.activation == .hold { outputs.append(.schedule(config.holdDuration)) }
        return (.pass, outputs)
    }

    /// Space, ← or → went down (including auto-repeat) while a base key may be held.
    public mutating func trigger(_ t: Trigger, shift: Bool, at time: TimeInterval) -> (Decision, [Output]) {
        guard key != nil else { return (.pass, []) }
        let accepts: Bool = switch config.activation {
        case .both: true
        case .space: t == .space
        case .arrows: t != .space
        case .hold: isVisible
        }
        guard accepts else {
            // An ordinary key while the base key is held: typing continues.
            if isVisible { reset(); return (.pass, [.hide]) }
            return otherKey()
        }
        let backward = t == .left || (t == .space && shift && !shiftAtDown)
        if let current = selection {
            selection = AccentLogic.step(current, count: count, forward: !backward)
        } else {
            selection = backward && !config.startFromLeft ? count - 1 : 0
        }
        if isVisible { return (.consume, [.select(selection)]) }
        swallowed.append(t)
        guard !isActive else { return (.consume, []) }
        isActive = true
        triggerAt = time
        return (.consume, [.schedule(config.inputDelay)])
    }

    /// A scheduled timer fired.
    public mutating func timerFired(at time: TimeInterval) -> [Output] {
        guard key != nil, !isVisible else { return [] }
        if config.activation == .hold {
            guard !isActive, time - downAt >= config.holdDuration - 0.01 else { return [] }
            isActive = true
            isVisible = true
            selection = nil
            return [.show]
        }
        guard isActive, time - triggerAt >= config.inputDelay - 0.01 else { return [] }
        isVisible = true
        return [.show]
    }

    /// The base key went up.
    public mutating func keyUp(_ key: AccentKey, at time: TimeInterval) -> (Decision, [Output]) {
        guard key == self.key else { return (.pass, []) }
        defer { reset() }
        guard isActive else { return (.pass, []) }
        if !isVisible {
            // Released before the toolbar appeared: a false start in fast typing.
            return (.pass, swallowed.isEmpty ? [] : [.retype(swallowed)])
        }
        if let selection { return (.pass, [.hide, .commit(selection)]) }
        return (.pass, [.hide])
    }

    /// Any other key went down while armed.
    public mutating func otherKey() -> (Decision, [Output]) {
        guard key != nil else { return (.pass, []) }
        let wasVisible = isVisible
        let pending = swallowed
        reset()
        if wasVisible { return (.pass, [.hide]) }
        if !pending.isEmpty { return (.replay, [.retype(pending)]) }
        return (.pass, [])
    }

    /// Esc, a click, or a ⌘/⌃/⌥ press: close without typing anything.
    public mutating func cancel() -> (Decision, [Output]) {
        guard key != nil else { return (.pass, []) }
        let wasVisible = isVisible
        reset()
        return (wasVisible ? .consume : .pass, wasVisible ? [.hide] : [])
    }

    private mutating func reset() {
        key = nil
        count = 0
        selection = nil
        isVisible = false
        isActive = false
        swallowed = []
        shiftAtDown = false
    }
}
