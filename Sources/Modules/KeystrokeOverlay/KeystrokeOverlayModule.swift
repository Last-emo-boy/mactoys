import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Keystroke Overlay: shows the keys and shortcuts you press, for screen recordings and presentations.
///
/// Listens through the shared `InputTap` and always passes every event on untouched. Keystrokes are
/// only drawn: nothing is recorded, logged or saved, typed text is dropped as soon as the pill fades,
/// and nothing shows while secure input is on, a password field is focused or an excluded app is
/// active. Shortcut names come from the active app's menus (read through Accessibility, cached per app).
///
/// URL actions: `toggle`, `show`, `hide`, `mode?value=shortcuts|allKeys|text`, `position` (drag editor), `settings`.
@MainActor
public final class KeystrokeOverlayModule: ToyModule {
    public let info = ModuleInfo(
        id: "keystrokes", name: "Keystroke Overlay",
        summary: "Show the keys and shortcuts you press, for recordings and presentations.",
        symbol: "keyboard.fill", tint: .yellow, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: false,
        keywords: ["keystroke", "keys", "shortcut", "presentation", "screencast", "overlay", "recording", "keycaps",
                   "visualize", "typing"])

    let settings = Persisted("keystrokes", default: KeystrokeSettings())
    let model = KeystrokeOverlayModel()
    private(set) lazy var panel = KeystrokePanel(model: model)
    private let names = MenuNames()
    private var running = false
    private var listening = false
    private var interpreter = KeystrokeInterpreter(mode: .shortcuts, typing: nil, shortcuts: nil)
    private var modifierTaps = ModifierTapTracker()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var focusWatcher: AXWatcher?
    private var frontPID: pid_t?
    private var frontExcluded = false
    private var secureField = false
    private static let hotkeyID = "keystrokes.toggle"
    private static let tapID = "keystrokes"

    public init() {
        model.settings = settings.value
        settings.onChange { [weak self] _ in self?.settingsChanged() }
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        registerHotkey()
        syncListening()
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(Self.hotkeyID)
        stopListening()
        panel.teardown()
    }

    public func settingsView() -> AnyView { AnyView(KeystrokeSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "keystrokes.toggle", title: "Keystroke Overlay", symbol: info.symbol, tint: info.tint,
                     shortcut: settings.value.toggle,
                     isOn: { [weak self] in self?.settings.value.showing ?? false },
                     detail: { [weak self] in
                         guard let s = self?.settings.value else { return "" }
                         return s.showing ? s.mode.title : String(localized: "Off", comment: "Keystroke Overlay quick action: not showing keys")
                     },
                     perform: { [weak self] in self?.toggle(feedback: false) })]
    }

    public var shortcutBindings: [ShortcutBinding] {
        [ShortcutBinding("Show or hide keystrokes", settings.value.toggle)]
    }

    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "toggle": toggle(feedback: true)
        case "show": setShowing(true, feedback: true)
        case "hide": setShowing(false, feedback: true)
        case "mode":
            guard let raw = command.parameters["value"], let mode = KeystrokeSettings.Mode(rawValue: raw) else { return false }
            settings.value.mode = mode
        case "position": editPosition()
        case "open", "settings": ModuleRegistry.shared.showSettings?(info.id)
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] { KeystrokePreviews.scenes(settings: settings) }

    // MARK: Actions

    func toggle(feedback: Bool) {
        setShowing(!settings.value.showing, feedback: feedback)
    }

    private func setShowing(_ on: Bool, feedback: Bool) {
        settings.value.showing = on
        guard feedback else { return }
        if !running {
            HUD.show("Keystroke Overlay is off in MacToys Settings", symbol: "keyboard")
        } else if on {
            HUD.show("Showing keystrokes · \(settings.value.mode.title)", symbol: "keyboard.fill")
        } else {
            HUD.show("Keystrokes hidden", symbol: "keyboard")
        }
    }

    func editPosition() {
        panel.editPosition { [weak self] point in
            self?.settings.update {
                $0.position = .custom
                $0.customX = Double(point.x)
                $0.customY = Double(point.y)
            }
        }
    }

    private func settingsChanged() {
        model.settings = settings.value
        guard running else { return }
        registerHotkey()
        if listening && settings.value.showing {
            // Already listening: pick up mode, layout, size, exclusion and click changes.
            configureInterpreter()
            refreshFront(NSWorkspace.shared.frontmostApplication)
            installTap()
        } else {
            syncListening()
        }
    }

    private func registerHotkey() {
        HotkeyCenter.shared.register(Self.hotkeyID, settings.value.toggle) { [weak self] in self?.toggle(feedback: true) }
    }

    // MARK: Listening

    /// Listens only while the overlay is on: when hidden, no handler sees a single key.
    private func syncListening() {
        if running && settings.value.showing { startListening() } else { stopListening() }
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        configureInterpreter()
        installTap()
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((center, token))
        }
        let ws = NSWorkspace.shared.notificationCenter
        on(ws, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            self?.refreshFront(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        on(ws, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.names.forget(app.processIdentifier)
            }
        }
        on(DistributedNotificationCenter.default(),
           Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)) { [weak self] _ in
            self?.configureInterpreter()
        }
        refreshFront(NSWorkspace.shared.frontmostApplication)
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        InputTap.shared.remove(Self.tapID)
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        focusWatcher?.invalidate()
        focusWatcher = nil
        frontPID = nil
        secureField = false
        names.clear()
        modifierTaps = ModifierTapTracker()
        interpreter.typing?.reset()
        panel.dismiss()
    }

    private func installTap() {
        let s = settings.value
        var events: [CGEventType] = [.keyDown, .flagsChanged]
        if s.mouseClicks { events += [.leftMouseDown, .rightMouseDown, .otherMouseDown] }
        // Highest priority so remaps and accent pickers further down can't hide the key that was
        // pressed; the handler copies a few fields and always passes the event on.
        InputTap.shared.add(Self.tapID, priority: 1000, events: events) { [weak self] type, event in
            let raw = RawInput(type: type,
                               keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                               flags: event.flags,
                               isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                               clickCount: Int(event.getIntegerValueField(.mouseEventClickState)),
                               button: event.getIntegerValueField(.mouseEventButtonNumber))
            DispatchQueue.main.async { self?.process(raw) }
            return .pass
        }
    }

    private func configureInterpreter() {
        let s = settings.value
        interpreter = KeystrokeInterpreter(mode: s.mode, specialKeys: s.specialKeys, maskText: s.maskText,
                                           typing: KeyboardLayouts.current().map { KeyTranslator(layout: $0) },
                                           shortcuts: KeyboardLayouts.asciiCapable().map { KeyTranslator(layout: $0) })
        let size = s.size
        model.feed.maxItems = size.maxItems
        model.feed.maxText = size.maxText
    }

    /// Tracks the active app: exclusion, its focused password field, and its menus for names.
    private func refreshFront(_ app: NSRunningApplication?) {
        let pid = app?.processIdentifier
        frontExcluded = settings.value.excludedApps.matches(app: app)
        if frontExcluded { panel.dismiss() }
        guard pid != frontPID else { return }
        frontPID = pid
        interpreter.typing?.reset()
        focusWatcher?.invalidate()
        focusWatcher = nil
        secureField = false
        guard let pid, AXIsProcessTrusted() else { return }
        let watcher = AXWatcher(pid: pid) { [weak self] _, element in
            MainActor.assumeIsolated { self?.secureField = Self.isSecureField(element) }
        }
        watcher?.add(kAXFocusedUIElementChangedNotification)
        focusWatcher = watcher
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.1)
        if let focused: AXUIElement = axApp.ax(kAXFocusedUIElementAttribute) { secureField = Self.isSecureField(focused) }
        if settings.value.showNames, !frontExcluded { names.prefetch(pid) }
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.1)
        let subrole: String? = element.ax(kAXSubroleAttribute)
        return subrole == kAXSecureTextFieldSubrole as String
    }

    // MARK: Events (main queue, after the tap has passed the event on)

    private struct RawInput {
        let type: CGEventType
        let keyCode: UInt16
        let flags: CGEventFlags
        let isRepeat: Bool
        let clickCount: Int
        let button: Int64
    }

    private func process(_ raw: RawInput) {
        guard listening else { return }
        let s = settings.value
        switch raw.type {
        case .keyDown:
            modifierTaps.interrupt()
            switch KeystrokePrivacy.verdict(isKey: true, secureInput: IsSecureEventInputEnabled(), secureField: secureField,
                                            excludedApp: frontExcluded) {
            case .ignore: return
            case .hideTyping:
                interpreter.typing?.reset()
                model.feed.hidden()
                panel.present()
                return
            case .show: break
            }
            let press = KeyPress(Int(raw.keyCode), Modifiers(raw.flags), capsLock: raw.flags.contains(.maskAlphaShift),
                                 isRepeat: raw.isRepeat)
            switch interpreter.interpret(press) {
            case .keys(let keys):
                model.feed.add(keys: keys, name: name(for: press, keys: keys))
            case .text(let text):
                guard !text.isEmpty else { return }
                model.feed.type(text)
            case .backspace:
                model.feed.backspace()
            case .ignore:
                return
            }
            panel.present()
        case .flagsChanged:
            guard !frontExcluded, !IsSecureEventInputEnabled(), !secureField else { return }
            if Int(raw.keyCode) == kVK_CapsLock {
                guard s.modifierOnly || s.mode == .allKeys else { return }
                model.feed.add(keys: ["⇪"])
                panel.present()
                return
            }
            if let alone = modifierTaps.flagsChanged(Modifiers(raw.flags)), s.modifierOnly {
                model.feed.add(keys: alone.symbols)
                panel.present()
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            modifierTaps.interrupt()
            guard s.mouseClicks,
                  KeystrokePrivacy.verdict(isKey: false, secureInput: false, secureField: false, excludedApp: frontExcluded) == .show
            else { return }
            let button: KeystrokeFeed.Click.Button = switch raw.type {
            case .leftMouseDown: .left
            case .rightMouseDown: .right
            default: raw.button == 2 ? .middle : .other
            }
            let mods = Modifiers(raw.flags).subtracting(.function)
            model.feed.click(KeystrokeFeed.Click(button, count: max(1, raw.clickCount), modifiers: mods.symbols))
            panel.present()
        default:
            break
        }
    }

    /// The menu item a shortcut triggers in the active app; filled in later when the menus are still being read.
    private func name(for press: KeyPress, keys: [String]) -> String? {
        guard settings.value.showNames, press.isShortcut || KeyNames.isSpecial(press.keyCode), let pid = frontPID,
              AXIsProcessTrusted() else { return nil }
        let layout = interpreter.shortcuts ?? interpreter.typing
        let base = layout?.label(press.keyCode)
        let shifted = layout?.label(press.keyCode, shift: true)
        let index = names.index(for: pid) { [weak self] index in
            guard let self, let name = index.name(for: press, base: base, shifted: shifted) else { return }
            self.model.feed.setName(name, forKeys: keys)
        }
        return index?.name(for: press, base: base, shifted: shifted)
    }
}
