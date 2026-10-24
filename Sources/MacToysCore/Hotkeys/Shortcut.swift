import AppKit
import Carbon.HIToolbox

/// Modifier keys, independent of AppKit/CoreGraphics/Carbon flag layouts.
public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)

    public init(_ flags: NSEvent.ModifierFlags) {
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.function) { m.insert(.function) }
        self = m
    }

    public init(_ flags: CGEventFlags) {
        var m: Modifiers = []
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskSecondaryFn) { m.insert(.function) }
        self = m
    }

    public var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if contains(.control) { f.insert(.maskControl) }
        if contains(.option) { f.insert(.maskAlternate) }
        if contains(.shift) { f.insert(.maskShift) }
        if contains(.command) { f.insert(.maskCommand) }
        if contains(.function) { f.insert(.maskSecondaryFn) }
        return f
    }

    public var nsFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if contains(.control) { f.insert(.control) }
        if contains(.option) { f.insert(.option) }
        if contains(.shift) { f.insert(.shift) }
        if contains(.command) { f.insert(.command) }
        if contains(.function) { f.insert(.function) }
        return f
    }

    public var carbonFlags: UInt32 {
        var f: UInt32 = 0
        if contains(.control) { f |= UInt32(controlKey) }
        if contains(.option) { f |= UInt32(optionKey) }
        if contains(.shift) { f |= UInt32(shiftKey) }
        if contains(.command) { f |= UInt32(cmdKey) }
        return f
    }

    /// Apple's canonical order: ⌃ ⌥ ⇧ ⌘ (fn first when present).
    public var symbols: [String] {
        var s: [String] = []
        if contains(.function) { s.append("fn") }
        if contains(.control) { s.append("⌃") }
        if contains(.option) { s.append("⌥") }
        if contains(.shift) { s.append("⇧") }
        if contains(.command) { s.append("⌘") }
        return s
    }
}

/// A key plus modifiers, e.g. ⌃⌥C. Stored by virtual key code so it is layout independent.
public struct Shortcut: Codable, Hashable, Sendable, CustomStringConvertible {
    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(_ keyCode: Int, _ modifiers: Modifiers) {
        self.keyCode = UInt16(keyCode)
        self.modifiers = modifiers
    }

    public init?(event: NSEvent) {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        let mods = Modifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        self.init(Int(event.keyCode), KeyCodes.isFunctionKey(event.keyCode) ? mods : mods.subtracting(.function))
    }

    /// Keycaps for display, e.g. `["⌃", "⌥", "C"]`.
    public var keys: [String] { modifiers.symbols + [KeyCodes.name(for: keyCode)] }
    public var description: String { keys.joined() }

    /// True when the CG event is this key with exactly these modifiers.
    public func matches(keyCode code: Int64, flags: CGEventFlags) -> Bool {
        guard UInt16(code) == keyCode else { return false }
        var mods = Modifiers(flags)
        if !KeyCodes.isFunctionKey(keyCode) { mods.remove(.function) }
        return mods == modifiers
    }

    public func matches(_ event: CGEvent) -> Bool {
        matches(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
    }
}

/// Virtual key codes and their display names.
public enum KeyCodes {
    public static let special: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫", UInt16(kVK_Escape): "esc", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟", UInt16(kVK_CapsLock): "⇪",
        UInt16(kVK_Help): "Help", UInt16(kVK_ANSI_KeypadEnter): "⌤", UInt16(kVK_ANSI_KeypadClear): "⌧",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        UInt16(kVK_Command): "Left ⌘", UInt16(kVK_RightCommand): "Right ⌘",
        UInt16(kVK_Option): "Left ⌥", UInt16(kVK_RightOption): "Right ⌥",
        UInt16(kVK_Control): "Left ⌃", UInt16(kVK_RightControl): "Right ⌃",
        UInt16(kVK_Shift): "Left ⇧", UInt16(kVK_RightShift): "Right ⇧", UInt16(kVK_Function): "fn",
        UInt16(kVK_VolumeUp): "Volume Up", UInt16(kVK_VolumeDown): "Volume Down", UInt16(kVK_Mute): "Mute",
        UInt16(kVK_ANSI_Keypad0): "Num 0", UInt16(kVK_ANSI_Keypad1): "Num 1", UInt16(kVK_ANSI_Keypad2): "Num 2",
        UInt16(kVK_ANSI_Keypad3): "Num 3", UInt16(kVK_ANSI_Keypad4): "Num 4", UInt16(kVK_ANSI_Keypad5): "Num 5",
        UInt16(kVK_ANSI_Keypad6): "Num 6", UInt16(kVK_ANSI_Keypad7): "Num 7", UInt16(kVK_ANSI_Keypad8): "Num 8",
        UInt16(kVK_ANSI_Keypad9): "Num 9", UInt16(kVK_ANSI_KeypadDecimal): "Num .",
        UInt16(kVK_ANSI_KeypadMultiply): "Num *", UInt16(kVK_ANSI_KeypadPlus): "Num +",
        UInt16(kVK_ANSI_KeypadDivide): "Num /", UInt16(kVK_ANSI_KeypadMinus): "Num -",
        UInt16(kVK_ANSI_KeypadEquals): "Num =",
    ]

    /// Fallback names for character keys on a US ANSI layout.
    static let ansi: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 10: "§",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    public static func isFunctionKey(_ code: UInt16) -> Bool {
        let fkeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                               kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
                               kVK_F18, kVK_F19, kVK_F20, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
                               kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                               kVK_Help]
        return fkeys.contains(Int(code))
    }

    public static func isModifier(_ code: UInt16) -> Bool {
        [kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption, kVK_Control, kVK_RightControl,
         kVK_Shift, kVK_RightShift, kVK_Function, kVK_CapsLock].contains(Int(code))
    }

    /// Display name for a key code using the current keyboard layout for character keys.
    public static func name(for code: UInt16) -> String {
        if let s = special[code] { return s }
        if let c = character(for: code, shift: false), !c.isEmpty,
           c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return c.uppercased()
        }
        return ansi[code] ?? "Key \(code)"
    }

    /// The character a key produces on the current layout.
    public static func character(for code: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return ansi[code]
        }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), mods,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// Reverse lookup on the current layout (falls back to ANSI): `code(for: "c")`.
    public static func code(for character: String) -> UInt16? {
        let target = character.lowercased()
        for code in UInt16(0)...UInt16(127) where !isModifier(code) && special[code] == nil {
            if self.character(for: code, shift: false)?.lowercased() == target { return code }
        }
        return ansi.first { $0.value.lowercased() == target }?.key
    }

    /// Every nameable key, for pickers.
    public static var all: [(code: UInt16, name: String)] {
        var seen = Set<UInt16>()
        var result: [(UInt16, String)] = []
        for code in UInt16(0)...UInt16(127) {
            let n = name(for: code)
            if n.hasPrefix("Key ") { continue }
            if seen.insert(code).inserted { result.append((code, n)) }
        }
        return result.map { (code: $0.0, name: $0.1) }
    }
}
