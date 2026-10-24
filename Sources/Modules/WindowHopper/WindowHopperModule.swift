import AppKit
import MacToysCore
import SwiftUI

/// Window Hopper: hold ⌥ and press ` to cycle through the windows of the focused app with
/// previews; release ⌥ to switch, Esc to cancel. Unlike ⌘Tab it never leaves the current app.
@MainActor
public final class WindowHopperModule: ToyModule {
    public let info = ModuleInfo(
        id: "windowhopper", name: "Window Hopper",
        summary: "Cycle through the windows of the focused app with previews.",
        symbol: "macwindow.on.rectangle", tint: .indigo, category: .windowing,
        permissions: [.accessibility, .screenRecording], enabledByDefault: false,
        keywords: ["switch", "windows", "alt tab", "cycle", "app windows", "backtick"])

    let settings = Persisted("windowhopper", default: WindowHopperSettings())

    /// A window offered by the switcher.
    private struct Candidate {
        let ref: WindowRef
        let id: CGWindowID
        let title: String
        let isMinimized: Bool
        let size: CGSize
        let frame: CGRect?
    }

    /// One open switcher.
    private struct Session {
        let token: Int
        let windows: [Candidate]
        /// Modifiers to hold; empty for a switcher opened from a URL (confirm with ↩ or a click).
        let hold: Modifiers
    }

    private enum Key {
        static let escape: UInt16 = 53, returnKey: UInt16 = 36, enter: UInt16 = 76
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    private var running = false
    private var session: Session?
    private var nextToken = 0
    private var panel: OverlayPanel?
    private let model = HopperModel()
    private var mouseMonitor: Any?
    private var pointerAtOpen = CGPoint.zero
    /// Key codes whose key-down we swallowed, so their key-up is swallowed too (no allocation per event).
    private var swallowUp = [Bool](repeating: false, count: 128)
    // Cached shortcut key codes for the O(1) early exit in the tap.
    private var nextShortcut: Shortcut?
    private var previousShortcut: Shortcut?
    private let log = Log.for("windowhopper")
    private static let tapID = "windowhopper"

    public init() {
        settings.onChange { [weak self] _ in self?.cacheShortcuts() }
        cacheShortcuts()
        model.onChoose = { [weak self] i in
            self?.model.selection = i
            self?.finish(choose: true)
        }
        model.onHover = { [weak self] i in
            // Only a pointer that actually moves selects: the panel may open right under it.
            guard let self, NSEvent.mouseLocation != self.pointerAtOpen else { return }
            self.model.selection = i
        }
    }

    // MARK: ToyModule

    public func start() {
        guard !running else { return }
        running = true
        // Built up front: the switcher opens from inside the event tap and must appear at once.
        if panel == nil { panel = makePanel(CGRect(x: 0, y: 0, width: 400, height: 220)) }
        InputTap.shared.add(Self.tapID, priority: 70, events: [.keyDown, .keyUp, .flagsChanged]) { [weak self] type, event in
            self?.handle(type, event) ?? .pass
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        InputTap.shared.remove(Self.tapID)
        finish(choose: false)
        panel?.close()
        panel = nil
        swallowUp = [Bool](repeating: false, count: 128)
    }

    public func settingsView() -> AnyView { AnyView(WindowHopperSettingsView(module: self)) }

    public var shortcutBindings: [ShortcutBinding] {
        let s = settings.value
        return [ShortcutBinding("Next window of the focused app", s.next),
                ShortcutBinding("Previous window of the focused app", s.previous)]
    }

    /// `mactoys://windowhopper/<action>`: `show` (switcher for the frontmost app; ↩ or click to
    /// switch, Esc to cancel), `settings`.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "show":
            guard running else { HUD.show("Window Hopper is off", symbol: "macwindow.on.rectangle"); return true }
            guard AXIsProcessTrusted() else {
                HUD.show("Accessibility permission needed", symbol: "exclamationmark.shield")
                PermissionCenter.shared.request(.accessibility)
                return true
            }
            if !open(forward: true, hold: []) { HUD.show("Only one window to switch to", symbol: "macwindow") }
        case "open", "settings": ModuleRegistry.shared.showSettings?(info.id)
        default: return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("hud", size: CGSize(width: 760, height: 280)) { AnyView(WindowHopperPreview(previews: true)) },
         PreviewScene("icons", size: CGSize(width: 980, height: 460)) { AnyView(WindowHopperPreview(previews: false)) }]
    }

    // MARK: Event tap (main thread, every key event)

    private func cacheShortcuts() {
        nextShortcut = settings.value.next
        previousShortcut = settings.value.previous
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> TapDecision {
        switch type {
        case .keyDown:
            let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            if session == nil {
                // Early exit: only the two hop keys can open the switcher.
                guard code == nextShortcut?.keyCode || code == previousShortcut?.keyCode else { return .pass }
                let backward = previousShortcut?.matches(event) == true
                guard let opener = backward ? previousShortcut : (nextShortcut?.matches(event) == true ? nextShortcut : nil)
                else { return .pass }
                guard open(forward: !backward, hold: HopperLogic.holdModifiers(for: opener)) else { return .pass }
                return swallow(code)
            }
            return handleWhileOpen(code: code, event: event)
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard code >= 0, code < swallowUp.count, swallowUp[code] else { return .pass }
            swallowUp[code] = false
            return .consume
        case .flagsChanged:
            if let s = session, HopperLogic.isReleased(hold: s.hold, now: Modifiers(event.flags)) {
                finish(choose: true)
            }
            return .pass
        default:
            return .pass
        }
    }

    private func handleWhileOpen(code: UInt16, event: CGEvent) -> TapDecision {
        let count = model.cards.count
        if code == previousShortcut?.keyCode, previousShortcut?.matches(event) == true {
            model.selection = HopperLogic.step(model.selection, by: -1, count: count)
            return swallow(code)
        }
        if code == nextShortcut?.keyCode {
            // ` again moves on; with ⇧ held it moves back.
            let back = event.flags.contains(.maskShift) && nextShortcut?.modifiers.contains(.shift) == false
            model.selection = HopperLogic.step(model.selection, by: back ? -1 : 1, count: count)
            return swallow(code)
        }
        switch code {
        case Key.escape:
            finish(choose: false)
            return swallow(code)
        case Key.returnKey, Key.enter:
            finish(choose: true)
            return swallow(code)
        case Key.left, Key.up:
            model.selection = HopperLogic.step(model.selection, by: code == Key.up ? -model.columns : -1, count: count)
            return swallow(code)
        case Key.right, Key.down:
            model.selection = HopperLogic.step(model.selection, by: code == Key.down ? model.columns : 1, count: count)
            return swallow(code)
        default:
            return .pass
        }
    }

    private func swallow(_ code: UInt16) -> TapDecision {
        if Int(code) < swallowUp.count { swallowUp[Int(code)] = true }
        return .consume
    }

    // MARK: Switcher

    /// Opens the switcher for the frontmost app; false (and nothing shown) with fewer than two windows.
    private func open(forward: Bool, hold: Modifiers) -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own else { return false }
        let windows = eligibleWindows(of: app.processIdentifier)
        guard windows.count >= 2 else { return false }
        nextToken += 1
        let s = Session(token: nextToken, windows: windows, hold: hold)
        session = s
        let canPreview = settings.value.showPreviews && CGPreflightScreenCaptureAccess()
        model.appName = app.localizedName ?? "App"
        model.appIcon = app.icon
        model.cards = windows.map { HopperModel.Card(id: $0.id, title: $0.title, isMinimized: $0.isMinimized) }
        model.thumbnails = [:]
        model.showThumbnails = canPreview
        model.selection = HopperLogic.initialSelection(forward: forward, count: windows.count)
        pointerAtOpen = NSEvent.mouseLocation
        present(near: windows.first?.frame)
        if canPreview { loadThumbnails(for: s) }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(choose: false) }
        }
        return true
    }

    private func present(near frame: CGRect?) {
        let screen = frame.flatMap { ScreenGeometry.screen(forAX: $0) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let vf = screen.visibleFrame
        model.columns = HopperLogic.columns(count: model.cards.count, maxWidth: vf.width)
        let size = HopperLogic.panelSize(count: model.cards.count, maxWidth: vf.width)
        let rect = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)
        let p = panel ?? makePanel(rect)
        p.setFrame(rect, display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
    }

    private func makePanel(_ rect: CGRect) -> OverlayPanel {
        let p = OverlayPanel(frame: rect, interactive: true, acceptsKey: false, level: .popUpMenu)
        p.setContent(HopperHUD(model: model))
        return p
    }

    /// Closes the switcher; with `choose`, switches to the selected window.
    private func finish(choose: Bool) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        guard let s = session else { return }
        session = nil
        panel?.orderOut(nil)
        model.thumbnails = [:]
        guard choose, s.windows.indices.contains(model.selection) else { return }
        let target = s.windows[model.selection].ref
        // Leave the tap callback first: focusing talks to the app over Accessibility.
        DispatchQueue.main.async {
            if target.isMinimized { target.minimize(false) }
            target.focus()
        }
    }

    /// Standard windows of `pid` on the current Space, front to back, then minimized ones.
    private func eligibleWindows(of pid: pid_t) -> [Candidate] {
        let axApp = AXUIElementCreateApplication(pid)
        // Runs inside the event tap: a hung app must not stall input.
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        let elements: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
        let onScreen = WindowInfo.onScreen().filter { $0.pid == pid }.map(\.id)
        let visible = Set(onScreen)
        let includeMinimized = settings.value.includeMinimized
        var result: [Candidate] = []
        for element in elements {
            AXUIElementSetMessagingTimeout(element, 0.15)
            let ref = WindowRef(element: element, pid: pid)
            guard ref.isStandard, let id = ref.windowID else { continue }
            let minimized = ref.isMinimized
            if minimized ? !includeMinimized : !visible.contains(id) { continue }
            let frame = ref.frame
            result.append(Candidate(ref: ref, id: id, title: ref.title ?? "", isMinimized: minimized,
                                    size: frame?.size ?? .zero, frame: frame))
        }
        return HopperLogic.ordered(result, id: { $0.id }, zOrder: onScreen)
    }

    private func loadThumbnails(for s: Session) {
        Task { [weak self] in
            for w in s.windows {
                guard let self, self.session?.token == s.token else { return }
                // About 2 px per card point: enough for a sharp 200 pt card.
                let scale = min(1, (HopperLogic.cardSize.width * 2.2) / max(w.size.width, 1))
                do {
                    let image = try await ScreenCapture.image(windowID: w.id, scale: scale)
                    guard self.session?.token == s.token else { return }
                    self.model.thumbnails[w.id] = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                } catch {
                    self.log.debug("No preview for window \(w.id): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
