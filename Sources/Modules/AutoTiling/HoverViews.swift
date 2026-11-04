import AppKit
import MacToysCore
import SwiftUI

/// The glass pill shown above a tiled window's title bar: make main, float or tile, send to the
/// next display.
struct QuickActionPillView: View {
    let isMain: Bool
    let isFloating: Bool
    let canSendToDisplay: Bool
    var onMakeMain: () -> Void = {}
    var onToggleFloat: () -> Void = {}
    var onSendToDisplay: () -> Void = {}
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let buttonSize = CGSize(width: 32, height: 26)
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 4

    /// The pill's size with this many buttons.
    static func size(buttons: Int) -> CGSize {
        CGSize(width: CGFloat(buttons) * buttonSize.width + CGFloat(max(buttons - 1, 0)) * spacing + padding * 2,
               height: buttonSize.height + padding * 2)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            PillButton(symbol: "star.fill", help: Text("Make main window", comment: "Auto Tiling quick action above a window"),
                       disabled: isMain || isFloating, action: onMakeMain)
            PillButton(symbol: isFloating ? "rectangle.split.2x2" : "macwindow.on.rectangle",
                       help: isFloating ? Text("Tile this window", comment: "Auto Tiling quick action above a window")
                                        : Text("Float this window", comment: "Auto Tiling quick action above a window"),
                       action: onToggleFloat)
            if canSendToDisplay {
                PillButton(symbol: "rectangle.portrait.and.arrow.right",
                           help: Text("Send to the next display", comment: "Auto Tiling quick action above a window"),
                           disabled: isFloating, action: onSendToDisplay)
            }
        }
        .padding(Self.padding)
        // A dark base keeps the icons legible over light title bars and the title text below.
        .background(Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(reduceTransparency ? 1 : 0.86)))
        // The rim sits inside the glass so it follows the glass's own lensing of the content.
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .glassEffect(.regular, in: .capsule)
        .clipShape(.capsule)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
        .scaleEffect(shown || reduceMotion ? 1 : 0.9, anchor: .top)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) { shown = true } }
    }
}

private struct PillButton: View {
    let symbol: String
    let help: Text
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(disabled ? 0.35 : 0.92))
                .frame(width: QuickActionPillView.buttonSize.width, height: QuickActionPillView.buttonSize.height)
                .background(Capsule().fill(.white.opacity(hovering && !disabled ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The tile a dragged window will swap with (or the display it will move to). The tint and
/// outline leave out the dragged window itself, and the label moves to the part of the tile the
/// window doesn't cover.
struct SwapTargetView: View {
    enum Kind: Equatable {
        case swap(app: String)
        case move(display: String)
    }

    let kind: Kind
    var radius: CGFloat = WindowCorners.titlebarRadius
    /// The dragged window, in this view's coordinates.
    var cutout: CGRect?
    var cutoutRadius: CGFloat = WindowCorners.titlebarRadius
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3))
                    .mask(Cutout(hole: cutout, radius: cutoutRadius).fill(style: FillStyle(eoFill: true)))
                labelPill
                    .position(Self.labelCenter(in: bounds, avoiding: cutout))
            }
        }
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.2)) { shown = true } }
    }

    private var labelPill: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            label.font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // A dark base keeps the glass legible over light windows.
        .background(Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(reduceTransparency ? 1 : 0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .glassEffect(.regular, in: .capsule)
        .clipShape(.capsule)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    /// The center of the largest part of the tile the dragged window leaves free (above, below,
    /// left or right of it), or the tile's center when nothing is roomy enough.
    static func labelCenter(in bounds: CGRect, avoiding hole: CGRect?, minimum: CGSize = CGSize(width: 220, height: 56)) -> CGPoint {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let atCenter = CGRect(x: center.x - minimum.width / 2, y: center.y - minimum.height / 2,
                              width: minimum.width, height: minimum.height)
        guard let hole, hole.intersects(atCenter) else { return center }
        let bands = [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: hole.minY - bounds.minY),
            CGRect(x: bounds.minX, y: hole.maxY, width: bounds.width, height: bounds.maxY - hole.maxY),
            CGRect(x: bounds.minX, y: bounds.minY, width: hole.minX - bounds.minX, height: bounds.height),
            CGRect(x: hole.maxX, y: bounds.minY, width: bounds.maxX - hole.maxX, height: bounds.height),
        ].filter { $0.width >= minimum.width && $0.height >= minimum.height }
        guard let best = bands.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return center }
        return CGPoint(x: best.midX, y: best.midY)
    }

    private var symbol: String {
        switch kind {
        case .swap: "arrow.left.arrow.right"
        case .move: "rectangle.portrait.and.arrow.right"
        }
    }

    private var label: Text {
        switch kind {
        case .swap(let app): Text("Swap with \(app)", comment: "Auto Tiling: drop a dragged window here to swap; %@ is an app name")
        case .move(let display): Text("Move to \(display)", comment: "Auto Tiling: drop a dragged window to move it to the display named %@")
        }
    }
}

/// The whole rectangle except a rounded hole.
private struct Cutout: Shape {
    let hole: CGRect?
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if let hole { p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous) }
        return p
    }
}

/// The live target's state, updated while the window moves without rebuilding the panel.
@MainActor @Observable
final class SwapTargetModel {
    var kind = SwapTargetView.Kind.swap(app: "")
    var radius = WindowCorners.titlebarRadius
    var cutout: CGRect?
    var cutoutRadius = WindowCorners.titlebarRadius
    /// Changes with every new target so it fades in again.
    var generation = 0
}

struct SwapTargetHost: View {
    let model: SwapTargetModel

    var body: some View {
        SwapTargetView(kind: model.kind, radius: model.radius, cutout: model.cutout, cutoutRadius: model.cutoutRadius)
            .id(model.generation)
    }
}
