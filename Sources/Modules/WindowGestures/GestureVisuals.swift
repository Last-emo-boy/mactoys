import MacToysCore
import SwiftUI

/// A small trackpad drawing of a two-finger gesture: finger dots, the trail they leave and an
/// arrowhead. Used in the cheat sheet, the settings rows and (large, animated) in the hero.
struct GestureGlyph: View {
    enum Kind: Equatable {
        case swipe(SwipeDirection)
        /// The same swipe once more (cycling sizes).
        case swipeAgain(SwipeDirection)
        /// An L-shaped stroke: first one way, then the other.
        case corner(SwipeDirection, SwipeDirection)
        case pinchIn, pinchOut, doubleTap
    }

    let kind: Kind
    var width: CGFloat = 46
    /// 0…1: how far along its path the gesture is drawn (1 = complete).
    var progress: Double = 1
    var tint: Color = .accentColor
    /// Draw for a dark glass background regardless of the color scheme.
    var onGlass = false

    var body: some View {
        Canvas { ctx, size in
            let pad = CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)
            let radius = size.height * 0.2
            let padPath = Path(roundedRect: pad, cornerRadius: radius, style: .continuous)
            ctx.fill(padPath, with: .color(onGlass ? .white.opacity(0.08) : Color.primary.opacity(0.05)))
            ctx.stroke(padPath, with: .color(onGlass ? .white.opacity(0.22) : Color.primary.opacity(0.16)), lineWidth: 1)
            draw(in: &ctx, size: size)
        }
        .frame(width: width, height: width * 0.7)
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    private var dot: CGFloat { max(2.6, width * 0.07) }
    private var line: CGFloat { max(1.6, width * 0.045) }

    private func draw(in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let p = min(max(progress, 0), 1)
        switch kind {
        case .swipe(let d), .swipeAgain(let d):
            let (start, end) = segment(d, w: w, h: h, reach: 0.27)
            let now = lerp(start, end, p)
            trails(&ctx, path: [start, now], spread: perpendicular(d) * (h * 0.13))
            arrowhead(&ctx, at: now, direction: vector(d), size: h * 0.13)
            if case .swipeAgain = kind {
                arrowhead(&ctx, at: now - vector(d) * (h * 0.15), direction: vector(d), size: h * 0.13)
            }
            fingers(&ctx, at: now, spread: perpendicular(d) * (h * 0.13))
        case .corner(let a, let b):
            let c = CGPoint(x: w / 2, y: h / 2)
            let first = vector(a) * (a.isHorizontal ? w * 0.22 : h * 0.24)
            let second = vector(b) * (b.isHorizontal ? w * 0.26 : h * 0.26)
            let start = c - first * 0.9 - second * 0.55
            let corner = start + first * 1.6
            let end = corner + second
            let points: [CGPoint]
            if p < 0.55 { points = [start, lerp(start, corner, p / 0.55)] } else { points = [start, corner, lerp(corner, end, (p - 0.55) / 0.45)] }
            let last = points[points.count - 1]
            let heading = p < 0.55 ? vector(a) : vector(b)
            trails(&ctx, path: points, spread: .zero)
            arrowhead(&ctx, at: last, direction: heading, size: h * 0.13)
            fingers(&ctx, at: last, spread: perpendicular(p < 0.55 ? a : b) * (h * 0.12))
        case .pinchIn, .pinchOut:
            let c = CGPoint(x: w / 2, y: h / 2)
            let outer = CGVector(dx: w * 0.27, dy: h * 0.27)
            let inner = CGVector(dx: w * 0.09, dy: h * 0.09)
            let pinchingIn = kind == .pinchIn
            for sign in [-1.0, 1.0] {
                let from = c + (pinchingIn ? outer : inner) * sign
                let to = c + (pinchingIn ? inner : outer) * sign
                let now = lerp(from, to, p)
                trails(&ctx, path: [from, now], spread: .zero, single: true)
                arrowhead(&ctx, at: now, direction: (to - from).normalized, size: h * 0.12)
                fill(&ctx, circleAt: now, radius: dot)
            }
        case .doubleTap:
            let c = CGPoint(x: w / 2, y: h / 2)
            let spread = CGVector(dx: h * 0.13, dy: 0)
            for f in [c - spread, c + spread] {
                for (i, ring) in [2.1, 3.2].enumerated() {
                    let r = dot * ring * (0.7 + 0.3 * p)
                    let circle = Path(ellipseIn: CGRect(x: f.x - r, y: f.y - r, width: 2 * r, height: 2 * r))
                    ctx.stroke(circle, with: .color(tint.opacity((i == 0 ? 0.55 : 0.28) * p)), lineWidth: line * 0.8)
                }
                fill(&ctx, circleAt: f, radius: dot)
            }
        }
    }

    private func trails(_ ctx: inout GraphicsContext, path points: [CGPoint], spread: CGVector, single: Bool = false) {
        guard points.count >= 2, let first = points.first, let last = points.last else { return }
        var path = Path()
        path.addLines(points)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [tint.opacity(0), tint.opacity(0.85)]), startPoint: first, endPoint: last)
        let style = StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)
        if single || spread == .zero {
            ctx.stroke(path, with: shading, style: style)
        } else {
            for s in [-1.0, 1.0] {
                ctx.stroke(path.offsetBy(dx: spread.dx * s, dy: spread.dy * s), with: shading, style: style)
            }
        }
    }

    private func fingers(_ ctx: inout GraphicsContext, at p: CGPoint, spread: CGVector) {
        for s in [-1.0, 1.0] { fill(&ctx, circleAt: p + spread * s, radius: dot) }
    }

    private func fill(_ ctx: inout GraphicsContext, circleAt p: CGPoint, radius r: CGFloat) {
        let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(circle, with: .color(onGlass ? .white : Color(nsColor: .controlBackgroundColor)))
        ctx.stroke(circle, with: .color(tint), lineWidth: max(1.2, r * 0.45))
    }

    private func arrowhead(_ ctx: inout GraphicsContext, at p: CGPoint, direction v: CGVector, size s: CGFloat) {
        let tip = p + v * (s * 1.25)
        let back = tip - v * s
        let side = CGVector(dx: -v.dy, dy: v.dx) * (s * 0.62)
        var path = Path()
        path.move(to: back + side)
        path.addLine(to: tip)
        path.addLine(to: back - side)
        ctx.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
    }

    private func segment(_ d: SwipeDirection, w: CGFloat, h: CGFloat, reach: CGFloat) -> (CGPoint, CGPoint) {
        let c = CGPoint(x: w / 2, y: h / 2)
        let half = d.isHorizontal ? w * reach : h * reach
        return (c - vector(d) * half, c + vector(d) * (half * 0.55))
    }

    private func vector(_ d: SwipeDirection) -> CGVector {
        switch d {
        case .left: CGVector(dx: -1, dy: 0)
        case .right: CGVector(dx: 1, dy: 0)
        case .up: CGVector(dx: 0, dy: -1)
        case .down: CGVector(dx: 0, dy: 1)
        }
    }

    private func perpendicular(_ d: SwipeDirection) -> CGVector { d.isHorizontal ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0) }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// A tiny display with the tile's cells drawn in: the glyph next to tile names.
struct TileGlyph: View {
    let tile: Tile
    var size: CGFloat = 18
    var color: Color = .white

    var body: some View {
        let w = size * 1.45, h = size
        let outer = CGRect(x: 0, y: 0, width: w, height: h)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(color.opacity(0.7), lineWidth: max(1, size * 0.08))
            let cell = tile.frame(in: outer.insetBy(dx: size * 0.16, dy: size * 0.16))
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(color)
                .frame(width: max(1, cell.width), height: max(1, cell.height))
                .offset(x: cell.minX, y: cell.minY)
        }
        .frame(width: w, height: h)
        .accessibilityHidden(true)
    }
}

/// The glass target preview drawn while a swipe is in progress, in local (panel) coordinates:
/// the target, faint cells of its grid, and a label.
struct TargetPreviewView: View {
    let target: CGRect
    let title: String
    let tile: Tile?
    let symbol: String?
    var cells: [CGRect] = []
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                let r = RoundedRectangle(cornerRadius: 12, style: .continuous)
                r.fill(.white.opacity(0.04))
                    // A dark rim under the light dashes keeps the grid visible over white windows too.
                    .overlay(r.strokeBorder(.black.opacity(0.16), style: StrokeStyle(lineWidth: 2, dash: [6, 6])))
                    .overlay(r.strokeBorder(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [6, 6])))
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
            }
            shape
                .frame(width: target.width, height: target.height)
                .overlay { PreviewLabel(title: title, tile: tile, symbol: symbol) }
                .offset(x: target.minX, y: target.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var shape: some View {
        let r = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let border = contrast == .increased ? 3.0 : 2.0
        if reduceTransparency {
            r.fill(Color(red: 0.16, green: 0.3, blue: 0.52))
                .overlay(r.strokeBorder(Color.accentColor, lineWidth: border))
        } else {
            ZStack {
                Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 16))
                r.fill(LinearGradient(colors: [Color.accentColor.opacity(0.34), Color.accentColor.opacity(0.2)],
                                      startPoint: .top, endPoint: .bottom))
                r.inset(by: border + 1).strokeBorder(.white.opacity(0.3), lineWidth: 1)
                r.strokeBorder(Color.accentColor, lineWidth: border)
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        }
    }
}

/// The capsule label in the middle of a target preview: "▧ Left Half".
struct PreviewLabel: View {
    let title: String
    let tile: Tile?
    let symbol: String?

    var body: some View {
        HStack(spacing: 9) {
            if let tile {
                TileGlyph(tile: tile, size: 15)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
            }
            Text(verbatim: title).font(.system(size: 14, weight: .semibold))
            if let tile, !tile.isFill {
                Text(verbatim: tile.fraction).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.72), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

/// The pinch-to-close confirmation: a ring that fills while the pinch is held, red once armed.
struct CloseConfirmView: View {
    let progress: Double
    let armed: Bool
    let quitting: Bool
    /// The app (quit) or window (close) name.
    let name: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.24), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.001, progress))
                    .stroke(armed ? Color.red : .white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: quitting ? "power" : "xmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(armed ? Color.red : .white)
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                if !name.isEmpty {
                    Text(verbatim: name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(minWidth: 230)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.74), in: shape)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .overlay(shape.strokeBorder(armed ? Color.red.opacity(0.6) : .white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var title: LocalizedStringKey {
        switch (quitting, armed) {
        case (false, false): "Keep pinching to close"
        case (false, true): "Release to close"
        case (true, false): "Keep pinching to quit"
        case (true, true): "Release to quit"
        }
    }
}

/// A glass capsule for actions without a target frame: minimize, Dock actions, a blocked move.
struct ActionBadge: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(verbatim: title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12).opacity(0.74), in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}

// MARK: - Vector helpers

extension CGPoint {
    static func + (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x + v.dx, y: p.y + v.dy) }
    static func - (p: CGPoint, v: CGVector) -> CGPoint { CGPoint(x: p.x - v.dx, y: p.y - v.dy) }
    static func - (a: CGPoint, b: CGPoint) -> CGVector { CGVector(dx: a.x - b.x, dy: a.y - b.y) }
}

extension CGVector {
    static func * (v: CGVector, s: CGFloat) -> CGVector { CGVector(dx: v.dx * s, dy: v.dy * s) }
    var normalized: CGVector {
        let l = (dx * dx + dy * dy).squareRoot()
        return l > 0 ? CGVector(dx: dx / l, dy: dy / l) : self
    }
}
