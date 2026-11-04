import Foundation
import MacToysCore

/// Every switch Quick Switches offers. Toggles have an on/off state read from the system;
/// actions run once (they appear as tiles).
enum SwitchKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case hideDesktopIcons, showHiddenFiles, autohideDock, autohideMenuBar, darkMode, keepAwake
    case muteMicrophone, doNotDisturb, lowPowerMode, bluetooth
    case screenSaver, lockScreen, emptyTrash, cleanKeyboard

    var id: String { rawValue }

    var isToggle: Bool {
        switch self {
        case .screenSaver, .lockScreen, .emptyTrash, .cleanKeyboard: false
        default: true
        }
    }

    /// Shown in the menu bar flyout unless turned off in settings.
    var enabledByDefault: Bool {
        switch self {
        case .hideDesktopIcons, .showHiddenFiles, .autohideDock, .darkMode, .keepAwake, .muteMicrophone: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .hideDesktopIcons: String(localized: "Hide Desktop Icons", comment: "Quick switch")
        case .showHiddenFiles: String(localized: "Show Hidden Files", comment: "Quick switch")
        case .autohideDock: String(localized: "Hide the Dock", comment: "Quick switch: automatically hide and show the Dock")
        case .autohideMenuBar: String(localized: "Hide the Menu Bar", comment: "Quick switch: automatically hide and show the menu bar")
        case .darkMode: String(localized: "Dark Mode", comment: "Quick switch")
        case .keepAwake: String(localized: "Keep Awake", comment: "Quick switch: stop the Mac from sleeping")
        case .muteMicrophone: String(localized: "Mute Microphone", comment: "Quick switch")
        case .doNotDisturb: String(localized: "Do Not Disturb", comment: "Quick switch: Focus mode")
        case .lowPowerMode: String(localized: "Low Power Mode", comment: "Quick switch")
        case .bluetooth: String(localized: "Bluetooth Devices", comment: "Quick switch group: connect paired devices")
        case .screenSaver: String(localized: "Start Screen Saver", comment: "Quick action")
        case .lockScreen: String(localized: "Lock Screen", comment: "Quick action: lock the Mac now")
        case .emptyTrash: String(localized: "Empty Trash", comment: "Quick action")
        case .cleanKeyboard: String(localized: "Clean Keyboard", comment: "Quick action: lock the keyboard for a while to wipe it")
        }
    }

    var subtitle: String {
        switch self {
        case .hideDesktopIcons: String(localized: "Hide files and folders on the desktop, for screen sharing or a clean look. Finder restarts.")
        case .showHiddenFiles: String(localized: "Show files whose names start with a dot, in Finder and Open dialogs. Finder restarts.")
        case .autohideDock: String(localized: "The Dock slides in when you move the pointer to its edge.")
        case .autohideMenuBar: String(localized: "The menu bar appears when you move the pointer to the top of the screen.")
        case .darkMode: String(localized: "Switch between light and dark appearance. Uses Light Switch when it is on.")
        case .keepAwake: String(localized: "Stop your Mac from sleeping, with Awake.")
        case .muteMicrophone: String(localized: "Turn the input volume of the current microphone to zero, and back to where it was.")
        case .doNotDisturb: String(localized: "Runs a shortcut you choose that sets a Focus.")
        case .lowPowerMode: String(localized: "Saves energy. Changing it asks for your administrator password.")
        case .bluetooth: String(localized: "Connect or disconnect paired headphones, speakers and other devices.")
        case .screenSaver: String(localized: "Start the screen saver right away.")
        case .lockScreen: String(localized: "Lock your Mac and show the login window.")
        case .emptyTrash: String(localized: "Erase the items in the Trash, after asking.")
        case .cleanKeyboard: String(localized: "Ignore every key for a while so you can wipe the keyboard. Press esc three times to stop early.")
        }
    }

    var symbol: String {
        switch self {
        case .hideDesktopIcons: "menubar.dock.rectangle"
        case .showHiddenFiles: "eye"
        case .autohideDock: "dock.arrow.down.rectangle"
        case .autohideMenuBar: "menubar.arrow.up.rectangle"
        case .darkMode: "circle.lefthalf.filled"
        case .keepAwake: "cup.and.saucer.fill"
        case .muteMicrophone: "mic.slash.fill"
        case .doNotDisturb: "moon.fill"
        case .lowPowerMode: "battery.25percent"
        case .bluetooth: "headphones"
        case .screenSaver: "sparkles.tv"
        case .lockScreen: "lock.fill"
        case .emptyTrash: "trash.fill"
        case .cleanKeyboard: "keyboard"
        }
    }

    var tint: Tint {
        switch self {
        case .hideDesktopIcons: .teal
        case .showHiddenFiles: .graphite
        case .autohideDock: .blue
        case .autohideMenuBar: .indigo
        case .darkMode: .purple
        case .keepAwake: .orange
        case .muteMicrophone: .red
        case .doNotDisturb: .indigo
        case .lowPowerMode: .yellow
        case .bluetooth: .blue
        case .screenSaver: .cyan
        case .lockScreen: .graphite
        case .emptyTrash: .graphite
        case .cleanKeyboard: .mint
        }
    }
}

struct SwitchesSettings: Codable, Equatable {
    /// Switch id → shown in the flyout. Missing ids use `SwitchKind.enabledByDefault`.
    var enabled: [String: Bool] = [:]
    /// Switch id → shortcut. None by default.
    var shortcuts: [String: Shortcut] = [:]
    var showHUD = true
    /// How long Clean Keyboard ignores the keyboard.
    var cleanSeconds = 30
    /// Shortcuts app shortcut that turns a Focus on; `focusOffShortcut` nil runs the same one again to turn it off.
    var focusOnShortcut: String?
    var focusOffShortcut: String?
    /// Whether the Focus is on, as far as MacToys knows (macOS doesn't tell apps).
    var focusAssumedOn = false
    /// Bluetooth addresses shown as switches; nil shows every paired audio device.
    var bluetoothPinned: [String]?
    /// The input volume to restore when the microphone is unmuted.
    var micRestoreVolume: Double?

    func isEnabled(_ kind: SwitchKind) -> Bool { enabled[kind.rawValue] ?? kind.enabledByDefault }
    func shortcut(_ kind: SwitchKind) -> Shortcut? { shortcuts[kind.rawValue] }

    static let cleanRange = 10...180
}
