import AppKit
import Carbon.HIToolbox
import MacToysCore
import Observation
import SwiftUI

/// Every item and type on the general pasteboard, to put back exactly what was there.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    /// Very large copies aren't worth holding twice.
    private static let byteLimit = 64 * 1024 * 1024

    static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot? {
        var total = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > byteLimit { return nil }
                entry[type] = data
            }
            if !entry.isEmpty { items.append(entry) }
        }
        return items.isEmpty ? nil : PasteboardSnapshot(items: items)
    }

    /// Writes the snapshot back without it being recorded in the history again.
    @MainActor
    func restore(_ pb: NSPasteboard = .general) {
        if ClipboardHistory.shared.isRunning { ClipboardHistory.shared.ignoreNextChange = true }
        pb.clearContents()
        pb.writeObjects(items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }
}

/// Paste stack mode: new copies queue up; each ⌘V pastes the next one. A small HUD shows the queue.
///
/// While active, the next item is kept on the clipboard, and an event tap notices ⌘V (Accessibility)
/// and moves on a moment later, once the app has read the clipboard. Without Accessibility the HUD's
/// Next button moves on instead.
@MainActor
@Observable
final class PasteStackController {
    private(set) var isActive = false
    private(set) var stack = PasteStack()
    /// Whether ⌘V can be noticed (Accessibility granted).
    private(set) var canFollowPastes = false

    @ObservationIgnored var restoreOriginal = true
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private var hud: OverlayPanel?
    @ObservationIgnored private var original: PasteboardSnapshot?
    @ObservationIgnored private var pendingAdvance: DispatchWorkItem?
    @ObservationIgnored private let log = Log.for("clipboard")
    private static let tapID = "clipboard.pastestack"

    static let hudWidth: CGFloat = 320

    var detail: String {
        guard isActive else { return String(localized: "Copy several items, then paste them in order") }
        return stack.isEmpty ? String(localized: "Waiting for copies", comment: "Paste stack status")
            : String(localized: "\(stack.count) queued · ⌘V pastes the next", comment: "Paste stack status; %lld is the number of items")
    }

    func toggle(order: PasteStack.Order) {
        if isActive { stop() } else { start(order: order) }
    }

    func start(order: PasteStack.Order, with items: [ClipItem] = []) {
        if !isActive {
            isActive = true
            stack = PasteStack(order: order)
            original = restoreOriginal ? PasteboardSnapshot.capture() : nil
            installTap()
        }
        if !items.isEmpty {
            stack.push(contentsOf: items)
            loadNext()
        }
        showHUD()
        onChange()
    }

    /// Ends the mode; `restore` puts back what was on the clipboard before it started.
    func stop(restore: Bool = true) {
        guard isActive else { return }
        isActive = false
        pendingAdvance?.cancel()
        pendingAdvance = nil
        InputTap.shared.remove(Self.tapID)
        if restore, restoreOriginal, let original { original.restore() }
        original = nil
        stack.clear()
        hideHUD()
        onChange()
    }

    /// A new copy while the mode is on.
    func copied(_ item: ClipItem) {
        guard isActive else { return }
        stack.push(item)
        // In copy order the first item must stay on the clipboard, not the one just copied.
        if stack.next?.id != item.id { loadNext() }
        updateHUD()
        onChange()
    }

    /// Adds entries from the panel (oldest first), starting the mode when needed.
    func add(_ items: [ClipItem], order: PasteStack.Order) {
        start(order: order, with: items)
    }

    /// Drops the next item without pasting it.
    func skip() {
        guard isActive else { return }
        stack.advance()
        afterAdvance()
    }

    func remove(_ id: UUID) {
        let wasNext = stack.next?.id == id
        stack.remove(id)
        if wasNext { loadNext() }
        updateHUD()
        onChange()
    }

    // MARK: Following pastes

    private func installTap() {
        InputTap.shared.add(Self.tapID, priority: 20, events: [.keyDown]) { [weak self] _, event in
            // Hot path: only ⌘-chords without ⌃ are looked at further.
            let flags = event.flags
            guard flags.contains(.maskCommand), !flags.contains(.maskControl),
                  event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  let self, self.isActive, !self.stack.isEmpty, self.isPasteKey(event) else { return .pass }
            self.notePaste()
            return .pass
        }
        canFollowPastes = AXIsProcessTrusted()
    }

    /// ⌘V on any keyboard layout.
    private func isPasteKey(_ event: CGEvent) -> Bool {
        if let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers { return chars.lowercased() == "v" }
        return Int(event.getIntegerValueField(.keyboardEventKeycode)) == kVK_ANSI_V
    }

    private func notePaste() {
        if let pending = pendingAdvance {
            // A second ⌘V before the first was handled: move on now, so this one gets the next item.
            pending.cancel()
            pendingAdvance = nil
            stack.advance()
            loadNext()
            if stack.isEmpty {
                scheduleFinish()
            } else {
                updateHUD()
                onChange()
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.pendingAdvance = nil
                self.stack.advance()
                self.afterAdvance()
            }
        }
        pendingAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func afterAdvance() {
        if stack.isEmpty {
            scheduleFinish()
        } else {
            loadNext()
            updateHUD()
            onChange()
        }
    }

    private func scheduleFinish() {
        updateHUD()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                guard self.isActive, self.stack.isEmpty else { return }
                self.stop()
                HUD.show("Paste stack finished", symbol: "checkmark.circle")
            }
        }
    }

    private func loadNext() {
        guard let next = stack.next else { return }
        ClipboardHistory.shared.restore(next)
    }

    // MARK: HUD

    private func showHUD() {
        let panel = hud ?? OverlayPanel(frame: CGRect(x: 0, y: 0, width: Self.hudWidth, height: 200), interactive: true,
                                        acceptsKey: false, level: .statusBar)
        if hud == nil {
            panel.setContent(PasteStackHUD(controller: self))
            hud = panel
        }
        canFollowPastes = AXIsProcessTrusted()
        updateHUD()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func hideHUD() {
        guard let hud else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            hud.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if !self.isActive { hud.orderOut(nil) }
            }
        })
    }

    /// Sizes the HUD to its rows, top right of the screen under the pointer.
    private func updateHUD() {
        guard let hud else { return }
        canFollowPastes = AXIsProcessTrusted()
        let height = PasteStackHUD.height(rows: min(stack.count, PasteStackHUD.maxRows), warning: !canFollowPastes,
                                          more: stack.count > PasteStackHUD.maxRows)
        let screen = NSScreen.underMouse ?? NSScreen.main
        let vf = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = CGRect(x: vf.maxX - Self.hudWidth - 16, y: vf.maxY - height - 12, width: Self.hudWidth, height: height)
        hud.setFrame(frame, display: true)
    }

    /// Preview scenes: a filled stack without touching the pasteboard.
    static func preview(_ items: [ClipItem], canFollow: Bool = true) -> PasteStackController {
        let c = PasteStackController()
        c.isActive = true
        c.stack = PasteStack(order: .copyOrder, items: items)
        c.canFollowPastes = canFollow
        return c
    }
}

/// The paste stack's queue, top right of the screen.
struct PasteStackHUD: View {
    let controller: PasteStackController
    @Environment(\.clipStyle) private var style

    static let maxRows = 5

    static func height(rows: Int, warning: Bool, more: Bool) -> CGFloat {
        let body: CGFloat = rows == 0 ? 54 : CGFloat(rows) * 38 + 8 + (more ? 22 : 0)
        return 52 + body + (warning ? 58 : 0) + 42
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(style.hairline).frame(height: 1)
            queue
            if !controller.canFollowPastes { warning }
            Rectangle().fill(style.hairline).frame(height: 1)
            footer
        }
        .frame(width: PasteStackController.hudWidth)
        .clipGlass(cornerRadius: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Tint.indigo.gradient)
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Paste Stack").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(style.primary)
                Text(verbatim: controller.stack.order.title).font(.system(size: 11)).foregroundStyle(style.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(verbatim: controller.stack.count.formatted())
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(style.primary)
                .padding(.horizontal, 8)
                .frame(minWidth: 26, minHeight: 22)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    @ViewBuilder private var queue: some View {
        let items = controller.stack.queue
        if items.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc").foregroundStyle(style.tertiary)
                Text("Copy items to add them to the stack.").foregroundStyle(style.secondary)
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, minHeight: 54)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(items.prefix(Self.maxRows).enumerated()), id: \.element.id) { i, item in
                    row(item, index: i)
                }
                if items.count > Self.maxRows {
                    Text("and \(items.count - Self.maxRows) more", comment: "Paste stack: items beyond the visible rows")
                        .font(.system(size: 11)).foregroundStyle(style.tertiary).frame(height: 20)
                }
            }
            .padding(4)
            .animation(.snappy(duration: 0.2), value: items.map(\.id))
        }
    }

    private func row(_ item: ClipItem, index: Int) -> some View {
        HStack(spacing: 9) {
            Text(verbatim: (index + 1).formatted())
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(index == 0 ? .white : style.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(index == 0 ? Color.accentColor : Color.white.opacity(0.08)))
            ClipIcon(item: item, size: 22)
            Text(verbatim: item.displayTitle)
                .font(ClipTextStyle.titleFont(ClipContentType.of(item), size: 12.5))
                .foregroundStyle(style.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if index == 0 {
                Text("Next", comment: "Paste stack: the item ⌘V pastes next")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Button { controller.remove(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(style.tertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove from the stack"))
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(index == 0 ? style.selection : .clear))
    }

    private var warning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Tint.orange.color)
            Text("Allow Accessibility so ⌘V moves to the next item.")
                .font(.system(size: 11.5)).foregroundStyle(style.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { PermissionCenter.shared.request(.accessibility) } label: {
                Text("Allow…", comment: "Button: grant Accessibility for the paste stack").font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                KeyCap(key: "⌘")
                KeyCap(key: "V")
            }
            Text("pastes the next", comment: "Paste stack HUD footer, after the ⌘V keycaps").font(.system(size: 11.5)).foregroundStyle(style.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { controller.skip() } label: {
                Text("Skip", comment: "Button: drop the next paste stack item").font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.primary)
            .disabled(controller.stack.isEmpty)
            Button { controller.stop() } label: {
                Text("Done", comment: "Button: end paste stack mode").font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }
}
