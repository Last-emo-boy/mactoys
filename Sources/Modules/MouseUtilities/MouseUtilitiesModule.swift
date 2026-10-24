import AppKit
import MacToysCore
import SwiftUI

@MainActor
public final class MouseUtilitiesModule: ToyModule {
    public let info = ModuleInfo(
        id: "mouseutils", name: "Mouse Utilities",
        summary: "Find, highlight, lock, hide, jump, wrap and crosshair your pointer.",
        symbol: "cursorarrow.rays", tint: .red, category: .inputOutput,
        permissions: [.accessibility], enabledByDefault: true,
        keywords: ["find my mouse", "spotlight", "highlighter", "click", "jump", "crosshairs", "cursor wrap",
                   "hide cursor", "button lock", "drag lock", "gliding cursor", "pointer"])

    let settings = Persisted("mouseutils", default: MouseUtilitiesSettings())
    let findMyMouse: FindMyMouse
    let highlighter: MouseHighlighter
    let jump: MouseJump
    let crosshairs: Crosshairs
    let glide = GlidingCursorController()
    let cursorWrap: CursorWrap
    let autoHide: AutoHideCursor
    let buttonLock: MouseButtonLock
    private var running = false
    private var observing = false

    public init() {
        let s = settings.value
        findMyMouse = FindMyMouse(settings: s.findMyMouse)
        highlighter = MouseHighlighter(settings: s.highlighter)
        jump = MouseJump(settings: s.jump)
        crosshairs = Crosshairs(settings: s.crosshairs)
        cursorWrap = CursorWrap(settings: s.cursorWrap)
        autoHide = AutoHideCursor(settings: s.autoHide)
        buttonLock = MouseButtonLock(settings: s.buttonLock)
        crosshairs.pointerHidden = { [weak self] in self?.autoHide.isHidden ?? false }
        autoHide.onHiddenChange = { [weak self] _ in self?.crosshairs.pointerVisibilityChanged() }
    }

    public func start() {
        guard !running else { return }
        running = true
        if !observing {
            observing = true
            settings.onChange { [weak self] _ in
                guard let self, self.running else { return }
                self.sync(startup: false)
            }
        }
        sync(startup: true)
    }

    public func stop() {
        guard running else { return }
        running = false
        HotkeyCenter.shared.unregister(prefix: "mouseutils.")
        findMyMouse.stop()
        highlighter.setActive(false)
        jump.stop()
        crosshairs.setActive(false)
        glide.cancel()
        cursorWrap.setActive(false)
        autoHide.stop()
        buttonLock.stop()
        settings.flush()
    }

    /// Starts, stops and reconfigures every sub-utility to match the settings.
    private func sync(startup: Bool) {
        let s = settings.value

        findMyMouse.update(s.findMyMouse)
        if s.findMyMouse.enabled { findMyMouse.start() } else { findMyMouse.stop() }

        highlighter.update(s.highlighter)
        if s.highlighter.enabled {
            if startup && s.highlighter.autoActivate { highlighter.setActive(true) }
        } else {
            highlighter.setActive(false)
        }

        jump.update(s.jump)
        if s.jump.enabled { jump.start() } else { jump.stop() }

        crosshairs.update(s.crosshairs)
        glide.travelSpeed = s.crosshairs.glideTravelSpeed
        glide.delaySpeed = s.crosshairs.glideDelaySpeed
        glide.color = s.crosshairs.color
        glide.thickness = max(2, s.crosshairs.thickness * 0.6)
        if s.crosshairs.enabled {
            if startup && s.crosshairs.autoActivate { crosshairs.setActive(true) }
        } else {
            crosshairs.setActive(false)
            glide.cancel()
        }

        cursorWrap.update(s.cursorWrap)
        if s.cursorWrap.enabled {
            if startup && s.cursorWrap.autoActivate { cursorWrap.setActive(true) }
        } else {
            cursorWrap.setActive(false)
        }

        autoHide.update(s.autoHide)
        if s.autoHide.enabled { autoHide.start() } else { autoHide.stop() }

        buttonLock.update(s.buttonLock)
        if s.buttonLock.enabled { buttonLock.start() } else { buttonLock.stop() }

        registerHotkeys()
    }

    private func registerHotkeys() {
        let s = settings.value
        HotkeyCenter.shared.register("mouseutils.highlighter", s.highlighter.enabled ? s.highlighter.shortcut : nil) { [weak self] in
            self?.highlighter.toggle()
        }
        HotkeyCenter.shared.register("mouseutils.crosshairs", s.crosshairs.enabled ? s.crosshairs.shortcut : nil) { [weak self] in
            self?.crosshairs.toggle()
        }
        HotkeyCenter.shared.register("mouseutils.glide", s.crosshairs.enabled ? s.crosshairs.glideShortcut : nil) { [weak self] in
            self?.glide.press()
        }
        HotkeyCenter.shared.register("mouseutils.cursorwrap", s.cursorWrap.enabled ? s.cursorWrap.shortcut : nil) { [weak self] in
            self?.cursorWrap.toggle()
        }
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView {
        AnyView(MouseUtilitiesSettingsView(module: self))
    }

    public var quickActions: [QuickAction] {
        let s = settings.value
        var list: [QuickAction] = []
        if s.jump.enabled {
            list.append(QuickAction(id: "mouseutils.jump", title: "Mouse Jump", symbol: "rectangle.on.rectangle", tint: .red,
                                    shortcut: s.jump.shortcut) { [weak self] in self?.jump.open() })
        }
        if s.findMyMouse.enabled {
            list.append(QuickAction(id: "mouseutils.find", title: "Find My Mouse", symbol: "scope", tint: .red,
                                    shortcut: s.findMyMouse.activation == .shortcut ? s.findMyMouse.shortcut : nil) { [weak self] in
                self?.findMyMouse.activate()
            })
        }
        if s.highlighter.enabled {
            list.append(QuickAction(id: "mouseutils.highlighter", title: "Mouse Highlighter", symbol: "cursorarrow.click.2",
                                    tint: .red, shortcut: s.highlighter.shortcut,
                                    isOn: { [weak self] in self?.highlighter.isActive ?? false },
                                    detail: { s.highlighter.shortcut?.keys.joined(separator: " ") ?? s.highlighter.mode.title },
                                    perform: { [weak self] in self?.highlighter.toggle() }))
        }
        if s.crosshairs.enabled {
            list.append(QuickAction(id: "mouseutils.crosshairs", title: "Mouse Crosshairs", symbol: "plus.viewfinder",
                                    tint: .red, shortcut: s.crosshairs.shortcut,
                                    isOn: { [weak self] in self?.crosshairs.isActive ?? false },
                                    detail: { s.crosshairs.shortcut?.keys.joined(separator: " ") ?? "" },
                                    perform: { [weak self] in self?.crosshairs.toggle() }))
        }
        if s.cursorWrap.enabled {
            list.append(QuickAction(id: "mouseutils.cursorwrap", title: "CursorWrap", symbol: "arrow.left.and.right.square",
                                    tint: .red, shortcut: s.cursorWrap.shortcut,
                                    isOn: { [weak self] in self?.cursorWrap.isActive ?? false },
                                    detail: { s.cursorWrap.mode.title },
                                    perform: { [weak self] in self?.cursorWrap.toggle() }))
        }
        return list
    }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        var list: [ShortcutBinding] = []
        if s.findMyMouse.enabled {
            switch s.findMyMouse.activation {
            case .leftControlTwice: list.append(ShortcutBinding("Find My Mouse", keys: s.findMyMouse.requireCommand ? ["⌘", "Left ⌃", "×2"] : ["Left ⌃", "×2"]))
            case .rightControlTwice: list.append(ShortcutBinding("Find My Mouse", keys: s.findMyMouse.requireCommand ? ["⌘", "Right ⌃", "×2"] : ["Right ⌃", "×2"]))
            case .shake: list.append(ShortcutBinding("Find My Mouse", keys: ["Shake mouse"]))
            case .shortcut: list.append(ShortcutBinding("Find My Mouse", s.findMyMouse.shortcut))
            }
        }
        if s.highlighter.enabled { list.append(ShortcutBinding("Mouse Highlighter", s.highlighter.shortcut)) }
        if s.jump.enabled { list.append(ShortcutBinding("Mouse Jump", s.jump.shortcut)) }
        if s.crosshairs.enabled {
            list.append(ShortcutBinding("Mouse Crosshairs", s.crosshairs.shortcut))
            list.append(ShortcutBinding("Gliding cursor", s.crosshairs.glideShortcut))
        }
        if s.cursorWrap.enabled { list.append(ShortcutBinding("CursorWrap on/off", s.cursorWrap.shortcut)) }
        return list.filter { !$0.keys.isEmpty }
    }

    /// `mactoys://mouseutils/<action>`: `find`, `jump`, `highlighter`, `crosshairs`, `cursorwrap`
    /// (toggle, or `?on=1`/`?on=0`), `glide`, `open`/`settings`.
    public func handle(_ command: AppCommand) -> Bool {
        let on = command.parameters["on"].map { ["1", "true", "yes", "on"].contains($0.lowercased()) }
        switch command.action {
        case "find", "findmymouse":
            findMyMouse.activate()
        case "jump":
            jump.open()
        case "highlighter":
            if let on { highlighter.setActive(on) } else { highlighter.toggle() }
        case "crosshairs":
            if let on { crosshairs.setActive(on) } else { crosshairs.toggle() }
        case "cursorwrap":
            if let on { cursorWrap.setActive(on) } else { cursorWrap.toggle() }
        case "glide":
            glide.press()
        case "open", "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        let s = settings.value
        return [
            PreviewScene("findmymouse", size: CGSize(width: 720, height: 460), wallpaper: false) {
                AnyView(PreviewStage { SpotlightPreview(settings: s.findMyMouse) })
            },
            PreviewScene("highlighter", size: CGSize(width: 720, height: 460), wallpaper: false) {
                AnyView(PreviewStage { HighlighterPreview(settings: s.highlighter) })
            },
            PreviewScene("jump", size: CGSize(width: 720, height: 460), wallpaper: false) {
                AnyView(PreviewStage { MouseJumpPreview(settings: s.jump) })
            },
            PreviewScene("crosshairs", size: CGSize(width: 720, height: 460), wallpaper: false) {
                AnyView(PreviewStage { CrosshairsPreview(settings: s.crosshairs) })
            },
        ]
    }
}
