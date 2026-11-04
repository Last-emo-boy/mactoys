import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Where Quick Access cards go. Pure, for tests.
enum QuickAccessLayout {
    static let margin: CGFloat = 18
    static let spacing: CGFloat = 12

    /// A card as wide as `width`, as tall as the capture's shape allows (never a sliver, never a tower).
    static func cardSize(image: CGSize, width: CGFloat) -> CGSize {
        let aspect = image.width / max(image.height, 1)
        let height = min(max(width / max(aspect, 0.01), width * 0.5), width * 1.05)
        return CGSize(width: width, height: height.rounded())
    }

    /// Cocoa frames for cards, newest first: the newest sits in the corner, older ones stack away from it.
    /// Cards that don't fit on the screen get no frame (the controller closes them).
    static func frames(sizes: [CGSize], corner: OverlayCorner, in visible: CGRect) -> [CGRect] {
        var frames: [CGRect] = []
        var edge = corner.isTop ? visible.maxY - margin : visible.minY + margin
        for size in sizes {
            let x = corner.isLeft ? visible.minX + margin : visible.maxX - margin - size.width
            let y = corner.isTop ? edge - size.height : edge
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            guard frame.minY >= visible.minY, frame.maxY <= visible.maxY else { break }
            frames.append(frame)
            edge = corner.isTop ? frame.minY - spacing : frame.maxY + spacing
        }
        return frames
    }
}

/// What a card's buttons do.
struct QuickAccessActions {
    var copy: (CaptureItem) -> Void = { _ in }
    var save: (CaptureItem) -> Void = { _ in }
    var annotate: (CaptureItem) -> Void = { _ in }
    var pin: (CaptureItem) -> Void = { _ in }
    var copyText: (CaptureItem) -> Void = { _ in }
    /// A file for dragging the capture into another app.
    var dragFile: (CaptureItem) -> URL? = { _ in nil }
}

/// One card's view state.
@MainActor
@Observable
final class QuickAccessCardModel {
    let item: CaptureItem
    var thumbnail: NSImage
    var hovering = false
    /// Feedback after Copy or Save.
    var flash: String?
    @ObservationIgnored var onClose: () -> Void = {}

    init(item: CaptureItem, thumbnail: NSImage) {
        self.item = item
        self.thumbnail = thumbnail
    }

    func flash(_ text: String) {
        flash = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            if self?.flash == text { self?.flash = nil }
        }
    }
}

/// The floating thumbnail after a capture (design: dark glass card, actions on hover).
struct QuickAccessCardView: View {
    @Bindable var model: QuickAccessCardModel
    let actions: QuickAccessActions

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack {
            LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
            Image(nsImage: model.thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            if model.hovering { hoverLayer.transition(.opacity) }
            if let flash = model.flash {
                Label { Text(verbatim: flash) } icon: { Image(systemName: "checkmark.circle.fill") }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .contentShape(shape)
        .onDrag {
            guard let url = actions.dragFile(model.item), let provider = NSItemProvider(contentsOf: url) else {
                return NSItemProvider()
            }
            return provider
        }
        .onTapGesture(count: 2) { actions.annotate(model.item) }
        .animation(.smooth(duration: 0.18), value: model.hovering)
        .animation(.snappy(duration: 0.2), value: model.flash)
        .environment(\.colorScheme, .dark)
    }

    private var hoverLayer: some View {
        ZStack {
            Color.black.opacity(0.45)
            // Short cards put the two buttons side by side, clear of the corner buttons.
            GeometryReader { proxy in
                let layout = proxy.size.height < 150
                    ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 8))
                layout {
                    pill(Text("Copy", comment: "Quick Access card: copy the screenshot")) {
                        actions.copy(model.item)
                        model.flash(String(localized: "Copied", comment: "Quick Access card: the screenshot was copied"))
                    }
                    pill(model.item.savedURL == nil ? Text("Save", comment: "Quick Access card: save the screenshot to a file")
                                                    : Text("Show in Finder", comment: "Quick Access card: reveal the saved file")) {
                        actions.save(model.item)
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            corner(.topLeading, "xmark", Text("Close", comment: "Quick Access card button")) { model.onClose() }
            corner(.topTrailing, "pencil.tip.crop.circle", Text("Annotate", comment: "Quick Access card button")) {
                actions.annotate(model.item)
            }
            corner(.bottomLeading, "pin", Text("Pin to screen", comment: "Quick Access card button")) { actions.pin(model.item) }
            corner(.bottomTrailing, "text.viewfinder", Text("Copy text", comment: "Quick Access card button: recognize and copy the text")) {
                actions.copyText(model.item)
            }
        }
    }

    private func pill(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            title
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 72, maxWidth: 120)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule().fill(.white.opacity(0.16)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.28)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func corner(_ alignment: Alignment, _ symbol: String, _ help: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

/// A card's hosting view: hover without activating MacToys, first-click buttons, and swipe to dismiss.
final class QuickAccessHostingView: NSHostingView<QuickAccessCardView> {
    var onHover: ((Bool) -> Void)?
    var onSwipe: ((CGFloat, NSEvent.Phase) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["quickaccess"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["quickaccess": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) || !event.phase.isEmpty else {
            super.scrollWheel(with: event)
            return
        }
        onSwipe?(event.scrollingDeltaX, event.phase)
    }
}

/// The stack of Quick Access cards in a screen corner.
@MainActor
final class QuickAccessController {
    @MainActor
    private final class Card {
        let model: QuickAccessCardModel
        let panel: OverlayPanel
        let size: CGSize
        var timer: Timer?
        var swipe: CGFloat = 0
        var home: CGRect = .zero

        init(model: QuickAccessCardModel, panel: OverlayPanel, size: CGSize) {
            self.model = model
            self.panel = panel
            self.size = size
        }
    }

    var actions = QuickAccessActions()
    var settings: () -> ScreenshotSettings = { ScreenshotSettings() }
    private var cards: [Card] = []
    private var screen: NSScreen?
    private static let maxCards = 6

    var isEmpty: Bool { cards.isEmpty }

    func show(_ item: CaptureItem, on screen: NSScreen?) {
        let s = settings()
        self.screen = screen ?? NSScreen.main
        let size = QuickAccessLayout.cardSize(image: item.pointSize, width: s.overlaySize.width)
        let model = QuickAccessCardModel(item: item, thumbnail: Self.thumbnail(item, width: size.width))
        let panel = OverlayPanel(frame: CGRect(origin: .zero, size: size), interactive: true, acceptsKey: false,
                                 level: .statusBar)
        panel.hasShadow = true
        let host = QuickAccessHostingView(rootView: QuickAccessCardView(model: model, actions: actions))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        let card = Card(model: model, panel: panel, size: size)
        model.onClose = { [weak self, weak card] in
            guard let self, let card else { return }
            self.dismiss(card, toEdge: false)
        }
        host.onHover = { [weak self, weak card] inside in
            guard let self, let card else { return }
            card.model.hovering = inside
            if inside { card.timer?.invalidate(); card.timer = nil } else { self.scheduleClose(card) }
        }
        host.onSwipe = { [weak self, weak card] dx, phase in
            guard let self, let card else { return }
            self.swipe(card, dx: dx, phase: phase)
        }
        cards.insert(card, at: 0)
        while cards.count > Self.maxCards, let oldest = cards.last { dismiss(oldest, toEdge: false) }
        layout(entering: card)
        scheduleClose(card)
    }

    /// Refreshes a card after its capture was edited.
    func refresh(_ item: CaptureItem) {
        for card in cards where card.model.item === item {
            card.model.thumbnail = Self.thumbnail(item, width: card.size.width)
        }
    }

    func close(_ item: CaptureItem) {
        for card in cards where card.model.item === item { dismiss(card, toEdge: false) }
    }

    func closeAll() {
        for card in cards {
            card.timer?.invalidate()
            card.panel.orderOut(nil)
            card.panel.contentView = nil
        }
        cards.removeAll()
    }

    // MARK: Layout

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func layout(entering: Card? = nil) {
        let s = settings()
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let frames = QuickAccessLayout.frames(sizes: cards.map(\.size), corner: s.overlayCorner, in: visible)
        for (card, frame) in zip(cards, frames) { card.home = frame }
        // Cards that no longer fit go away.
        for card in cards.dropFirst(frames.count) { dismiss(card, toEdge: false) }
        for card in cards.prefix(frames.count) {
            if card === entering {
                let dx = (s.overlayCorner.isLeft ? -1 : 1) * (card.size.width + QuickAccessLayout.margin)
                card.panel.setFrame(reduceMotion ? card.home : card.home.offsetBy(dx: dx, dy: 0), display: false)
                card.panel.alphaValue = 0
                card.panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0.15 : 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                card.panel.animator().setFrame(card.home, display: true)
                card.panel.animator().alphaValue = 1
            }
        }
    }

    private func scheduleClose(_ card: Card) {
        card.timer?.invalidate()
        card.timer = nil
        let seconds = settings().autoCloseSeconds
        guard seconds > 0 else { return }
        card.timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self, weak card] _ in
            MainActor.assumeIsolated {
                guard let self, let card, !card.model.hovering else { return }
                self.dismiss(card, toEdge: true)
            }
        }
    }

    private func dismiss(_ card: Card, toEdge: Bool) {
        guard let i = cards.firstIndex(where: { $0 === card }) else { return }
        cards.remove(at: i)
        card.timer?.invalidate()
        card.timer = nil
        let s = settings()
        var target = card.panel.frame
        if toEdge && !reduceMotion {
            target = target.offsetBy(dx: (s.overlayCorner.isLeft ? -1 : 1) * (card.size.width + QuickAccessLayout.margin * 2), dy: 0)
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            card.panel.animator().setFrame(target, display: true)
            card.panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                card.panel.orderOut(nil)
                card.panel.contentView = nil
            }
        })
        layout()
    }

    /// Two-finger swipe toward the screen edge dismisses; a short one springs back.
    private func swipe(_ card: Card, dx: CGFloat, phase: NSEvent.Phase) {
        let towardEdge: CGFloat = settings().overlayCorner.isLeft ? -1 : 1
        if phase.contains(.ended) || phase.contains(.cancelled) {
            if card.swipe * towardEdge > 50 {
                card.swipe = 0
                dismiss(card, toEdge: true)
            } else {
                card.swipe = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    card.panel.animator().setFrame(card.home, display: true)
                    card.panel.animator().alphaValue = 1
                }
            }
            return
        }
        card.swipe += dx
        // Resist pulling away from the edge.
        let offset = card.swipe * towardEdge > 0 ? card.swipe : card.swipe * 0.25
        card.panel.setFrameOrigin(CGPoint(x: card.home.minX + offset, y: card.home.minY))
        card.panel.alphaValue = max(0.3, 1 - abs(offset) / (card.size.width * 1.4))
    }

    static func thumbnail(_ item: CaptureItem, width: CGFloat) -> NSImage {
        let rendered = item.rendered
        let maxSide = width * 2 * 1.2
        let small = CaptureHistory.thumbnail(rendered, maxSide: maxSide) ?? rendered
        return NSImage(cgImage: small, size: NSSize(width: CGFloat(small.width) / 2, height: CGFloat(small.height) / 2))
    }
}
