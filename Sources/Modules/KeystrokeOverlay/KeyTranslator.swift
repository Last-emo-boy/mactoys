import Carbon.HIToolbox
import Foundation
import MacToysCore

/// One key press as the event tap saw it. Never stored beyond drawing it.
public struct KeyPress: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Modifiers
    public var capsLock: Bool
    public var isRepeat: Bool

    public init(_ keyCode: Int, _ modifiers: Modifiers = [], capsLock: Bool = false, isRepeat: Bool = false) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = modifiers
        self.capsLock = capsLock
        self.isRepeat = isRepeat
    }

    /// Modifiers as the user pressed them: the fn flag macOS sets on arrows, function keys and the
    /// navigation block is dropped (it is part of those keys, not a modifier the user held).
    public var effectiveModifiers: Modifiers {
        KeyNames.impliesFunction(keyCode) ? modifiers.subtracting(.function) : modifiers
    }

    /// Pressed with ⌘, ⌃, ⌥ or (on a character key) fn/🌐.
    public var isShortcut: Bool {
        !effectiveModifiers.intersection([.command, .control, .option, .function]).isEmpty
    }
}

/// Legends of the keys that don't type a character.
public enum KeyNames {
    /// Stable tokens used to match menu key equivalents; the display legend is `legend(_:)`.
    public static func token(_ code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Space: "Space"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_Escape: "esc"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_Help: "Help"
        case kVK_ANSI_KeypadEnter: "⌤"
        case kVK_ANSI_KeypadClear: "⌧"
        case kVK_CapsLock: "⇪"
        case kVK_JIS_Eisu: "英数"
        case kVK_JIS_Kana: "かな"
        default: functionKeys[Int(code)].map { "F\($0)" }
        }
    }

    /// What the keycap shows.
    public static func legend(_ code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Space: String(localized: "Space", comment: "Key name: space bar")
        case kVK_Help: String(localized: "Help", comment: "Key name: Help key")
        default: token(code)
        }
    }

    /// Keys whose events always carry the fn flag.
    public static func impliesFunction(_ code: UInt16) -> Bool {
        functionKeys[Int(code)] != nil || navigation.contains(Int(code))
    }

    /// esc, return, tab, delete, arrows, the navigation block and function keys.
    public static func isSpecial(_ code: UInt16) -> Bool {
        Int(code) != kVK_Space && token(code) != nil
    }

    public static func isModifier(_ code: UInt16) -> Bool { KeyCodes.isModifier(code) }

    private static let navigation: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
                                               kVK_PageUp, kVK_PageDown, kVK_ForwardDelete, kVK_Help]

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18,
        kVK_F19: 19, kVK_F20: 20,
    ]

    /// Upper-cases a legend unless that changes its length ("ß" stays "ß", not "SS").
    public static func capital(_ s: String) -> String {
        let upper = s.uppercased()
        return upper.count == s.count ? upper : s
    }
}

/// Translates key codes with a Unicode keyboard layout ('uchr' data), keeping dead-key state the way
/// the text system does: ⌥E then E types "é" on a U.S. layout, ^ then A types "â" on a German one.
public struct KeyTranslator {
    public let layout: Data
    public let keyboardType: UInt32
    public private(set) var deadKeyState: UInt32 = 0

    public init(layout: Data, keyboardType: UInt32 = UInt32(LMGetKbdType())) {
        self.layout = layout
        self.keyboardType = keyboardType
    }

    /// Whether a dead key is waiting for the next key.
    public var isComposing: Bool { deadKeyState != 0 }

    public mutating func reset() { deadKeyState = 0 }

    /// The text a key press types: "" while it starts a dead-key sequence; the accent followed by the
    /// character when the next key can't take it. ⌘ and ⌃ are ignored (they don't change the text).
    public mutating func type(_ keyCode: UInt16, modifiers: Modifiers, capsLock: Bool = false) -> String {
        var state = deadKeyState
        let text = translate(keyCode, modifiers: modifiers.intersection([.shift, .option]), capsLock: capsLock,
                             action: UInt16(kUCKeyActionDown), options: 0, state: &state)
        deadKeyState = state
        return text
    }

    /// The key's legend: its character without modifiers and without dead-key composition,
    /// e.g. "z" for the key right of T on a German layout. Nil for keys that type nothing printable.
    public func label(_ keyCode: UInt16, shift: Bool = false) -> String? {
        var state: UInt32 = 0
        let s = translate(keyCode, modifiers: shift ? .shift : [], capsLock: false, action: UInt16(kUCKeyActionDisplay),
                          options: OptionBits(kUCKeyTranslateNoDeadKeysMask), state: &state)
        guard !s.isEmpty, s.unicodeScalars.allSatisfy({ Self.isPrintable($0) }) else { return nil }
        return s
    }

    private func translate(_ keyCode: UInt16, modifiers: Modifiers, capsLock: Bool, action: UInt16, options: OptionBits,
                           state: inout UInt32) -> String {
        var carbon = 0
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if capsLock { carbon |= alphaLock }
        let modifierState = UInt32((carbon >> 8) & 0xFF)
        return layout.withUnsafeBytes { raw -> String in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "" }
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(base, keyCode, action, modifierState, keyboardType, options, &state,
                                        chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "" }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v < 0x20 || v == 0x7F || (0xF700...0xF8FF).contains(v) { return false }
        return true
    }
}

/// Keyboard layout data from Text Input Sources. TIS must be used from one thread: the main thread.
@MainActor
public enum KeyboardLayouts {
    /// The layout of the current input source (what typing produces).
    public static func current() -> Data? {
        data(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    /// The ASCII-capable layout macOS matches shortcuts against, even while a Russian or Japanese
    /// input source is active.
    public static func asciiCapable() -> Data? {
        data(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    /// An installed layout by input source ID, e.g. `com.apple.keylayout.German`.
    public static func named(_ id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.lazy.compactMap { data($0) }.first
    }

    private static func data(_ source: TISInputSource?) -> Data? {
        guard let source, let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }
}
