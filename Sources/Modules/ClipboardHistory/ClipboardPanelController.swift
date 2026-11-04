import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Opens the panel or the paste bar, routes the keyboard to it, and pastes into the app the user
/// came from: the panel takes the keyboard without activating MacToys, so that app stays in front.
@MainActor
final class ClipboardPanelController: ClipboardPanelHost {
    private let settings: Persisted<ClipboardSettings>
    private let library: ClipLibrary
    private let stack: PasteStackController
    private let log = Log.for("clipboard")
    private var panel: FloatingPanel?
    private(set) var model: ClipboardPanelModel?
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    /// The app to paste into: frontmost when the panel opened, or the last one the user switched to.
    private var targetApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var askedForAccessibility = false

    init(settings: Persisted<ClipboardSettings>, library: ClipLibrary, stack: PasteStackController) {
        self.settings = settings
        self.library = library
        self.stack = stack
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func start() {
        guard activationObserver == nil else { return }
        noteFrontmost(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.noteFrontmost(app) }
        }
    }

    func stop() {
        close()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        panel?.contentView = nil
        panel = nil
    }

    private func noteFrontmost(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current else { return }
        lastExternalApp = app
    }

    private var currentExternalApp: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front == NSRunningApplication.current ? lastExternalApp : front
    }

    // MARK: Showing

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show(source: ClipboardPanelModel.Source? = nil, query: String = "") {
        if isVisible { close() }
        targetApp = currentExternalApp
        let s = settings.value
        let model = ClipboardPanelModel(history: ClipboardHistory.shared, library: library, settings: s)
        model.host = self
        model.stackCount = stack.isActive ? stack.stack.count : 0
        if let source { model.source = source }
        model.query = query
        model.startObserving()
        self.model = model

        let screen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame: CGRect
        let callbacks = PanelCallbacks(
            resume: { [weak self] in self?.settings.value.paused = false },
            settings: { [weak self] in self?.openSettings() },
            open: { [weak self] in self?.open($0) })
        let root: AnyView
        switch s.style {
        case .panel:
            let size = PanelLayout.panelSize
            frame = CGRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.maxY - vf.height * 0.2 - size.height).rounded(),
                           width: size.width, height: size.height)
            root = AnyView(ClipboardPanelView(model: model, callbacks: callbacks).frame(width: size.width, height: size.height))
        case .bar:
            let width = min(vf.width - 32, PanelLayout.barMaxWidth)
            frame = CGRect(x: (vf.midX - width / 2).rounded(), y: vf.minY + 12, width: width, height: PanelLayout.barHeight)
            root = AnyView(PasteBarView(model: model, callbacks: callbacks).frame(width: width, height: PanelLayout.barHeight))
        }

        let p = panel ?? makePanel()
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.setFrame(frame, display: false)
        // A non-activating panel takes the keyboard while the user's app stays frontmost.
        p.makeKeyAndOrderFront(nil)
        p.invalidateShadow()
        installKeyMonitor()
        model.focusRequest += 1
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(size: PanelLayout.panelSize)
        p.level = .modalPanel
        p.isMovableByWindowBackground = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.onClose = { [weak self] in self?.didClose() }
        panel = p
        return p
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.dismiss()
    }

    private func didClose() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model?.stopObserving()
        model = nil
        // Drop the SwiftUI tree so a closed panel holds no images.
        panel?.contentView = nil
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let e = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, e.window === panel else { return false }
                return self.handleKey(e)
            }
            return handled ? nil : event
        }
    }

    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let editor = panel?.firstResponder as? NSTextView
        // Keys that confirm or move through an input method's candidates belong to the input method.
        if editor?.hasMarkedText() == true { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        let isReturn = code == kVK_Return || code == kVK_ANSI_KeypadEnter

        switch model.mode {
        case .actions:
            switch code {
            case kVK_Escape: model.mode = .browse
            case kVK_UpArrow: model.moveAction(-1)
            case kVK_DownArrow: model.moveAction(1)
            case kVK_Return, kVK_ANSI_KeypadEnter: model.runSelectedAction()
            case kVK_ANSI_K where mods == .command: model.toggleActions()
            default: return false
            }
            return true
        case .editing:
            if code == kVK_Escape { model.cancelSheet(); return true }
            if isReturn, mods == .command { model.commitSheet(); return true }
            return false
        case .renaming, .newPinboard:
            if code == kVK_Escape { model.cancelSheet(); return true }
            return false
        case .confirmClear:
            if code == kVK_Escape { model.cancelSheet() } else if isReturn { model.commitSheet() }
            return true
        case .browse:
            break
        }

        let bar = model.settings.style == .bar
        if mods == .command, let n = Self.digits[code] {
            if let index = model.rows.firstIndex(where: { $0.number == n }) {
                model.select(index)
                model.activate()
            }
            return true
        }
        switch code {
        case kVK_Escape:
            if !model.query.isEmpty { model.query = "" }
            else if !model.marked.isEmpty { model.marked = [] }
            else if model.filter.isActive { model.filter = ClipFilter() }
            else { close() }
            return true
        case kVK_UpArrow where !bar || mods.isEmpty || mods == .shift, kVK_LeftArrow where bar && (mods.isEmpty || mods == .shift):
            model.move(mods.contains(.command) ? -100_000 : -1, extend: mods.contains(.shift))
            return true
        case kVK_DownArrow where !bar || mods.isEmpty || mods == .shift, kVK_RightArrow where bar && (mods.isEmpty || mods == .shift):
            model.move(mods.contains(.command) ? 100_000 : 1, extend: mods.contains(.shift))
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            switch mods {
            case []: model.activate()
            case .shift: model.activate(plain: true)
            case .option: model.perform(model.settings.returnAction == .paste ? .copy : .paste)
            default: return false
            }
            return true
        case kVK_Tab where mods.isEmpty || mods == .shift:
            model.cycleSource(mods == .shift ? -1 : 1)
            return true
        case kVK_ForwardDelete where mods.isEmpty && model.query.isEmpty:
            model.perform(.delete)
            return true
        case kVK_Delete where mods == .command:
            model.perform(.delete)
            return true
        default:
            break
        }
        guard mods == .command else { return false }
        switch code {
        case kVK_ANSI_C:
            if let editor, editor.selectedRange().length > 0 { return false }
            model.perform(.copy)
        case kVK_ANSI_K: model.toggleActions()
        case kVK_ANSI_P: model.perform(.togglePin)
        case kVK_ANSI_E: model.perform(.edit)
        case kVK_ANSI_R: model.perform(.rename)
        case kVK_ANSI_M: model.perform(.merge)
        case kVK_ANSI_F: model.focusRequest += 1
        case kVK_ANSI_Comma: openSettings()
        default: return false
        }
        return true
    }

    // MARK: ClipboardPanelHost

    func paste(_ item: ClipItem, plain: Bool, original: ClipItem?) {
        let app = targetApp
        close()
        let content = plain ? ClipItem(kind: .text, text: item.plainText ?? item.text) : item
        if settings.value.moveToTopOnPaste, var original {
            original.date = Date()
            ClipboardHistory.shared.add(original)
        }
        ClipboardHistory.shared.restore(content)
        deliver(into: app, cursorOffset: nil, restore: nil)
    }

    func copy(_ item: ClipItem, plain: Bool) {
        close()
        ClipboardHistory.shared.restore(plain ? ClipItem(kind: .text, text: item.plainText ?? item.text) : item)
        HUD.show("Copied", symbol: "doc.on.doc")
    }

    func pasteSnippet(_ snippet: Snippet, plain: Bool, copyOnly: Bool) {
        let app = targetApp
        close()
        let result = SnippetExpander.expand(snippet.text, clipboard: NSPasteboard.general.string(forType: .string))
        let snapshot = !copyOnly && settings.value.restoreClipboardAfterSnippet ? PasteboardSnapshot.capture() : nil
        ClipboardHistory.shared.restore(ClipItem(kind: .text, text: result.text))
        if copyOnly {
            HUD.show("Copied", symbol: "doc.on.doc")
            return
        }
        deliver(into: app, cursorOffset: result.cursorOffset, restore: snapshot)
    }

    func addToStack(_ items: [ClipItem]) {
        close()
        stack.add(items, order: settings.value.stackOrder)
    }

    func open(_ url: URL) {
        close()
        NSWorkspace.shared.open(url)
    }

    func reveal(_ urls: [URL]) {
        close()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func closePanel() { close() }

    func openSettings() {
        close()
        ModuleRegistry.shared.showSettings?("clipboard")
    }

    /// Returns focus to `app` and sends ⌘V (Accessibility); then moves the caret and restores the clipboard.
    private func deliver(into app: NSRunningApplication?, cursorOffset: Int?, restore snapshot: PasteboardSnapshot?) {
        guard AXIsProcessTrusted() else {
            HUD.show("Copied — press ⌘V to paste", symbol: "doc.on.clipboard", duration: 2.2)
            if !askedForAccessibility {
                askedForAccessibility = true
                PermissionCenter.shared.request(.accessibility)
            }
            return
        }
        Task {
            if let app, !app.isTerminated, NSWorkspace.shared.frontmostApplication != app {
                NSApp.yieldActivation(to: app)
                app.activate()
                for _ in 0..<50 where NSWorkspace.shared.frontmostApplication != app {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            // Let the window server hand key focus back before typing.
            try? await Task.sleep(for: .milliseconds(80))
            await Self.waitForModifierRelease()
            KeySynth.paste()
            if let cursorOffset, cursorOffset > 0 {
                try? await Task.sleep(for: .milliseconds(60))
                for _ in 0..<min(cursorOffset, 4000) { KeySynth.tap(kVK_LeftArrow) }
            }
            if let snapshot {
                try? await Task.sleep(for: .milliseconds(700))
                snapshot.restore()
            }
        }
    }

    /// Synthesized keys combine with physically held modifiers in some apps; wait for the shortcut's to lift.
    static func waitForModifierRelease() async {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        for _ in 0..<50 where !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
