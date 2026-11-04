import CoreGraphics

/// How the camera picture fills a view: aspect-filled, zoomed around a chosen center, never
/// showing past the edges of the camera picture. Used to lay out the live preview layer and to
/// crop photos, so a photo shows exactly what the mirror showed.
///
/// All rects here are normalized to the camera picture with a top-left origin.
struct MirrorFraming: Equatable, Sendable {
    var zoom: CGFloat
    var center: CGPoint

    static let zoomRange: ClosedRange<CGFloat> = 1...3
    static let standard = MirrorFraming(zoom: 1, center: CGPoint(x: 0.5, y: 0.5))

    init(zoom: CGFloat, center: CGPoint) {
        self.zoom = zoom
        self.center = center
    }

    private var clampedZoom: CGFloat { min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound) }

    /// The part of the camera picture a view of `view` size shows.
    func visibleRect(source: CGSize, view: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, view.width > 0, view.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let sourceAspect = source.width / source.height
        let viewAspect = view.width / view.height
        // Aspect fill at zoom 1: one dimension shows all of the picture, the other is cut.
        var w: CGFloat = 1, h: CGFloat = 1
        if viewAspect > sourceAspect { h = sourceAspect / viewAspect } else { w = viewAspect / sourceAspect }
        w /= clampedZoom
        h /= clampedZoom
        let cx = min(max(center.x, w / 2), 1 - w / 2)
        let cy = min(max(center.y, h / 2), 1 - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Where the whole camera picture goes, in view points with a top-left origin, so that
    /// `visibleRect` exactly covers the view. It always has the picture's aspect ratio.
    func layerFrame(source: CGSize, view: CGSize) -> CGRect {
        let v = visibleRect(source: source, view: view)
        let width = view.width / v.width
        let height = view.height / v.height
        return CGRect(x: -v.minX * width, y: -v.minY * height, width: width, height: height)
    }

    /// The same framing with the center moved where it can actually go (edges clamp it).
    func clamped(source: CGSize, view: CGSize) -> MirrorFraming {
        let v = visibleRect(source: source, view: view)
        return MirrorFraming(zoom: clampedZoom, center: CGPoint(x: v.midX, y: v.midY))
    }

    /// Follows a drag of `delta` points (top-left coordinates) across the view: the picture moves
    /// with the pointer. In a mirrored view horizontal movement is reversed in picture space.
    func panned(by delta: CGSize, source: CGSize, view: CGSize, mirrored: Bool) -> MirrorFraming {
        guard view.width > 0, view.height > 0 else { return self }
        let v = visibleRect(source: source, view: view)
        var dx = -delta.width / view.width * v.width
        if mirrored { dx = -dx }
        let dy = -delta.height / view.height * v.height
        return MirrorFraming(zoom: clampedZoom, center: CGPoint(x: v.midX + dx, y: v.midY + dy))
            .clamped(source: source, view: view)
    }

    /// Changes the zoom by `factor`, keeping the center.
    func zoomed(by factor: CGFloat, source: CGSize, view: CGSize) -> MirrorFraming {
        let z = min(max(clampedZoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        return MirrorFraming(zoom: z, center: center).clamped(source: source, view: view)
    }

    /// The pixel rect of a photo of `pixels` size that the view shows (top-left origin, integral).
    func cropRect(pixels: CGSize, view: CGSize) -> CGRect {
        let v = visibleRect(source: pixels, view: view)
        let r = CGRect(x: v.minX * pixels.width, y: v.minY * pixels.height,
                       width: v.width * pixels.width, height: v.height * pixels.height)
        return r.integral.intersection(CGRect(origin: .zero, size: pixels))
    }
}

/// Size rules for the floating mirror window.
enum FloatingGeometry {
    /// The shortest side a floating mirror may have.
    static let minSide: CGFloat = 120
    /// The largest share of the screen's visible area a floating mirror may cover, per side.
    static let maxScreenFraction: CGFloat = 0.7
    static let defaultWidth: CGFloat = 260

    /// Width divided by height for a shape.
    static func ratio(shape: MirrorShape, aspect: MirrorAspect) -> CGFloat {
        shape == .circle ? 1 : aspect.ratio
    }

    /// The largest size allowed on a screen whose visible area is `visible`.
    static func maxSize(in visible: CGSize, ratio: CGFloat) -> CGSize {
        var w = visible.width * maxScreenFraction
        var h = w / ratio
        let maxH = visible.height * maxScreenFraction
        if h > maxH { h = maxH; w = h * ratio }
        return CGSize(width: w, height: h)
    }

    /// The smallest size: the shorter side is `minSide`.
    static func minSize(ratio: CGFloat) -> CGSize {
        ratio >= 1 ? CGSize(width: minSide * ratio, height: minSide) : CGSize(width: minSide, height: minSide / ratio)
    }

    /// Locks `size` to the shape's ratio (keeping its width, or its height for portrait shapes)
    /// and clamps it between the minimum and the screen maximum.
    static func constrain(_ size: CGSize, shape: MirrorShape, aspect: MirrorAspect, visible: CGSize) -> CGSize {
        let ratio = ratio(shape: shape, aspect: aspect)
        let lo = minSize(ratio: ratio)
        let hi = maxSize(in: visible, ratio: ratio)
        var w = ratio >= 1 ? size.width : size.height * ratio
        w = min(max(w, lo.width), max(lo.width, hi.width))
        return CGSize(width: w.rounded(), height: (w / ratio).rounded())
    }

    /// A frame kept fully inside `visible` (moved, never resized).
    static func fit(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var r = frame
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        if r.minY < visible.minY { r.origin.y = visible.minY }
        return r
    }

    /// The first floating frame: top right of the visible area, 20 pt from the edges.
    static func defaultFrame(in visible: CGRect, shape: MirrorShape, aspect: MirrorAspect) -> CGRect {
        let size = constrain(CGSize(width: defaultWidth, height: defaultWidth), shape: shape, aspect: aspect, visible: visible.size)
        return CGRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20,
                      width: size.width, height: size.height)
    }

    /// Corner radius of the window outline (concentric with the hover controls inside it).
    static func cornerRadius(shape: MirrorShape, size: CGSize) -> CGFloat {
        let short = min(size.width, size.height)
        switch shape {
        case .circle: return short / 2
        case .rounded: return min(32, short * 0.14)
        case .rectangle: return 6
        }
    }
}
