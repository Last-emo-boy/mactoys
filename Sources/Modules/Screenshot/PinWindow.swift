import AppKit
import MacToysCore
import Observation
import SwiftUI

/// A pinned screenshot's view state.
@MainActor
@Observable
final class PinModel {
    var image: NSImage
    var hovering = false
    var opacity: Double = 1
    var locked = false
    /// Current size ÷ the capture's point size, shown briefly while zooming.
    var zoom: CGFloat = 1
    var showZoom = false

    init(image: NSImage) { self.image = image }
}

/// What a pin's buttons and menu do.
struct PinActions {
    var copy: () -> Void = {}
    var save: () -> Void = {}
    var annotate: () -> Void = {}
    var copyText: () -> Void = {}
    var setOpacity: (Double) -> Void = { _ in }
    var lock: () -> Void = {}
    var close: () -> Void = {}
    var closeAll: () -> Void = {}
}

/// The pinned image: borderless, a toolbar while the pointer is over it, a context menu.
struct PinView: View {
    @Bindable var model: PinModel
    let actions: PinActions

    static let opacities: [Double] = [1, 0.8, 0.6, 0.4, 0.2]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: model.image)
                .resizable()
                .interpolation(.high)
                .gesture(WindowDragGesture())
            if model.hovering && !model.locked {
                toolbar
                    .padding(8)
                    .transition(.opacity)
            }
            if model.showZoom {
                Text(Double(model.zoom).formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.65)))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .animation(.smooth(duration: 0.16), value: model.hovering)
        .animation(.smooth(duration: 0.2), value: model.showZoom)
        .contextMenu { menu }
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            Menu {
                opacityItems
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(width: 26, height: 24)
            .help(Text("Opacity", comment: "Pinned screenshot: change how see-through it is"))
            icon("lock", Text("Lock (clicks pass through)", comment: "Pinned screenshot: make it click-through"), actions.lock)
            icon("doc.on.doc", Text("Copy", comment: "Pinned screenshot: copy the image"), actions.copy)
            icon("pencil.tip.crop.circle", Text("Annotate", comment: "Pinned screenshot: open it in the annotate window"), actions.annotate)
            icon("xmark", Text("Close", comment: "Pinned screenshot: close it"), actions.close)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.5)))
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
    }

    private func icon(_ symbol: String, _ help: Text, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder private var opacityItems: some View {
        ForEach(Self.opacities, id: \.self) { value in
            Button {
                actions.setOpacity(value)
            } label: {
                if abs(model.opacity - value) < 0.01 {
                    Label { Text(value.formatted(.percent.precision(.fractionLength(0)))) } icon: { Image(systemName: "checkmark") }
                } else {
                    Text(value.formatted(.percent.precision(.fractionLength(0))))
                }
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button { actions.copy() } label: { Text("Copy", comment: "Pinned screenshot menu") }
        Button { actions.copyText() } label: { Text("Copy Text", comment: "Pinned screenshot menu: recognize and copy the text") }
        Button { actions.save() } label: { Text("Save…", comment: "Pinned screenshot menu") }
        Button { actions.annotate() } label: { Text("Annotate", comment: "Pinned screenshot menu") }
        Divider()
        Menu { opacityItems } label: { Text("Opacity", comment: "Pinned screenshot menu") }
        Button { actions.lock() } label: { Text("Lock", comment: "Pinned screenshot menu: make it click-through") }
        Divider()
        Button { actions.close() } label: { Text("Close", comment: "Pinned screenshot menu") }
        Button { actions.closeAll() } label: { Text("Close All Pins", comment: "Pinned screenshot menu") }
    }
}

/// A borderless, always-on-top window showing a capture. Drag to move; scroll, pinch or ⌘+/⌘- to
/// resize; arrows nudge; Lock makes it click-through.
@MainActor
final class PinWindow: NSPanel {
    let item: CaptureItem
    let model: PinModel
    var onClose: ((PinWindow) -> Void)?
    private let baseSize: CGSize
    private var zoomHide: DispatchWorkItem?

    init(item: CaptureItem, actions: PinActions, near screen: NSScreen?) {
        self.item = item
        let rendered = item.rendered
        model = PinModel(image: NSImage(cgImage: rendered, size: item.pointSize))
        baseSize = item.pointSize
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, visible.width * 0.7 / max(baseSize.width, 1), visible.height * 0.7 / max(baseSize.height, 1))
        let size = CGSize(width: (baseSize.width * fit).rounded(), height: (baseSize.height * fit).rounded())
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        model.zoom = fit
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = baseSize
        contentMinSize = CGSize(width: 48, height: 48 * baseSize.height / max(baseSize.width, 1))
        title = String(localized: "Pinned screenshot", comment: "Window title (Window menu, accessibility)")
        let host = PinHostingView(rootView: PinView(model: model, actions: actions))
        host.onHover = { [weak self] inside in self?.model.hovering = inside }
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show() {
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = CGFloat(model.opacity)
        }
    }

    func setOpacity(_ value: Double) {
        model.opacity = value
        alphaValue = CGFloat(value)
    }

    /// Click-through until unlocked from the menu bar or a URL.
    func setLocked(_ locked: Bool) {
        model.locked = locked
        ignoresMouseEvents = locked
        if locked { model.hovering = false }
    }

    func refresh() {
        model.image = NSImage(cgImage: item.rendered, size: item.pointSize)
    }

    /// Resizes around the center by `factor`, between 10 % and 400 % of the capture's size.
    func zoom(by factor: CGFloat) {
        let current = frame.width / max(baseSize.width, 1)
        set(zoom: min(max(current * factor, 0.1), 4))
    }

    func set(zoom: CGFloat) {
        let size = CGSize(width: (baseSize.width * zoom).rounded(), height: (baseSize.height * zoom).rounded())
        let f = frame
        setFrame(CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height),
                 display: true)
        model.zoom = zoom
        model.showZoom = true
        zoomHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.showZoom = false }
        zoomHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 12
        guard abs(dy) > 0.001 else { return }
        zoom(by: 1 + max(-0.3, min(0.3, dy)))
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var o = frame.origin
        switch Int(event.keyCode) {
        case 123: o.x -= step
        case 124: o.x += step
        case 125: o.y -= step
        case 126: o.y += step
        case 53: close(); return                                   // esc
        default: super.keyDown(with: event); return
        }
        setFrameOrigin(o)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "w": close()
        case "=", "+": zoom(by: 1.15)
        case "-": zoom(by: 1 / 1.15)
        case "0": set(zoom: 1)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func close() {
        let callback = onClose
        onClose = nil
        super.close()
        contentView = nil
        callback?(self)
    }
}

/// Hover tracking that works while MacToys isn't the active app.
final class PinHostingView: NSHostingView<PinView> {
    var onHover: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["pin"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["pin": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}
