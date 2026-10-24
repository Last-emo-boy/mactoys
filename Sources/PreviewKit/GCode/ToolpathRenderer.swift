import CoreGraphics
import Foundation

/// How a toolpath is drawn.
public struct ToolpathStyle: Sendable, Equatable {
    public enum View: String, Codable, CaseIterable, Sendable {
        case isometric, top

        public var title: String { self == .isometric ? "Isometric" : "Top" }
    }

    public var view: View
    public var showTravel: Bool
    public var darkBackground: Bool

    public init(view: View = .isometric, showTravel: Bool = false, darkBackground: Bool = true) {
        self.view = view
        self.showTravel = showTravel
        self.darkBackground = darkBackground
    }
}

/// Draws a `GCodeToolpath` into a bitmap: extrusions colored by height over a bed grid.
public enum ToolpathRenderer {
    /// Height palette, bottom to top.
    static let palette: [(CGFloat, CGFloat, CGFloat)] = [
        (0.24, 0.43, 0.94), (0.18, 0.77, 0.71), (0.64, 0.88, 0.28), (0.96, 0.78, 0.27), (0.95, 0.54, 0.19),
    ]

    static func color(at t: CGFloat, alpha: CGFloat = 1) -> CGColor {
        let x = max(0, min(1, t)) * CGFloat(palette.count - 1)
        let i = min(palette.count - 2, Int(x))
        let f = x - CGFloat(i)
        let a = palette[i], b = palette[i + 1]
        return CGColor(srgbRed: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: alpha)
    }

    /// Projects a point to 2D (y up) for the chosen view.
    static func project(_ x: Float, _ y: Float, _ z: Float, view: ToolpathStyle.View) -> CGPoint {
        switch view {
        case .top:
            return CGPoint(x: CGFloat(x), y: CGFloat(y))
        case .isometric:
            // Seen from the front left, 30° above the bed.
            let u = (Double(x) - Double(y)) * 0.70710678
            let v = (Double(x) + Double(y)) * 0.70710678
            return CGPoint(x: u, y: v * 0.5 + Double(z) * 0.8660254)
        }
    }

    public static func render(_ path: GCodeToolpath, size: CGSize, style: ToolpathStyle = ToolpathStyle()) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = ImageUtil.context(width: w, height: h) else { return nil }
        let bg = style.darkBackground ? CGColor(srgbRed: 0.086, green: 0.094, blue: 0.114, alpha: 1)
                                      : CGColor(srgbRed: 0.965, green: 0.969, blue: 0.976, alpha: 1)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let bounds = path.bounds else { return ctx.makeImage() }

        // Fit the projected object (and its bed footprint) into the image.
        let pad: Float = max(2, max(bounds.max.x - bounds.min.x, bounds.max.y - bounds.min.y) * 0.08)
        let lo = bounds.min - SIMD3(pad, pad, 0), hi = bounds.max + SIMD3(pad, pad, 0)
        var minP = CGPoint(x: CGFloat.greatestFiniteMagnitude, y: .greatestFiniteMagnitude)
        var maxP = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: -.greatestFiniteMagnitude)
        for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
            let p = project(x, y, z, view: style.view)
            minP = CGPoint(x: min(minP.x, p.x), y: min(minP.y, p.y))
            maxP = CGPoint(x: max(maxP.x, p.x), y: max(maxP.y, p.y))
        } } }
        let margin = CGFloat(min(w, h)) * 0.06
        let spanX = max(maxP.x - minP.x, 1e-3), spanY = max(maxP.y - minP.y, 1e-3)
        let scale = min((CGFloat(w) - 2 * margin) / spanX, (CGFloat(h) - 2 * margin) / spanY)
        let offX = (CGFloat(w) - spanX * scale) / 2 - minP.x * scale
        let offY = (CGFloat(h) - spanY * scale) / 2 - minP.y * scale
        func screen(_ k: Int) -> CGPoint {
            let p = project(path.xs[k], path.ys[k], path.zs[k], view: style.view)
            return CGPoint(x: p.x * scale + offX, y: p.y * scale + offY)
        }

        drawGrid(ctx, lo: lo, hi: hi, view: style.view, dark: style.darkBackground) { p in
            CGPoint(x: p.x * scale + offX, y: p.y * scale + offY)
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let zSpan = max(bounds.max.z - bounds.min.z, 1e-3)
        let width = max(0.5, min(3.2, 0.42 * scale * (style.view == .top ? 1 : 0.9)))
        let minStep: CGFloat = 0.45            // merge sub-pixel segments
        var bucket = -1
        var current = CGMutablePath()
        var last = CGPoint.zero
        var drawing = false
        var segmentsInPath = 0

        func flush() {
            guard !current.isEmpty, bucket >= 0 else { return }
            ctx.addPath(current)
            ctx.setStrokeColor(color(at: CGFloat(bucket) / 47))
            ctx.setLineWidth(width)
            ctx.strokePath()
            current = CGMutablePath()
            segmentsInPath = 0
        }

        if style.showTravel {
            let travel = CGMutablePath()
            for k in 1..<path.kinds.count where !path.isWorking(path.kinds[k]) {
                travel.move(to: screen(k - 1))
                travel.addLine(to: screen(k))
            }
            ctx.addPath(travel)
            ctx.setStrokeColor(style.darkBackground ? CGColor(gray: 1, alpha: 0.18) : CGColor(gray: 0, alpha: 0.18))
            ctx.setLineWidth(0.6)
            ctx.strokePath()
        }

        for k in 1..<max(1, path.kinds.count) {
            guard path.isWorking(path.kinds[k]) else { drawing = false; continue }
            let zt = (path.zs[k] - bounds.min.z) / zSpan
            let b = Int((zt * 47).rounded())
            if b != bucket || segmentsInPath > 4000 {
                flush()
                bucket = b
                drawing = false
            }
            let end = screen(k)
            if !drawing {
                last = screen(k - 1)
                current.move(to: last)
                drawing = true
            }
            if abs(end.x - last.x) + abs(end.y - last.y) < minStep && k + 1 < path.kinds.count && path.isWorking(path.kinds[k + 1]) {
                continue
            }
            current.addLine(to: end)
            last = end
            segmentsInPath += 1
        }
        flush()
        return ctx.makeImage()
    }

    /// Bed grid under the object (10 mm, or 50 mm for large prints).
    private static func drawGrid(_ ctx: CGContext, lo: SIMD3<Float>, hi: SIMD3<Float>, view: ToolpathStyle.View, dark: Bool,
                                 map: (CGPoint) -> CGPoint) {
        let extent = max(hi.x - lo.x, hi.y - lo.y)
        let step: Float = extent > 400 ? 50 : (extent > 120 ? 20 : (extent > 30 ? 10 : 5))
        let z = lo.z
        let grid = CGMutablePath()
        var x = (lo.x / step).rounded(.down) * step
        while x <= hi.x {
            if x >= lo.x {
                grid.move(to: map(project(x, lo.y, z, view: view)))
                grid.addLine(to: map(project(x, hi.y, z, view: view)))
            }
            x += step
        }
        var y = (lo.y / step).rounded(.down) * step
        while y <= hi.y {
            if y >= lo.y {
                grid.move(to: map(project(lo.x, y, z, view: view)))
                grid.addLine(to: map(project(hi.x, y, z, view: view)))
            }
            y += step
        }
        ctx.addPath(grid)
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.07) : CGColor(gray: 0, alpha: 0.08))
        ctx.setLineWidth(1)
        ctx.strokePath()
        let outline = CGMutablePath()
        outline.addLines(between: [map(project(lo.x, lo.y, z, view: view)), map(project(hi.x, lo.y, z, view: view)),
                                   map(project(hi.x, hi.y, z, view: view)), map(project(lo.x, hi.y, z, view: view))])
        outline.closeSubpath()
        ctx.addPath(outline)
        ctx.setStrokeColor(dark ? CGColor(gray: 1, alpha: 0.16) : CGColor(gray: 0, alpha: 0.16))
        ctx.strokePath()
    }
}
