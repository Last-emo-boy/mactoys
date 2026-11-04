import AppKit
import Carbon.HIToolbox
import MacToysCore
import SwiftUI

/// A hosting view that takes the first click in its non-key panel and reports the pointer,
/// so hover works while another app is active.
final class BarHostingView: NSHostingView<BarRootView> {
    weak var model: BarModel?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { report(event) }
    override func mouseEntered(with event: NSEvent) { report(event) }
    override func mouseExited(with event: NSEvent) { model?.pointerExited() }

    private func report(_ event: NSEvent) {
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        model?.pointerMoved(to: p)
    }
}

/// Shows the bar and result cards next to the selection.
@MainActor
final class BarController {
    let model = BarModel()
    private var panel: OverlayPanel?
    private var host: BarHostingView?
    private var anchor = CGRect.zero
    private var side = TextActionsSettings.Placement.above
    private var screen: BarPlacement.Screen?
    private var hideWork: DispatchWorkItem?
    private var moveMonitor: Any?
    private var hideWhenPointerLeaves = true

    /// The panel's frame in global top-left coordinates while visible (for the event tap).
    private(set) var frameAX = CGRect.null
    private(set) var isVisible = false
    /// Bumped whenever the bar hides or shows new content, so late results are dropped.
    private(set) var token = 0
    /// Told when the bar appears or disappears, and when its frame or mode changes.
    var onStateChange: (() -> Void)?

    // MARK: Showing

    func present(items: [BarItem], anchor: CGRect, side: TextActionsSettings.Placement, settings: TextActionsSettings,
                 keyboard: Bool) {
        hideWork?.cancel()
        hideWork = nil
        token &+= 1
        let wasVisible = isVisible
        model.reset(items: items, settings: settings, keyboard: keyboard)
        self.anchor = anchor
        self.side = side
        self.hideWhenPointerLeaves = settings.hideWhenPointerLeaves
        screen = Self.screen(for: anchor)
        let panel = ensurePanel()
        if !wasVisible { model.isShown = false }
        relayout()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        isVisible = true
        installMoveMonitor()
        onStateChange?()
        if !wasVisible {
            DispatchQueue.main.async { [weak self] in self?.model.isShown = true }
        }
    }

    func setPage(_ page: BarPage) {
        model.setPage(page)
        relayout()
    }

    func showCard(_ card: ResultCard) {
        model.card = card
        model.cardCopied = false
        model.hovered = nil
        relayout()
    }

    /// Replaces the card's content if the bar still shows the same session.
    func updateCard(_ card: ResultCard, token: Int) {
        guard token == self.token, isVisible, model.card != nil else { return }
        showCard(card)
    }

    func enterKeyboardMode() {
        model.keyboardMode = true
        if model.card == nil, model.highlighted == nil { model.highlighted = 0 }
        removeMoveMonitor()
        onStateChange?()
    }

    /// Shows a checkmark on a button, then closes.
    func confirm(_ itemID: String, caption: String, then: (() -> Void)? = nil) {
        model.doneID = itemID
        model.doneCaption = caption
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.token == current else { return }
            self.hide()
            then?()
        }
    }

    func confirmCardCopy() {
        model.cardCopied = true
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.token == current else { return }
            self.hide()
        }
    }

    func hide(animated: Bool = true) {
        guard isVisible else { return }
        isVisible = false
        token &+= 1
        frameAX = .null
        removeMoveMonitor()
        model.isShown = false
        model.hovered = nil
        onStateChange?()
        guard let panel else { return }
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let work = DispatchWorkItem { [weak self, weak panel] in
                panel?.orderOut(nil)
                self?.hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        } else {
            panel.orderOut(nil)
        }
    }

    /// Tears the panel down (module stopped).
    func dispose() {
        hideWork?.cancel()
        hideWork = nil
        removeMoveMonitor()
        panel?.orderOut(nil)
        panel = nil
        host = nil
        isVisible = false
        frameAX = .null
        token &+= 1
    }

    // MARK: Layout

    private func ensurePanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 200, height: 60), interactive: true, acceptsKey: false,
                                 level: .popUpMenu)
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        let host = BarHostingView(rootView: BarRootView(model: model))
        host.model = model
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        host.frame = CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }

    /// Measures the content and places the panel against the anchor.
    func relayout() {
        guard let panel, let screen else { return }
        let probe = NSHostingView(rootView: BarRootView(model: model))
        let size = probe.fittingSize
        let m = BarMetrics.margin
        let inner = CGSize(width: max(1, size.width - 2 * m), height: max(1, size.height - 2 * m))
        let box = BarPlacement.frame(size: inner, anchor: anchor, side: side, screen: screen)
        let below = box.minY >= anchor.maxY - 1
        if model.below != below { model.below = below }
        let frame = box.insetBy(dx: -m, dy: -m)
        frameAX = frame
        panel.setFrame(ScreenGeometry.toCocoa(frame), display: true)
        onStateChange?()
    }

    static func screen(for anchor: CGRect) -> BarPlacement.Screen? {
        guard let s = ScreenGeometry.screen(containingAX: anchor.center) ?? NSScreen.main else { return nil }
        return BarPlacement.Screen(frame: s.axFrame, visible: s.axVisibleFrame, notch: notch(of: s))
    }

    /// The camera housing between the two auxiliary top areas, in global top-left coordinates.
    static func notch(of screen: NSScreen) -> CGRect? {
        let top = screen.safeAreaInsets.top
        guard top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        let cocoa = CGRect(x: left.maxX, y: screen.frame.maxY - top, width: right.minX - left.maxX, height: top)
        return ScreenGeometry.toAX(cocoa)
    }

    // MARK: Pointer leaving

    private func installMoveMonitor() {
        removeMoveMonitor()
        guard hideWhenPointerLeaves, !model.keyboardMode else { return }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    private func removeMoveMonitor() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
    }

    private func pointerMoved() {
        guard isVisible, model.card == nil, model.busyID == nil, !model.keyboardMode else { return }
        let p = MouseSynth.location
        if frameAX.distance(to: p) > 150 { hide() }
    }

    // MARK: Keyboard

    /// Handles a key while the bar is driven by the keyboard. Returns false for keys it
    /// doesn't use (the bar then closes and the key goes to the app).
    func handleKey(_ code: Int, shift: Bool) -> Bool {
        if model.card != nil {
            switch code {
            case kVK_Escape:
                hide()
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let card = model.card, let text = card.copyText, !card.isError { model.onCardAction?(.copy(text)) } else { hide() }
                return true
            default:
                return false
            }
        }
        let items = model.current
        switch code {
        case kVK_LeftArrow:
            model.move(-1)
        case kVK_RightArrow:
            model.move(1)
        case kVK_Tab:
            model.move(shift ? -1 : 1)
        case kVK_DownArrow:
            guard let i = model.highlighted, items.indices.contains(i) else { return true }
            let item = items[i]
            if item.kind == .more || item.kind == .builtIn(.changeCase) || item.kind == .builtIn(.spelling) {
                model.onActivate?(item)
            }
        case kVK_UpArrow:
            if model.page != .main { setPage(.main) }
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space:
            guard let i = model.highlighted, items.indices.contains(i) else { return true }
            model.onActivate?(items[i])
        case kVK_Escape:
            if model.page != .main { setPage(.main) } else { hide() }
        default:
            guard let n = Self.digit(code), n >= 1, n <= items.count else { return false }
            model.highlighted = n - 1
            model.onActivate?(items[n - 1])
        }
        return true
    }

    private static func digit(_ code: Int) -> Int? {
        switch code {
        case kVK_ANSI_1: 1
        case kVK_ANSI_2: 2
        case kVK_ANSI_3: 3
        case kVK_ANSI_4: 4
        case kVK_ANSI_5: 5
        case kVK_ANSI_6: 6
        case kVK_ANSI_7: 7
        case kVK_ANSI_8: 8
        case kVK_ANSI_9: 9
        default: nil
        }
    }
}
