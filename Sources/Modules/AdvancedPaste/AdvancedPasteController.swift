import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// Opens the window, runs transforms and pastes results into the app the user came from.
@MainActor
final class AdvancedPasteController {
    private let settings: Persisted<AdvancedPasteSettings>
    private let log = Log.for("advancedpaste")
    private var panel: FloatingPanel?
    private var session: PasteSession?
    private var keyMonitor: Any?
    private var task: Task<Void, Never>?
    /// The app to paste into: frontmost when the window opened, or the last one the user switched to.
    private var targetApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(settings: Persisted<AdvancedPasteSettings>) {
        self.settings = settings
    }

    var isWindowVisible: Bool { panel?.isVisible ?? false }

    /// Tracks the last app that isn't MacToys, so actions launched from the menu bar paste there.
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
        closeWindow()
        task?.cancel()
        task = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func noteFrontmost(_ app: NSRunningApplication?) {
        guard let app, app != NSRunningApplication.current else { return }
        lastExternalApp = app
        if isWindowVisible { targetApp = app }
    }

    private var currentExternalApp: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        return front == NSRunningApplication.current ? lastExternalApp : front
    }

    // MARK: Window

    func toggleWindow() {
        if isWindowVisible { closeWindow() } else { showWindow() }
    }

    func showWindow() {
        guard !isWindowVisible, task == nil else { return }
        targetApp = currentExternalApp
        let s = settings.value
        let caret = s.windowPosition == .caret ? CaretLocator.caretRect() : nil
        if s.useSelectedText {
            task = Task { [weak self] in
                await Self.copySelection()
                self?.task = nil
                self?.present(caret: caret)
            }
        } else {
            present(caret: caret)
        }
    }

    private func present(caret: CGRect?) {
        let s = settings.value
        let history = s.historyEnabled ? ClipboardHistory.shared.items : []
        let session = PasteSession(input: AdvancedPasteTransforms.Input(pasteboard: .general), settings: s, history: history)
        self.session = session

        let panel = panel ?? FloatingPanel(size: CGSize(width: 440, height: 560))
        panel.hidesOnResign = s.closeOnFocusLoss
        panel.onClose = { [weak self] in self?.windowClosed() }
        panel.setContent(AdvancedPasteView(
            session: session,
            onRun: { [weak self] in self?.run($0) },
            onPrompt: { [weak self] in self?.runPrompt() },
            onCancel: { [weak self] in self?.task?.cancel() },
            onPastePreview: { [weak self] in self?.pastePreview() },
            onBack: { [weak self] in self?.session?.state = .idle },
            onSettings: { [weak self] in
                self?.closeWindow()
                ModuleRegistry.shared.showSettings?("advancedpaste")
            }))
        panel.setContentSize(CGSize(width: 440, height: 560))
        panel.setFrameOrigin(origin(for: panel.frame.size, caret: caret, position: s.windowPosition))
        self.panel = panel
        // A non-activating panel takes the keyboard while the user's app stays frontmost.
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func closeWindow() {
        guard let panel, panel.isVisible else { return }
        panel.dismiss()
    }

    private func windowClosed() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if case .running = session?.state { task?.cancel() }
        session = nil
    }

    /// Top-left of the window under the caret, else at the pointer, kept inside the visible frame.
    private func origin(for size: CGSize, caret: CGRect?, position: AdvancedPasteSettings.WindowPosition) -> CGPoint {
        let pointer = NSEvent.mouseLocation
        let anchorAX: CGPoint? = switch position {
        case .caret: caret.map { CGPoint(x: $0.minX - 20, y: $0.maxY + 6) } ?? ScreenGeometry.toAX(pointer)
        case .pointer: ScreenGeometry.toAX(pointer)
        case .center: nil
        }
        guard let anchorAX else {
            let vf = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame ?? .zero
            return CGPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + vf.height * 0.08)
        }
        let screen = ScreenGeometry.screen(containingAX: anchorAX) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let topLeft = ScreenGeometry.toCocoa(anchorAX)
        var origin = CGPoint(x: topLeft.x, y: topLeft.y - size.height)
        if origin.y < vf.minY, let caret {
            // Not enough room below the caret: open above it.
            origin.y = ScreenGeometry.toCocoa(CGPoint(x: 0, y: caret.minY - 6)).y
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        return origin
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private static let digitKeys: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5,
        UInt16(kVK_ANSI_6): 6, UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9,
    ]

    /// Returns true when the key was handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let session else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch session.state {
        case .idle:
            if mods == .command, let n = Self.digitKeys[event.keyCode] {
                if let row = session.row(number: n) { run(row) }
                return true
            }
            switch Int(event.keyCode) {
            case kVK_Escape:
                closeWindow()
                return true
            case kVK_UpArrow where mods.isEmpty:
                session.moveSelection(-1)
                return true
            case kVK_DownArrow where mods.isEmpty:
                session.moveSelection(1)
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if session.showsPrompt, !session.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
                    runPrompt()
                } else if let row = session.selectedRow {
                    run(row)
                }
                return true
            default:
                return false
            }
        case .running:
            if event.keyCode == UInt16(kVK_Escape) { task?.cancel(); return true }
            return false
        case .preview:
            if event.keyCode == UInt16(kVK_Escape) { session.state = .idle; return true }
            if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) { pastePreview(); return true }
            return false
        case .failed:
            if event.keyCode == UInt16(kVK_Escape) || event.keyCode == UInt16(kVK_Return) { session.state = .idle; return true }
            return false
        }
    }

    // MARK: Running

    private func run(_ row: PasteSession.Row) {
        guard let session, task == nil else { return }
        switch row.kind {
        case .history(let item):
            ClipboardHistory.shared.restore(item)
            session.use(item)
        case .action(let action):
            perform(action, title: action.title)
        case .custom(let custom):
            perform(.ai(prompt: custom.prompt, provider: settings.value.provider), title: custom.name)
        }
    }

    private func runPrompt() {
        guard let session else { return }
        let prompt = session.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        perform(.ai(prompt: prompt, provider: settings.value.provider), title: "Paste with AI")
    }

    private func perform(_ action: AdvancedPasteTransforms.Action, title: String) {
        guard let session, task == nil else { return }
        let input = session.input
        guard action.accepts(input) else {
            session.state = .failed(action.requirement)
            return
        }
        let original = settings.value.restoreClipboard ? PasteboardSnapshot.capture() : nil
        session.state = .running(title: title, progress: nil)
        let preview = settings.value.customFormatPreview && (action.isAI || action == .imageToText)
        task = Task { [weak self] in
            do {
                let output = try await AdvancedPasteTransforms.apply(action, to: input) { fraction in
                    Task { @MainActor in
                        if case .running(let t, _) = session.state { session.state = .running(title: t, progress: fraction) }
                    }
                }
                guard let self else { return }
                self.task = nil
                if preview, case .text = output {
                    session.state = .preview(title: title, output: output)
                } else {
                    self.finish(output, original: original)
                }
            } catch {
                self?.task = nil
                if error is CancellationError || Task.isCancelled {
                    session.state = .idle
                } else {
                    self?.log.error("\(title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    session.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func pastePreview() {
        guard let session, case .preview(_, let output) = session.state else { return }
        finish(output, original: settings.value.restoreClipboard ? PasteboardSnapshot.capture() : nil)
    }

    private func finish(_ output: AdvancedPasteTransforms.Output, original: PasteboardSnapshot?) {
        let app = targetApp
        session?.state = .idle
        closeWindow()
        task = Task { [weak self] in
            await self?.paste(output, original: original, into: app)
            self?.task = nil
        }
    }

    // MARK: Direct shortcuts

    /// Runs an action on the clipboard (or the selection) and pastes without opening the window.
    func runDirect(_ action: AdvancedPasteTransforms.Action, title: String, paste: Bool = true) {
        guard task == nil else { return }
        let app = currentExternalApp
        let useSelection = settings.value.useSelectedText
        let restore = settings.value.restoreClipboard
        task = Task { [weak self] in
            defer { self?.task = nil }
            if useSelection { await Self.copySelection() }
            let input = AdvancedPasteTransforms.Input(pasteboard: .general)
            guard !input.isEmpty else {
                HUD.show("The clipboard is empty", symbol: "doc.on.clipboard")
                return
            }
            let original = restore ? PasteboardSnapshot.capture() : nil
            guard action.accepts(input) else {
                HUD.show(action.requirement, symbol: "exclamationmark.triangle")
                return
            }
            if action.isLongRunning { HUD.show(title + "…", symbol: "hourglass", duration: 60) }
            do {
                let output = try await AdvancedPasteTransforms.apply(action, to: input)
                if paste {
                    await self?.paste(output, original: original, into: app)
                } else {
                    ClipboardHistory.shared.restore(output.clipItem)
                    HUD.show("Clipboard converted · \(title)", symbol: "doc.on.clipboard")
                }
            } catch is CancellationError {
                return
            } catch {
                self?.log.error("\(title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                HUD.show(error.localizedDescription, symbol: "exclamationmark.triangle", duration: 3)
            }
        }
    }

    // MARK: Pasting

    /// Writes the result, returns focus to `app` and sends ⌘V; optionally puts the original back.
    private func paste(_ output: AdvancedPasteTransforms.Output, original: PasteboardSnapshot?, into app: NSRunningApplication?) async {
        ClipboardHistory.shared.restore(output.clipItem)
        guard AXIsProcessTrusted() else {
            HUD.show("Copied · allow Accessibility to paste automatically", symbol: "exclamationmark.shield", duration: 2.5)
            PermissionCenter.shared.request(.accessibility)
            return
        }
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
        if let original {
            try? await Task.sleep(for: .milliseconds(700))
            original.restore()
        }
    }

    /// Sends ⌘C and waits briefly for the pasteboard to change.
    static func copySelection() async {
        guard AXIsProcessTrusted() else { return }
        await waitForModifierRelease()
        let before = NSPasteboard.general.changeCount
        KeySynth.copy()
        for _ in 0..<25 where NSPasteboard.general.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
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
