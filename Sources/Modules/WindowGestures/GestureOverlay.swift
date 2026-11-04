import AppKit
import MacToysCore
import SwiftUI

/// What the gesture overlay shows, in the panel's local (top-left) coordinates.
enum OverlayContent: Equatable {
    case none
    /// The window's destination, with the faint cells of its grid.
    case target(frame: CGRect, title: String, tile: Tile?, symbol: String?, cells: [CGRect])
    /// The pinch-to-close ring, centered at `center`.
    case confirm(center: CGPoint, armed: Bool, quitting: Bool, name: String)
    /// A capsule for actions without a frame (minimize, Dock actions, a blocked move).
    case badge(center: CGPoint, title: String, symbol: String)

    /// Identity for transitions: the same kind of content morphs, a new kind cross-fades.
    var kind: Int {
        switch self {
        case .none: 0
        case .target: 1
        case .confirm: 2
        case .badge: 3
        }
    }
}

@MainActor
@Observable
final class OverlayModel {
    var content = OverlayContent.none
    /// The close ring's fill, animated separately from the content.
    var progress: Double = 0
}

/// The overlay's root view: the content over the whole display, camera housing included.
struct GestureOverlayView: View {
    let model: OverlayModel

    var body: some View {
        OverlayContentView(model: model)
            .ignoresSafeArea()      // the camera housing must not shift the preview on notched displays
    }
}

/// What the overlay shows, in display coordinates.
struct OverlayContentView: View {
    let model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch model.content {
            case .none:
                Color.clear
            case let .target(frame, title, tile, symbol, cells):
                TargetPreviewView(target: frame, title: title, tile: tile, symbol: symbol, cells: cells)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            case let .confirm(center, armed, quitting, name):
                CloseConfirmView(progress: model.progress, armed: armed, quitting: quitting, name: name)
                    .position(center)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            case let .badge(center, title, symbol):
                ActionBadge(title: title, symbol: symbol)
                    .position(center)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One click-through panel, moved to whichever display the gesture's target is on, showing the
/// live target preview, the close confirmation or an action badge. Content changes morph with a
/// short spring; Reduce Motion cross-fades instead.
@MainActor
final class GestureOverlay {
    private var panel: OverlayPanel?
    private let model = OverlayModel()
    private var screenFrame = CGRect.null
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    var isVisible: Bool { panel?.isVisible == true && model.content != .none }

    /// Shows `content` on the display `screen` (top-left coordinates); content coordinates are global
    /// top-left and are converted to the panel here.
    func show(_ content: OverlayContent, on screen: CGRect) {
        hideWork?.cancel()
        generation += 1
        let p = panel ?? makePanel()
        let moved = screen != screenFrame
        if moved {
            screenFrame = screen
            p.setFrame(ScreenGeometry.toCocoa(screen), display: false)
        }
        let local = Self.localize(content, in: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let appearing = !p.isVisible || moved || model.content == .none
        if appearing {
            model.content = .none
            p.alphaValue = 1
            p.orderFrontRegardless()
        }
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : appearing ? .smooth(duration: 0.2) : .snappy(duration: 0.22)) {
            model.content = local
        }
    }

    /// Restarts the close ring and fills it over `duration` seconds.
    func runProgress(over duration: TimeInterval) {
        model.progress = 0
        withAnimation(.linear(duration: max(0.01, duration))) { model.progress = 1 }
    }

    /// Fades out (after `delay` seconds).
    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        generation += 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.model.content = .none }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                guard let self, self.generation == token else { return }
                self.panel?.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Shows a badge for a moment.
    func flash(_ content: OverlayContent, on screen: CGRect, for seconds: TimeInterval = 0.9) {
        show(content, on: screen)
        hide(after: seconds)
    }

    func tearDown() {
        hideWork?.cancel()
        generation += 1
        model.content = .none
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        screenFrame = .null
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(frame: .zero, level: .statusBar)
        p.setContent(GestureOverlayView(model: model))
        panel = p
        return p
    }

    nonisolated static func localize(_ content: OverlayContent, in screen: CGRect) -> OverlayContent {
        let dx = -screen.minX, dy = -screen.minY
        switch content {
        case .none:
            return .none
        case let .target(frame, title, tile, symbol, cells):
            return .target(frame: frame.offsetBy(dx: dx, dy: dy), title: title, tile: tile, symbol: symbol,
                           cells: cells.map { $0.offsetBy(dx: dx, dy: dy) })
        case let .confirm(center, armed, quitting, name):
            return .confirm(center: CGPoint(x: center.x + dx, y: center.y + dy), armed: armed, quitting: quitting, name: name)
        case let .badge(center, title, symbol):
            return .badge(center: CGPoint(x: center.x + dx, y: center.y + dy), title: title, symbol: symbol)
        }
    }
}
