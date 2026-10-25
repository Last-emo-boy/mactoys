import AppKit
import Carbon.HIToolbox
import MacToysCore

/// A key the remapper can see or produce: a keyboard key (virtual key code) or a media key
/// (an `NX_KEYTYPE_*` code delivered as an `NSSystemDefined` event).
public struct Key: Codable, Hashable, Sendable, Comparable {
    public enum Kind: String, Codable, Sendable { case keyboard, media }

    public var kind: Kind
    public var code: Int

    public init(_ kind: Kind, _ code: Int) {
        self.kind = kind
        self.code = code
    }

    public static func keyboard(_ code: Int) -> Key { Key(.keyboard, code) }
    public static func media(_ code: Int) -> Key { Key(.media, code) }

    public static let capsLock = Key.keyboard(kVK_CapsLock)
    public static let escape = Key.keyboard(kVK_Escape)

    /// Shift, Control, Option, Command (either side) and fn. Caps Lock is not a modifier here.
    public var isModifier: Bool { kind == .keyboard && KeyCatalog.modifierInfo[code] != nil }

    /// The modifier this key holds down, for modifier keys.
    public var modifier: Modifiers? { kind == .keyboard ? KeyCatalog.modifierInfo[code]?.modifier : nil }

    public var name: String { KeyCatalog.name(of: self) }

    /// Keycaps for display, e.g. `["Right", "⌘"]` or `["esc"]`.
    public var keycaps: [String] {
        if kind == .keyboard, let info = KeyCatalog.modifierInfo[code], let side = info.side {
            return [side, info.symbol]
        }
        return [name]
    }

    public static func < (a: Key, b: Key) -> Bool {
        a.kind == b.kind ? a.code < b.code : a.kind == .keyboard
    }
}

/// A key with modifiers, used for shortcut triggers and outputs. With no modifiers it is a plain key.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var modifiers: Modifiers
    public var key: Key

    public init(_ modifiers: Modifiers = [], _ key: Key) {
        self.modifiers = modifiers
        self.key = key
    }

    public var keycaps: [String] { modifiers.symbols + key.keycaps }
    public var description: String { keycaps.joined(separator: " ") }
}

/// Names, groups and hardware codes for every key the editor offers.
public enum KeyCatalog {
    struct ModifierInfo {
        let modifier: Modifiers
        let symbol: String
        /// "Left"/"Right" (localized); nil for fn.
        let side: String?
        /// `NX_DEVICE…KEYMASK` bit carried in event flags while this key is down; 0 for fn.
        let deviceMask: UInt64
    }

    static let left = String(localized: "key.side.left", defaultValue: "Left", comment: "Keycap before a modifier symbol: the left-hand key of the pair (Left ⌘)")
    static let right = String(localized: "key.side.right", defaultValue: "Right", comment: "Keycap before a modifier symbol: the right-hand key of the pair (Right ⌘)")

    static let modifierInfo: [Int: ModifierInfo] = [
        kVK_Control: ModifierInfo(modifier: .control, symbol: "⌃", side: left, deviceMask: 0x0000_0001),
        kVK_Shift: ModifierInfo(modifier: .shift, symbol: "⇧", side: left, deviceMask: 0x0000_0002),
        kVK_RightShift: ModifierInfo(modifier: .shift, symbol: "⇧", side: right, deviceMask: 0x0000_0004),
        kVK_Command: ModifierInfo(modifier: .command, symbol: "⌘", side: left, deviceMask: 0x0000_0008),
        kVK_RightCommand: ModifierInfo(modifier: .command, symbol: "⌘", side: right, deviceMask: 0x0000_0010),
        kVK_Option: ModifierInfo(modifier: .option, symbol: "⌥", side: left, deviceMask: 0x0000_0020),
        kVK_RightOption: ModifierInfo(modifier: .option, symbol: "⌥", side: right, deviceMask: 0x0000_0040),
        kVK_RightControl: ModifierInfo(modifier: .control, symbol: "⌃", side: right, deviceMask: 0x0000_2000),
        kVK_Function: ModifierInfo(modifier: .function, symbol: "fn", side: nil, deviceMask: 0),
    ]

    /// The left-hand key for each generic modifier (what "hold as ⌃" produces).
    static let canonicalModifierKey: [(Modifiers, Int)] = [
        (.control, kVK_Control), (.option, kVK_Option), (.shift, kVK_Shift), (.command, kVK_Command),
        (.function, kVK_Function),
    ]

    /// `NX_KEYTYPE_*` media keys.
    static let mediaNames: [Int: String] = [
        0: String(localized: "Volume Up", comment: "Key name"),
        1: String(localized: "Volume Down", comment: "Key name"),
        2: String(localized: "Brightness Up", comment: "Key name"),
        3: String(localized: "Brightness Down", comment: "Key name"),
        5: String(localized: "Help (media)", comment: "Key name: the Help media key, as opposed to the Help key of extended keyboards"),
        7: String(localized: "Mute", comment: "Key name: the mute key"),
        10: String(localized: "Num Lock", comment: "Key name"),
        13: String(localized: "Launchpad", comment: "Key name"),
        14: String(localized: "Eject", comment: "Key name"),
        15: String(localized: "Mirror Displays", comment: "Key name"),
        16: String(localized: "Play/Pause", comment: "Key name"),
        17: String(localized: "Next Track", comment: "Key name"),
        18: String(localized: "Previous Track", comment: "Key name"),
        19: String(localized: "Fast Forward", comment: "Key name"),
        20: String(localized: "Rewind", comment: "Key name"),
        21: String(localized: "Keyboard Light Up", comment: "Key name: keyboard backlight brighter"),
        22: String(localized: "Keyboard Light Down", comment: "Key name: keyboard backlight dimmer"),
        23: String(localized: "Keyboard Light Toggle", comment: "Key name: keyboard backlight on/off"),
    ]

    /// Keys that exist on some keyboards only; names the current layout can't provide.
    static let extraNames: [Int: String] = [
        kVK_ISO_Section: "§", kVK_JIS_Yen: "¥ (JIS)", kVK_JIS_Underscore: "_ (JIS)",
        kVK_JIS_KeypadComma: String(localized: "Num , (JIS)", comment: "Key name: the comma key on a Japanese (JIS) numeric keypad"),
        kVK_JIS_Eisu: "英数 Eisu", kVK_JIS_Kana: "かな Kana",
        kVK_ContextualMenu: String(localized: "Menu", comment: "Key name: the context menu key of PC keyboards"),
        kVK_Help: String(localized: "Help / Insert", comment: "Key name: the Help key, Insert on PC keyboards"),
    ]

    /// Keys whose `KeyCodes` name is an English word: modifiers by side, Space, volume keys, the keypad.
    static let wordNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: String(localized: "Space", comment: "Key name: the space bar"),
            kVK_VolumeUp: String(localized: "Volume Up", comment: "Key name"),
            kVK_VolumeDown: String(localized: "Volume Down", comment: "Key name"),
            kVK_Mute: String(localized: "Mute", comment: "Key name: the mute key"),
        ]
        for (code, info) in modifierInfo {
            if info.side == left {
                names[code] = String(localized: "Left \(info.symbol)", comment: "Key name: a left-hand modifier key; %@ is its symbol, such as ⌘")
            } else if info.side == right {
                names[code] = String(localized: "Right \(info.symbol)", comment: "Key name: a right-hand modifier key; %@ is its symbol, such as ⌘")
            }
        }
        let keypad = [kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
                      kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
                      kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadDecimal: ".",
                      kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadPlus: "+", kVK_ANSI_KeypadDivide: "/",
                      kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadEquals: "="]
        for (code, label) in keypad {
            names[code] = String(localized: "Num \(label)", comment: "Key name: a numeric keypad key; %@ is the character on it, such as 7 or +")
        }
        return names
    }()

    public static func name(of key: Key) -> String {
        switch key.kind {
        case .media:
            return mediaNames[key.code] ?? String(localized: "Media \(key.code)", comment: "Key name: an unknown media key; %lld is its code")
        case .keyboard:
            if let n = extraNames[key.code] ?? wordNames[key.code] { return n }
            let code = UInt16(clamping: key.code)
            if let n = KeyCodes.special[code] { return n }
            return KeyCodes.name(for: code)
        }
    }

    /// One picker group.
    public struct Group: Identifiable {
        public let id: String
        public let title: String
        public let keys: [Key]
    }

    /// Every key offered by the key picker, grouped, including keys missing from this keyboard.
    public static var groups: [Group] {
        let letters = (0...127).filter { code in
            let c = UInt16(code)
            return !KeyCodes.isModifier(c) && KeyCodes.special[c] == nil && extraNames[code] == nil
                && !KeyCodes.name(for: c).hasPrefix("Key ")
        }.map(Key.keyboard).sorted { $0.name < $1.name }
        let modifiers = [kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_Shift, kVK_RightShift,
                         kVK_Command, kVK_RightCommand, kVK_Function, kVK_CapsLock].map(Key.keyboard)
        let editing = [kVK_Return, kVK_Tab, kVK_Space, kVK_Delete, kVK_ForwardDelete, kVK_Escape].map(Key.keyboard)
        let navigation = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End,
                          kVK_PageUp, kVK_PageDown, kVK_Help].map(Key.keyboard)
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11,
                     kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20].map(Key.keyboard)
        let keypad = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                      kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
                      kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadMultiply,
                      kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEquals, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadClear]
            .map(Key.keyboard)
        let media = mediaNames.keys.sorted().map(Key.media)
            + [kVK_VolumeUp, kVK_VolumeDown, kVK_Mute].map(Key.keyboard)
        let international = [kVK_ISO_Section, kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_KeypadComma, kVK_JIS_Eisu,
                             kVK_JIS_Kana, kVK_ContextualMenu].map(Key.keyboard)
        return [
            Group(id: "letters", title: String(localized: "Letters, digits & symbols", comment: "Key picker section"), keys: letters),
            Group(id: "modifiers", title: String(localized: "Modifiers", comment: "Key picker section"), keys: modifiers),
            Group(id: "editing", title: String(localized: "Editing", comment: "Key picker section"), keys: editing),
            Group(id: "navigation", title: String(localized: "Navigation", comment: "Key picker section"), keys: navigation),
            Group(id: "fkeys", title: String(localized: "Function keys", comment: "Key picker section"), keys: fkeys),
            Group(id: "keypad", title: String(localized: "Keypad", comment: "Key picker section"), keys: keypad),
            Group(id: "media", title: String(localized: "Media & system", comment: "Key picker section"), keys: media),
            Group(id: "international", title: String(localized: "International & other", comment: "Key picker section"), keys: international),
        ]
    }

    /// HID usage (page 7 keyboard or Apple top-case page) for a virtual key code, as
    /// `hidutil` expects it: `0x7_0000_0000 | usage`.
    public static func hidUsage(for key: Key) -> UInt64? {
        guard key.kind == .keyboard else { return nil }
        if key.code == kVK_Function { return 0xFF_0000_0003 }
        guard let usage = hidKeyboardUsage[key.code] else { return nil }
        return 0x7_0000_0000 | UInt64(usage)
    }

    /// The inverse of `hidUsage(for:)`.
    public static func key(forHIDUsage value: UInt64) -> Key? {
        if value == 0xFF_0000_0003 { return .keyboard(kVK_Function) }
        guard value >> 32 == 7 else { return nil }
        let usage = Int(value & 0xFFFF)
        return hidKeyboardUsage.first { $0.value == usage }.map { .keyboard($0.key) }
    }

    /// macOS virtual key code → USB HID keyboard usage.
    static let hidKeyboardUsage: [Int: Int] = [
        kVK_ANSI_A: 0x04, kVK_ANSI_B: 0x05, kVK_ANSI_C: 0x06, kVK_ANSI_D: 0x07, kVK_ANSI_E: 0x08,
        kVK_ANSI_F: 0x09, kVK_ANSI_G: 0x0A, kVK_ANSI_H: 0x0B, kVK_ANSI_I: 0x0C, kVK_ANSI_J: 0x0D,
        kVK_ANSI_K: 0x0E, kVK_ANSI_L: 0x0F, kVK_ANSI_M: 0x10, kVK_ANSI_N: 0x11, kVK_ANSI_O: 0x12,
        kVK_ANSI_P: 0x13, kVK_ANSI_Q: 0x14, kVK_ANSI_R: 0x15, kVK_ANSI_S: 0x16, kVK_ANSI_T: 0x17,
        kVK_ANSI_U: 0x18, kVK_ANSI_V: 0x19, kVK_ANSI_W: 0x1A, kVK_ANSI_X: 0x1B, kVK_ANSI_Y: 0x1C,
        kVK_ANSI_Z: 0x1D, kVK_ANSI_1: 0x1E, kVK_ANSI_2: 0x1F, kVK_ANSI_3: 0x20, kVK_ANSI_4: 0x21,
        kVK_ANSI_5: 0x22, kVK_ANSI_6: 0x23, kVK_ANSI_7: 0x24, kVK_ANSI_8: 0x25, kVK_ANSI_9: 0x26,
        kVK_ANSI_0: 0x27, kVK_Return: 0x28, kVK_Escape: 0x29, kVK_Delete: 0x2A, kVK_Tab: 0x2B,
        kVK_Space: 0x2C, kVK_ANSI_Minus: 0x2D, kVK_ANSI_Equal: 0x2E, kVK_ANSI_LeftBracket: 0x2F,
        kVK_ANSI_RightBracket: 0x30, kVK_ANSI_Backslash: 0x31, kVK_ANSI_Semicolon: 0x33, kVK_ANSI_Quote: 0x34,
        kVK_ANSI_Grave: 0x35, kVK_ANSI_Comma: 0x36, kVK_ANSI_Period: 0x37, kVK_ANSI_Slash: 0x38,
        kVK_CapsLock: 0x39, kVK_F1: 0x3A, kVK_F2: 0x3B, kVK_F3: 0x3C, kVK_F4: 0x3D, kVK_F5: 0x3E,
        kVK_F6: 0x3F, kVK_F7: 0x40, kVK_F8: 0x41, kVK_F9: 0x42, kVK_F10: 0x43, kVK_F11: 0x44, kVK_F12: 0x45,
        kVK_Help: 0x49, kVK_Home: 0x4A, kVK_PageUp: 0x4B, kVK_ForwardDelete: 0x4C, kVK_End: 0x4D,
        kVK_PageDown: 0x4E, kVK_RightArrow: 0x4F, kVK_LeftArrow: 0x50, kVK_DownArrow: 0x51, kVK_UpArrow: 0x52,
        kVK_ANSI_KeypadClear: 0x53, kVK_ANSI_KeypadDivide: 0x54, kVK_ANSI_KeypadMultiply: 0x55,
        kVK_ANSI_KeypadMinus: 0x56, kVK_ANSI_KeypadPlus: 0x57, kVK_ANSI_KeypadEnter: 0x58,
        kVK_ANSI_Keypad1: 0x59, kVK_ANSI_Keypad2: 0x5A, kVK_ANSI_Keypad3: 0x5B, kVK_ANSI_Keypad4: 0x5C,
        kVK_ANSI_Keypad5: 0x5D, kVK_ANSI_Keypad6: 0x5E, kVK_ANSI_Keypad7: 0x5F, kVK_ANSI_Keypad8: 0x60,
        kVK_ANSI_Keypad9: 0x61, kVK_ANSI_Keypad0: 0x62, kVK_ANSI_KeypadDecimal: 0x63, kVK_ISO_Section: 0x64,
        kVK_ContextualMenu: 0x65, kVK_ANSI_KeypadEquals: 0x67, kVK_F13: 0x68, kVK_F14: 0x69, kVK_F15: 0x6A,
        kVK_F16: 0x6B, kVK_F17: 0x6C, kVK_F18: 0x6D, kVK_F19: 0x6E, kVK_F20: 0x6F, kVK_Mute: 0x7F,
        kVK_VolumeUp: 0x80, kVK_VolumeDown: 0x81, kVK_JIS_KeypadComma: 0x85, kVK_JIS_Underscore: 0x87,
        kVK_JIS_Yen: 0x89, kVK_JIS_Kana: 0x90, kVK_JIS_Eisu: 0x91,
        kVK_Control: 0xE0, kVK_Shift: 0xE1, kVK_Option: 0xE2, kVK_Command: 0xE3,
        kVK_RightControl: 0xE4, kVK_RightShift: 0xE5, kVK_RightOption: 0xE6, kVK_RightCommand: 0xE7,
    ]

    /// Event-flag bits for a set of held modifier keys: generic masks plus the per-side device bits.
    static func flags(forHeld codes: some Sequence<Int>) -> CGEventFlags {
        var raw: UInt64 = 0
        for code in codes {
            guard let info = modifierInfo[code] else { continue }
            raw |= info.modifier.cgFlags.rawValue | info.deviceMask
        }
        return CGEventFlags(rawValue: raw)
    }

    /// Every bit `flags(forHeld:)` can produce except fn (which the system also sets on arrow and F keys).
    static let managedFlagMask: UInt64 = {
        var raw = Modifiers([.control, .option, .shift, .command]).cgFlags.rawValue
        for info in modifierInfo.values { raw |= info.deviceMask }
        return raw
    }()
}
