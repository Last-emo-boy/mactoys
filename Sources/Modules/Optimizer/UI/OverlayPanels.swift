import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Hosts the result cards in a borderless panel at the chosen screen corner, sized to the cards.
@MainActor
final class ResultsPanelController {
    private let center: JobCenter
    private var panel: OverlayPanel?
    private var host: OverlayHostingView<AnyView>?
    private var screen: NSScreen?
    private var size: CGSize = .zero
    private var pendingShrink: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    private var observing = false
    /// Bumped on every start, so a tracking chain left from before a stop ends instead of doubling up.
    private var generation = 0
    var enabled = true { didSet { refresh() } }
    var corner: ScreenCorner = .bottomRight {
        didSet {
            guard corner != oldValue else { return }
            rebuild()
        }
    }

    init(center: JobCenter) {
        self.center = center
    }

    /// Follows the job center: shows the panel when there are cards, hides it when there are none.
    func start() {
        guard !observing else { return }
        observing = true
        generation += 1
        observe(generation)
    }

    func stop() {
        observing = false
        close()
    }

    private func observe(_ chain: Int) {
        guard observing, chain == generation else { return }
        withObservationTracking {
            _ = center.cards.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(chain) }
        }
        refresh()
    }

    private func refresh() {
        if enabled, observing, !center.cards.isEmpty {
            hideWork?.cancel()
            hideWork = nil
            show()
        } else if panel != nil, hideWork == nil {
            // Let the last card fade out first.
            let work = DispatchWorkItem { [weak self] in
                self?.close()
                self?.hideWork = nil
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func show() {
        if panel == nil {
            screen = NSScreen.underMouse ?? NSScreen.main
            let p = OverlayPanel(frame: CGRect(x: 0, y: 0, width: ResultStackView.width + 32, height: 140), interactive: true,
                                 acceptsKey: false, level: .floating)
            let host = OverlayHostingView(rootView: content())
            host.sizingOptions = []
            host.onHover = { [weak self] inside in self?.center.pointerInside = inside }
            p.contentView = host
            self.host = host
            panel = p
            size = CGSize(width: ResultStackView.width + 32, height: 140)
            place()
        }
        panel?.orderFrontRegardless()
    }

    private func content() -> AnyView {
        let alignment: Alignment = switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
        return AnyView(ResultStackView(center: center, corner: corner) { [weak self] size in
            self?.resize(size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment))
    }

    private func rebuild() {
        host?.rootView = content()
        place()
    }

    private func resize(_ new: CGSize) {
        guard new.width > 0, new.height > 0 else { return }
        pendingShrink?.cancel()
        if new.height >= size.height {
            size = new
            place()
        } else {
            // Shrink after the removal animation so leaving cards aren't clipped.
            let work = DispatchWorkItem { [weak self] in
                self?.size = new
                self?.place()
            }
            pendingShrink = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func place() {
        guard let panel else { return }
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = corner.isLeft ? vf.minX : vf.maxX - size.width
        let y = corner.isTop ? vf.maxY - size.height : vf.minY
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func close() {
        pendingShrink?.cancel()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        host = nil
        center.pointerInside = false
    }
}

/// Which part of the drop zone a drop landed on.
enum DropTarget: Equatable {
    case optimize, downscale, convert
}

/// State shared between the drop zone panel and its view.
@MainActor
@Observable
final class DropZoneModel {
    var visible = false
    var pinned = false
    var targeted: DropTarget?
    var convertFormat: ImageFormat = .jpeg
}

/// The glass drop zone that appears in a screen corner while files are dragged toward it.
@MainActor
final class DropZoneController {
    let model = DropZoneModel()
    var onDrop: ([URL], DropTarget, _ aggressive: Bool) -> Void = { _, _, _ in }
    private var panel: OverlayPanel?
    private var watchTimer: Timer?
    private var hideWork: DispatchWorkItem?

    static let size = CGSize(width: 336, height: 300)

    var isVisible: Bool { panel != nil }

    func show(on screen: NSScreen, corner: ScreenCorner, pinned: Bool) {
        hideWork?.cancel()
        hideWork = nil
        model.pinned = pinned || model.pinned && panel != nil
        let p = panel ?? makePanel()
        let vf = screen.visibleFrame
        let size = Self.size
        let x = corner.isLeft ? vf.minX + 8 : vf.maxX - size.width - 8
        let y = corner.isTop ? vf.maxY - size.height - 8 : vf.minY + 8
        p.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        model.visible = true
        if !model.pinned { watchButtons() }
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(frame: CGRect(origin: .zero, size: Self.size), interactive: true, acceptsKey: false, level: .statusBar)
        let host = OverlayHostingView(rootView: DropZoneView(model: model) { [weak self] urls, target in
            self?.drop(urls, target)
        } onClose: { [weak self] in
            self?.hide()
        })
        host.sizingOptions = []
        p.contentView = host
        panel = p
        return p
    }

    private func drop(_ urls: [URL], _ target: DropTarget) {
        let aggressive = NSEvent.modifierFlags.contains(.option)
        onDrop(urls, target, aggressive)
        model.pinned = false
        hide()
    }

    /// Hides once no mouse button is held (the drag ended), unless pinned.
    private func watchButtons() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, NSEvent.pressedMouseButtons & 1 == 0, !self.model.pinned else { return }
                self.hide()
            }
        }
    }

    /// The drag left the corner: hide unless pinned or the pointer is over the zone itself.
    func dragLeftCorner() {
        guard !model.pinned, let panel else { return }
        if panel.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { return }
        hide()
    }

    func hide() {
        watchTimer?.invalidate()
        watchTimer = nil
        guard panel != nil, hideWork == nil else { return }
        model.visible = false
        model.targeted = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panel?.contentView = nil
            self.panel = nil
            self.model.pinned = false
            self.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// The drop zone: a large "Optimize" target and two smaller ones, Downscale and Convert.
struct DropZoneView: View {
    @Bindable var model: DropZoneModel
    var onDrop: ([URL], DropTarget) -> Void
    var onClose: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            mainZone
            HStack(spacing: 10) {
                smallZone(.downscale, symbol: "arrow.down.right.and.arrow.up.left",
                          title: Text("Downscale 50 %", comment: "Optimizer drop zone target"))
                smallZone(.convert, symbol: "arrow.triangle.2.circlepath",
                          title: Text("Convert to \(model.convertFormat.title)", comment: "Optimizer drop zone target; the value is a format such as JPEG"))
            }
            Text("Hold \(Text(verbatim: "⌥").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.85))) while dropping for smaller files",
                 comment: "Optimizer drop zone hint; the value is the Option key symbol ⌥")
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                if model.pinned {
                    Button(action: onClose) {
                        Text("Close", comment: "Optimizer drop zone button").font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(12)
        .frame(width: DropZoneController.size.width - 24)
        .overlaySurface(cornerRadius: 26)
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.92)
        .opacity(model.visible ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.25), value: model.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainZone: some View {
        let on = model.targeted == .optimize
        return VStack(spacing: 8) {
            ZStack {
                Circle().fill(on ? Tint.green.color : .white.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: on ? "arrow.down" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text("Drop to optimize", comment: "Optimizer drop zone title")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Text("Images, videos and PDFs", comment: "Optimizer drop zone subtitle: what it accepts")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .background(zoneBackground(on, radius: 18))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls, .optimize)
            return true
        } isTargeted: { if $0 { model.targeted = .optimize } else if model.targeted == .optimize { model.targeted = nil } }
    }

    private func smallZone(_ target: DropTarget, symbol: String, title: Text) -> some View {
        let on = model.targeted == target
        return HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
            title.font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundStyle(.white.opacity(on ? 1 : 0.85))
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(zoneBackground(on, radius: 14))
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls, target)
            return true
        } isTargeted: { if $0 { model.targeted = target } else if model.targeted == target { model.targeted = nil } }
    }

    private func zoneBackground(_ on: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(on ? Tint.green.color.opacity(0.28) : .white.opacity(0.05))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(on ? Tint.green.color : .white.opacity(0.3),
                                  style: StrokeStyle(lineWidth: on ? 2 : 1.5, dash: on ? [] : [6, 5]))
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: on)
    }
}
