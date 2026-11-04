import AppKit
import MacToysCore

/// Reads and flips every switch. Reads go to the system each time (so the flyout always shows the
/// real state); changes report success or failure in a HUD.
@MainActor
final class SwitchEngine {
    let settings: Persisted<SwitchesSettings>
    let bluetooth = BluetoothDevices()
    let cleaner = CleanKeyboardController()
    /// Switches whose change is still in progress (Finder restarting, a password prompt).
    private(set) var busy: Set<SwitchKind> = []
    private var pendingDevices: Set<String> = []

    init(settings: Persisted<SwitchesSettings>) {
        self.settings = settings
    }

    // MARK: State

    func isOn(_ kind: SwitchKind) -> Bool {
        switch kind {
        case .hideDesktopIcons: DefaultsSwitch.hideDesktopIcons.isOn
        case .showHiddenFiles: DefaultsSwitch.showHiddenFiles.isOn
        case .autohideDock: DefaultsSwitch.autohideDock.isOn
        case .autohideMenuBar: DefaultsSwitch.autohideMenuBar.isOn
        case .darkMode: SystemSwitches.isDark
        case .keepAwake: SystemSwitches.isKeptAwake
        case .muteMicrophone: Microphone.defaultInput().map { MicrophoneMute.isMuted(volume: Microphone.volume($0)) } ?? false
        case .doNotDisturb: FocusShortcuts.readFocusState() ?? settings.value.focusAssumedOn
        case .lowPowerMode: SystemSwitches.isLowPower
        case .bluetooth: devices().contains(where: \.connected)
        case .screenSaver, .lockScreen, .emptyTrash: false
        case .cleanKeyboard: cleaner.isRunning
        }
    }

    /// The flyout's second line; nil lets it show the shortcut instead.
    func detail(_ kind: SwitchKind) -> String? {
        if busy.contains(kind) { return String(localized: "Changing…", comment: "Quick switch is applying a change") }
        switch kind {
        case .muteMicrophone:
            guard let mic = Microphone.defaultInput() else { return String(localized: "No microphone") }
            return Microphone.volume(mic) == nil ? String(localized: "\(mic.name) has no volume control", comment: "The placeholder is a microphone name") : mic.name
        case .doNotDisturb:
            guard let name = settings.value.focusOnShortcut else { return String(localized: "Choose a shortcut in settings") }
            return FocusShortcuts.readFocusState() == nil ? String(localized: "Runs “\(name)”", comment: "The placeholder is a Shortcuts shortcut name") : nil
        default:
            return nil
        }
    }

    /// Paired devices shown as switches.
    func devices() -> [BluetoothDeviceInfo] {
        BluetoothDeviceInfo.shown(bluetooth.paired(), pinned: settings.value.bluetoothPinned)
    }

    func isConnecting(_ address: String) -> Bool { pendingDevices.contains(address) }

    // MARK: Changes

    /// Flips a toggle, or runs an action.
    func activate(_ kind: SwitchKind) {
        if kind.isToggle { set(kind, on: !isOn(kind)) } else { perform(kind) }
    }

    func set(_ kind: SwitchKind, on: Bool) {
        guard !busy.contains(kind) else { return }
        let done: @MainActor (Result<Void, SystemSwitches.Failure>) -> Void = { [weak self] result in
            self?.busy.remove(kind)
            self?.report(kind, on: on, result)
        }
        switch kind {
        case .hideDesktopIcons:
            busy.insert(kind)
            SystemSwitches.setFinder(.hideDesktopIcons, on: on, completion: done)
        case .showHiddenFiles:
            busy.insert(kind)
            SystemSwitches.setFinder(.showHiddenFiles, on: on, completion: done)
        case .autohideDock:
            busy.insert(kind)
            SystemSwitches.setDockAutohide(on, completion: done)
        case .autohideMenuBar:
            busy.insert(kind)
            SystemSwitches.setMenuBarAutohide(on, completion: done)
        case .darkMode:
            busy.insert(kind)
            SystemSwitches.setDark(on, completion: done)
        case .keepAwake:
            done(SystemSwitches.setKeepAwake(on))
        case .muteMicrophone:
            done(setMicrophoneMuted(on))
        case .doNotDisturb:
            setFocus(on, completion: done)
        case .lowPowerMode:
            busy.insert(kind)
            SystemSwitches.setLowPower(on, completion: done)
        case .bluetooth:
            // The group switch connects the first shown device, or disconnects all of them.
            if on, let first = devices().first { setDevice(first.id, connected: true) }
            else { for d in devices() where d.connected { setDevice(d.id, connected: false) } }
        case .screenSaver, .lockScreen, .emptyTrash, .cleanKeyboard:
            perform(kind)
        }
    }

    func perform(_ kind: SwitchKind) {
        switch kind {
        case .screenSaver:
            if case .failure(let f) = SystemSwitches.startScreenSaver() { HUD.show(f.message, symbol: "exclamationmark.triangle") }
        case .lockScreen:
            SystemSwitches.lockScreen()
        case .emptyTrash:
            confirmEmptyTrash()
        case .cleanKeyboard:
            if cleaner.isRunning { cleaner.stop() } else { cleaner.start(seconds: settings.value.cleanSeconds) }
        default:
            activate(kind)
        }
    }

    private func report(_ kind: SwitchKind, on: Bool, _ result: Result<Void, SystemSwitches.Failure>) {
        switch result {
        case .success:
            guard settings.value.showHUD else { return }
            let text = on ? String(localized: "\(kind.title): On", comment: "HUD after a quick switch turned on; the placeholder is its name")
                : String(localized: "\(kind.title): Off", comment: "HUD after a quick switch turned off; the placeholder is its name")
            HUD.show(text, symbol: kind.symbol)
        case .failure(let failure):
            HUD.show(failure.message, symbol: "exclamationmark.triangle", duration: 2.6)
        }
    }

    // MARK: Microphone

    private func setMicrophoneMuted(_ mute: Bool) -> Result<Void, SystemSwitches.Failure> {
        guard let mic = Microphone.defaultInput() else {
            return .failure(.init(message: String(localized: "No microphone is connected.")))
        }
        guard let current = Microphone.volume(mic) else {
            return .failure(.init(message: String(localized: "\(mic.name) has no volume control", comment: "The placeholder is a microphone name")))
        }
        if mute {
            if !MicrophoneMute.isMuted(volume: current) { settings.value.micRestoreVolume = current }
            guard Microphone.setVolume(0, on: mic) else {
                return .failure(.init(message: String(localized: "Couldn’t change the input volume of \(mic.name).", comment: "The placeholder is a microphone name")))
            }
        } else {
            guard Microphone.setVolume(MicrophoneMute.restoreLevel(remembered: settings.value.micRestoreVolume), on: mic) else {
                return .failure(.init(message: String(localized: "Couldn’t change the input volume of \(mic.name).", comment: "The placeholder is a microphone name")))
            }
        }
        return .success(())
    }

    // MARK: Focus

    private func setFocus(_ on: Bool, completion: @escaping @MainActor (Result<Void, SystemSwitches.Failure>) -> Void) {
        let s = settings.value
        guard let name = FocusShortcuts.shortcut(toTurnOn: on, onShortcut: s.focusOnShortcut, offShortcut: s.focusOffShortcut) else {
            completion(.failure(.init(message: String(localized: "Choose a Focus shortcut in Quick Switches settings."))))
            ModuleRegistry.shared.showSettings?("switches")
            return
        }
        busy.insert(.doNotDisturb)
        Task {
            let error = await FocusShortcuts.run(name)
            if error == nil { self.settings.value.focusAssumedOn = on }
            completion(error.map { .failure(.init(message: $0)) } ?? .success(()))
        }
    }

    // MARK: Bluetooth

    func setDevice(_ address: String, connected: Bool) {
        guard BluetoothDevices.isAvailable else {
            HUD.show("Bluetooth isn’t available in this build of MacToys", symbol: "exclamationmark.triangle")
            return
        }
        guard !pendingDevices.contains(address) else { return }
        let name = bluetooth.paired().first { $0.id == address }?.name ?? address
        pendingDevices.insert(address)
        if connected { HUD.show("Connecting \(name)…", symbol: "dot.radiowaves.left.and.right", duration: 8) }
        bluetooth.setConnected(connected, address: address) { [weak self] ok in
            self?.pendingDevices.remove(address)
            if ok {
                HUD.show(connected ? String(localized: "\(name) connected", comment: "The placeholder is a Bluetooth device name")
                         : String(localized: "\(name) disconnected", comment: "The placeholder is a Bluetooth device name"),
                         symbol: connected ? "checkmark.circle.fill" : "minus.circle")
            } else {
                HUD.show(connected ? String(localized: "Couldn’t connect \(name)", comment: "The placeholder is a Bluetooth device name")
                         : String(localized: "Couldn’t disconnect \(name)", comment: "The placeholder is a Bluetooth device name"),
                         symbol: "exclamationmark.triangle", duration: 2.6)
            }
        }
    }

    // MARK: Trash

    private func confirmEmptyTrash() {
        SystemSwitches.trashCount { count in
            if count == 0 {
                HUD.show("The Trash is empty", symbol: "trash")
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = switch count {
            case 1: String(localized: "Empty the Trash? 1 item will be erased.")
            case let n?: String(localized: "Empty the Trash? \(n) items will be erased.", comment: "Confirmation; the placeholder is the number of items")
            case nil: String(localized: "Empty the Trash?")
            }
            alert.informativeText = String(localized: "You can’t undo this.")
            alert.addButton(withTitle: String(localized: "Empty Trash", comment: "Confirmation button: empty the Trash"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SystemSwitches.emptyTrash { result in
                switch result {
                case .success: HUD.show("Trash emptied", symbol: "trash")
                case .failure(let f): HUD.show(f.message, symbol: "exclamationmark.shield", duration: 2.6)
                }
            }
        }
    }
}
