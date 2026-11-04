import Carbon.HIToolbox
import Foundation
import MacToysCore

/// What a key press becomes on the overlay.
public enum KeystrokeOutput: Equatable, Sendable {
    /// Keycaps, e.g. `["⇧", "⌘", "T"]`.
    case keys([String])
    /// Typed characters ("" while a dead key waits for the next key).
    case text(String)
    /// Delete the last typed character.
    case backspace
    case ignore
}

/// Turns key presses into keycaps or text for a mode, using the layouts for legends and typing.
public struct KeystrokeInterpreter {
    public var mode: KeystrokeSettings.Mode
    public var specialKeys: Bool
    public var maskText: Bool
    /// The current input source's layout: typed text and the legends of plain keys.
    public var typing: KeyTranslator?
    /// The ASCII-capable layout: legends of shortcuts, as macOS matches them.
    public var shortcuts: KeyTranslator?

    public init(mode: KeystrokeSettings.Mode, specialKeys: Bool = false, maskText: Bool = false,
                typing: KeyTranslator?, shortcuts: KeyTranslator?) {
        self.mode = mode
        self.specialKeys = specialKeys
        self.maskText = maskText
        self.typing = typing
        self.shortcuts = shortcuts
    }

    public static let maskCharacter = "•"

    public mutating func interpret(_ press: KeyPress) -> KeystrokeOutput {
        guard !KeyNames.isModifier(press.keyCode) else { return .ignore }
        let special = KeyNames.isSpecial(press.keyCode)
        switch mode {
        case .shortcuts:
            guard press.isShortcut || (specialKeys && special) else { return .ignore }
            return keycaps(press)
        case .allKeys:
            return keycaps(press)
        case .text:
            let mods = press.effectiveModifiers
            let commandLike = !mods.intersection([.command, .control, .function]).isEmpty
            if commandLike || special {
                // ⌥⌫ deletes a word: show it as keys rather than guessing what it removed.
                if !commandLike, Int(press.keyCode) == kVK_Delete, !mods.contains(.option) {
                    typing?.reset()
                    return .backspace
                }
                typing?.reset()
                return keycaps(press)
            }
            guard var t = typing else { return keycaps(press) }
            let typed = t.type(press.keyCode, modifiers: mods, capsLock: press.capsLock)
            typing = t
            let printable = String(String.UnicodeScalarView(typed.unicodeScalars.filter(KeyTranslator.isPrintable)))
            if printable.isEmpty { return t.isComposing ? .text("") : .ignore }
            return .text(maskText ? Self.mask(printable) : printable)
        }
    }

    /// Keycaps for a press: modifiers in Apple's order, then the key's legend.
    public func keycaps(_ press: KeyPress) -> KeystrokeOutput {
        guard let key = legend(press) else { return .ignore }
        return .keys(press.effectiveModifiers.symbols + [key])
    }

    /// The legend of the pressed key: special keys by name, shortcuts from the ASCII-capable layout,
    /// other keys from the current layout; letters capitalized like the printed keys.
    public func legend(_ press: KeyPress) -> String? {
        if let name = KeyNames.legend(press.keyCode) { return name }
        let layout = press.isShortcut ? (shortcuts ?? typing) : (typing ?? shortcuts)
        guard let label = layout?.label(press.keyCode) ?? KeyNames.usFallback(press.keyCode) else { return nil }
        if maskText, !press.isShortcut, label.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            return Self.maskCharacter
        }
        return KeyNames.capital(label)
    }

    /// Letters, digits and symbols become dots; spaces stay so word shapes don't matter.
    public static func mask(_ text: String) -> String {
        String(text.map { $0.isWhitespace ? $0 : Character(maskCharacter) })
    }
}

extension KeyNames {
    /// U.S. legends for when no keyboard layout is available.
    static func usFallback(_ code: UInt16) -> String? {
        let table: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
            14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
            26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
            39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
        ]
        return table[code]
    }
}

/// The recent presses shown in the pill.
public struct KeystrokeFeed: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// Keycaps, with the menu item the shortcut triggers when known.
        case keys([String], name: String?)
        case text(String)
        case click(Click)
        /// Typing in a password field or under secure keyboard entry.
        case hidden
    }

    public struct Click: Equatable, Sendable {
        public enum Button: Equatable, Sendable { case left, right, middle, other }
        public var button: Button
        /// 1 single, 2 double, 3 triple.
        public var count: Int
        public var modifiers: [String]

        public init(_ button: Button, count: Int = 1, modifiers: [String] = []) {
            self.button = button
            self.count = count
            self.modifiers = modifiers
        }
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: Int
        public var content: Content
        /// Repetitions of the same press, shown as ×N.
        public var count: Int
    }

    public private(set) var items: [Item] = []
    public var maxItems: Int
    public var maxText: Int
    private var nextID = 1

    public init(maxItems: Int = 4, maxText: Int = 40) {
        self.maxItems = maxItems
        self.maxText = maxText
    }

    /// A shortcut or key; the same keys again collapse into ×N.
    public mutating func add(keys: [String], name: String? = nil) {
        if let last = items.indices.last, case .keys(let previous, let oldName) = items[last].content, previous == keys {
            items[last].count += 1
            items[last].content = .keys(keys, name: name ?? oldName)
            return
        }
        append(.keys(keys, name: name))
    }

    /// Typed characters join the running text.
    public mutating func type(_ text: String) {
        guard !text.isEmpty else { return }
        if let last = items.indices.last, case .text(let current) = items[last].content {
            items[last].content = .text(clip(current + text))
        } else {
            append(.text(clip(text)))
        }
    }

    /// ⌫ removes the last typed character; with no text to edit it shows as a key.
    public mutating func backspace() {
        if let last = items.indices.last, case .text(var current) = items[last].content {
            current.removeLast()
            if current.isEmpty || current == Self.ellipsis {
                items.removeLast()
            } else {
                items[last].content = .text(current)
            }
            return
        }
        add(keys: ["⌫"])
    }

    /// A click; the second press of a double click upgrades the first, repeated single clicks count up.
    public mutating func click(_ click: Click) {
        if let last = items.indices.last, case .click(let previous) = items[last].content,
           previous.button == click.button, previous.modifiers == click.modifiers {
            if click.count > 1, previous.count == click.count - 1 {
                items[last].content = .click(click)
                return
            }
            if click.count == 1, previous.count == 1 {
                items[last].count += 1
                return
            }
        }
        append(.click(click))
    }

    /// Notes once that typing is hidden.
    public mutating func hidden() {
        if case .hidden = items.last?.content { return }
        append(.hidden)
    }

    /// Names a shortcut once its menu item is known (the menus are read in the background).
    public mutating func setName(_ name: String, forKeys keys: [String]) {
        for i in items.indices.reversed() {
            if case .keys(let k, let existing) = items[i].content, k == keys {
                if existing == nil { items[i].content = .keys(k, name: name) }
                return
            }
        }
    }

    public mutating func clear() {
        items.removeAll()
    }

    public var isEmpty: Bool { items.isEmpty }

    static let ellipsis = "…"

    private func clip(_ text: String) -> String {
        guard text.count > maxText else { return text }
        let body = text.hasPrefix(Self.ellipsis) ? String(text.dropFirst()) : text
        return Self.ellipsis + String(body.suffix(maxText - 1))
    }

    private mutating func append(_ content: Content) {
        items.append(Item(id: nextID, content: content, count: 1))
        nextID += 1
        if items.count > maxItems { items.removeFirst(items.count - maxItems) }
    }
}

/// Decides what may be shown, before anything about a press is looked at.
public enum KeystrokePrivacy {
    public enum Verdict: Equatable, Sendable {
        case show
        /// Show only that typing is hidden.
        case hideTyping
        /// Show nothing at all.
        case ignore
    }

    /// - Parameters:
    ///   - isKey: a key press (clicks are not secret).
    ///   - secureInput: secure event input is on (a password field, or secure keyboard entry in a terminal).
    ///   - secureField: the focused element is a password field.
    ///   - excludedApp: the active app is on the never-show list.
    public static func verdict(isKey: Bool, secureInput: Bool, secureField: Bool, excludedApp: Bool) -> Verdict {
        if excludedApp { return .ignore }
        if isKey, secureInput || secureField { return .hideTyping }
        return .show
    }
}

/// Spots modifier keys pressed and released on their own (⌘ alone, ⌃⌥ together).
public struct ModifierTapTracker: Sendable {
    private var peak: Modifiers = []
    private var interrupted = false

    public init() {}

    /// Feed every modifier change; returns the modifiers when the last one is released with no key
    /// or click in between.
    public mutating func flagsChanged(_ modifiers: Modifiers) -> Modifiers? {
        if modifiers.isEmpty {
            defer {
                peak = []
                interrupted = false
            }
            return peak.isEmpty || interrupted ? nil : peak
        }
        peak.formUnion(modifiers)
        return nil
    }

    /// A key or click happened: the held modifiers were part of a shortcut.
    public mutating func interrupt() {
        if !peak.isEmpty { interrupted = true }
    }
}
