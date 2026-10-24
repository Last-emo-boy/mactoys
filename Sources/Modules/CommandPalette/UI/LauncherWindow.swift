import AppKit
import MacToysCore
import SwiftUI

/// The floating panel of a launcher: placement, keyboard routing, resizing and giving focus
/// back to the app that was in front.
@MainActor
final class LauncherWindow: LauncherHost {
    let model: LauncherModel
    /// The panel size for the current model state.
    var size: () -> CGSize = { CGSize(width: 780, height: 540) }
    var screen: () -> LauncherScreen = { .mouse }
    /// Distance of the top edge from the top of the visible screen, as a fraction of its height.
    var verticalFraction: CGFloat = 0.2
    var hidesOnResign: () -> Bool = { true }
    var lastOrigin: () -> CGPoint? = { nil }
    var saveOrigin: (CGPoint) -> Void = { _ in }
    var openSettings: () -> Void = {}
    private let content: () -> AnyView

    private var panel: FloatingPanel?
    private var monitor: Any?
    private var previousApp: NSRunningApplication?
    private(set) var closedAt: Date?

    init(model: LauncherModel, content: @escaping () -> AnyView) {
        self.model = model
        self.content = content
        model.host = self
        model.textSelected = { [weak self] in
            guard let editor = self?.panel?.firstResponder as? NSTextView else { return false }
            return editor.selectedRange().length > 0
        }
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows the launcher (the caller has prepared the model).
    func show() {
        let own = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == own ? nil : front
        let p = panel ?? makePanel()
        p.hidesOnResign = hidesOnResign()
        let s = size()
        p.setFrame(frame(for: s), display: false)
        installMonitor()
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    func toggle(prepare: () -> Void) {
        if isVisible { dismissLauncher(restoreFocus: true) } else { prepare(); show() }
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(size: size())
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: content())
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        p.onClose = { [weak self] in self?.didHide() }
        panel = p
        return p
    }

    private func frame(for s: CGSize) -> CGRect {
        let choice = screen()
        if choice == .lastPosition, let o = lastOrigin(),
           let scr = NSScreen.screens.first(where: { $0.visibleFrame.contains(CGPoint(x: o.x + 20, y: o.y - 20)) }) {
            let vf = scr.visibleFrame
            let x = min(max(o.x, vf.minX), vf.maxX - s.width)
            let top = min(max(o.y, vf.minY + s.height), vf.maxY)
            return CGRect(x: x, y: top - s.height, width: s.width, height: s.height)
        }
        let target: NSScreen?
        switch choice {
        case .primary: target = NSScreen.screens.first
        case .focusedWindow:
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let win = WindowInfo.onScreen().first { $0.pid == front }
            target = win.flatMap { ScreenGeometry.screen(forAX: $0.frame) } ?? NSScreen.underMouse
        case .mouse, .lastPosition: target = NSScreen.underMouse
        }
        let vf = (target ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let top = vf.maxY - vf.height * verticalFraction
        return CGRect(x: (vf.midX - s.width / 2).rounded(), y: (top - s.height).rounded(), width: s.width, height: s.height)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, e.window === panel else { return false }
                // Keys that confirm or move through an input method's candidates belong to the IME.
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                return self.model.handleKey(e)
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: LauncherHost

    func dismissLauncher(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        let previous = previousApp
        panel.dismiss()
        if restoreFocus {
            previous?.activate()
        } else {
            // An action that opened another app lets it take focus; otherwise go back to the previous app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    if NSApp.isActive { previous?.activate() }
                }
            }
        }
    }

    func launcherLayoutChanged() {
        guard let panel, panel.isVisible else { return }
        let s = size()
        var f = panel.frame
        guard f.size != s else { return }
        let top = f.maxY
        f.size = s
        f.origin.y = top - s.height
        panel.setFrame(f, display: true, animate: false)
    }

    func openLauncherSettings() {
        dismissLauncher(restoreFocus: false)
        openSettings()
    }

    private func didHide() {
        removeMonitor()
        if let panel { saveOrigin(CGPoint(x: panel.frame.minX, y: panel.frame.maxY)) }
        closedAt = Date()
        model.closed()
    }

    /// Hides without side effects (module stop).
    func tearDown() {
        if let panel, panel.isVisible { panel.dismiss() }
        removeMonitor()
        panel?.contentView = nil
        panel = nil
    }
}

/// Whether the frontmost app shows a full-screen window (for "Ignore shortcut in full-screen mode").
enum FullScreenCheck {
    @MainActor static func frontmostIsFullScreen() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let win = WindowInfo.onScreen().first(where: { $0.pid == pid }) else { return false }
        return NSScreen.screens.contains { $0.axFrame == win.frame }
    }
}
