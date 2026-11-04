import AppKit
import CoreGraphics
import MacToysCore

/// Paints annotations into a y-down context whose user space is image points.
enum MarkupRenderer {
    /// - Parameters:
    ///   - canvas: the area spotlights dim (the visible image).
    ///   - deviceScale: device pixels per point; shadows are measured in device pixels.
    ///   - hiding: items not to draw (the text being edited).
    static func draw(_ items: [MarkupItem], in ctx: CGContext, canvas: CGRect, redactions: RedactionCache?,
                     deviceScale: CGFloat, hiding: Set<MarkupItem.ID> = []) {
        var spotlightsDrawn = false
        for item in items where !hiding.contains(item.id) {
            if case .spotlight = item.shape {
                // All spotlights share one dimming layer, so two of them don't darken each other.
                if !spotlightsDrawn {
                    drawSpotlights(items.filter { !hiding.contains($0.id) }, in: ctx, canvas: canvas)
                    spotlightsDrawn = true
                }
                continue
            }
            draw(item, in: ctx, redactions: redactions, deviceScale: deviceScale)
        }
    }

    static func draw(_ item: MarkupItem, in ctx: CGContext, redactions: RedactionCache?, deviceScale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let w = item.strokeWidth
        ctx.setLineWidth(w)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        switch item.shape {
        case .arrow(let a, let b, let bend):
            dropShadow(ctx, deviceScale: deviceScale)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addPath(arrowPath(from: a, to: b, bend: bend, width: w))
            ctx.fillPath()
            ctx.endTransparencyLayer()
        case .line(let a, let b):
            dropShadow(ctx, deviceScale: deviceScale)
            ctx.move(to: a)
            ctx.addLine(to: b)
            ctx.strokePath()
        case .rectangle(let r, let filled):
            dropShadow(ctx, deviceScale: deviceScale)
            let radius = min(max(2, w * 0.9), min(r.width, r.height) / 2)
            let path = CGPath(roundedRect: filled ? r : r.insetBy(dx: w / 2, dy: w / 2),
                              cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            if filled { ctx.fillPath() } else { ctx.strokePath() }
        case .ellipse(let r, let filled):
            dropShadow(ctx, deviceScale: deviceScale)
            if filled { ctx.fillEllipse(in: r) } else { ctx.strokeEllipse(in: r.insetBy(dx: w / 2, dy: w / 2)) }
        case .text(let text):
            drawText(text, color: item.color, fontSize: item.size.fontSize, in: ctx, deviceScale: deviceScale)
        case .highlighter(let pts):
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(item.color.withAlpha(0.42).cgColor)
            ctx.setLineCap(.butt)
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        case .pencil(let pts):
            dropShadow(ctx, deviceScale: deviceScale, strength: 0.6)
            ctx.addPath(smoothPath(pts))
            ctx.strokePath()
        case .counter(let c, let n):
            drawCounter(n, at: c, diameter: item.size.counterDiameter, color: item.color, in: ctx, deviceScale: deviceScale)
        case .blur(let r):
            if let (image, px) = redactions?.blur(r) {
                ctx.clip(to: r)
                RenderContext.drawUpright(image, in: px, ctx: ctx)
            } else {
                placeholderRedaction(r, in: ctx)
            }
        case .pixelate(let r):
            if let (image, px) = redactions?.pixelate(r) {
                ctx.interpolationQuality = .none
                ctx.clip(to: r)
                RenderContext.drawUpright(image, in: px, ctx: ctx)
            } else {
                placeholderRedaction(r, in: ctx)
            }
        case .spotlight:
            break
        }
    }

    // MARK: Pieces

    /// The arrow as one filled outline: a shaft that tapers from the tail and a broad head.
    static func arrowPath(from a: CGPoint, to b: CGPoint, bend: CGFloat, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return path }
        let headLength = min(MarkupGeometry.arrowHeadLength(width: w), length * 0.6)
        let headHalf = headLength * 0.58
        let d = MarkupGeometry.tipDirection(from: a, to: b, bend: bend)
        let n = CGVector(dx: -d.dy, dy: d.dx)
        let base = CGPoint(x: b.x - d.dx * headLength, y: b.y - d.dy * headLength)
        // Shaft: sampled along the curve up to the head, wider toward the head.
        let curve = MarkupGeometry.arrowCurve(from: a, to: base, bend: bend * (1 - headLength / max(length, 1)))
        let samples = curve.count > 2 ? curve : (0...8).map { i -> CGPoint in
            let t = CGFloat(i) / 8
            return CGPoint(x: a.x + (base.x - a.x) * t, y: a.y + (base.y - a.y) * t)
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, p) in samples.enumerated() {
            let t = CGFloat(i) / CGFloat(max(1, samples.count - 1))
            let half = (w * 0.35 + w * 0.4 * t)
            let q = samples[min(samples.count - 1, i + 1)], o = samples[max(0, i - 1)]
            let tx = q.x - o.x, ty = q.y - o.y
            let len = max(hypot(tx, ty), 0.0001)
            let nx = -ty / len, ny = tx / len
            left.append(CGPoint(x: p.x + nx * half, y: p.y + ny * half))
            right.append(CGPoint(x: p.x - nx * half, y: p.y - ny * half))
        }
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        // Head: two barbs and the tip, with a slight notch at the back.
        let notch = CGPoint(x: base.x + d.dx * headLength * 0.12, y: base.y + d.dy * headLength * 0.12)
        path.addLine(to: CGPoint(x: notch.x + n.dx * w * 0.75, y: notch.y + n.dy * w * 0.75))
        path.addLine(to: CGPoint(x: base.x + n.dx * headHalf, y: base.y + n.dy * headHalf))
        path.addLine(to: b)
        path.addLine(to: CGPoint(x: base.x - n.dx * headHalf, y: base.y - n.dy * headHalf))
        path.addLine(to: CGPoint(x: notch.x - n.dx * w * 0.75, y: notch.y - n.dy * w * 0.75))
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        // A round tail.
        path.addEllipse(in: CGRect(x: a.x - w * 0.35, y: a.y - w * 0.35, width: w * 0.7, height: w * 0.7))
        return path
    }

    /// A freehand path smoothed through the midpoints of its samples.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 { path.addLine(to: first); return path }
        if pts.count == 2 { path.addLine(to: pts[1]); return path }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    static func drawText(_ t: MarkupText, color: RGBA, fontSize: CGFloat, in ctx: CGContext, deviceScale: CGFloat) {
        let font = MarkupText.font(size: fontSize)
        let rect = t.textRect(fontSize: fontSize)
        var textColor = color
        switch t.style {
        case .plain:
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * deviceScale), blur: 4 * deviceScale,
                          color: NSColor.black.withAlphaComponent(color.isLight ? 0.55 : 0.3).cgColor)
        case .outline:
            break
        case .solid, .soft:
            let frame = t.frame(fontSize: fontSize)
            let radius = min(fontSize * 0.36, frame.height / 2)
            let label = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            if t.style == .solid {
                dropShadow(ctx, deviceScale: deviceScale)
                ctx.setFillColor(color.cgColor)
                ctx.addPath(label)
                ctx.fillPath()
                textColor = color.isLight ? RGBA(red: 0.1, green: 0.1, blue: 0.11) : .white
            } else {
                ctx.setFillColor(RGBA.white.cgColor)
                ctx.addPath(label)
                ctx.fillPath()
                ctx.setFillColor(color.withAlpha(0.16).cgColor)
                ctx.addPath(label)
                ctx.fillPath()
                ctx.setStrokeColor(color.withAlpha(0.45).cgColor)
                ctx.setLineWidth(max(1, fontSize / 18))
                ctx.addPath(label)
                ctx.strokePath()
                textColor = color.isLight ? color.darkened(0.45) : color
            }
            ctx.restoreGState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin]
        if t.style == .outline {
            let outline = NSAttributedString(string: t.string, attributes: [
                .font: font, .strokeColor: (color.isLight ? NSColor.black : NSColor.white),
                .strokeWidth: 26, .foregroundColor: NSColor.clear,
            ])
            outline.draw(with: rect, options: options)
        }
        NSAttributedString(string: t.string, attributes: [.font: font, .foregroundColor: textColor.nsColor])
            .draw(with: rect, options: options)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawCounter(_ n: Int, at c: CGPoint, diameter d: CGFloat, color: RGBA, in ctx: CGContext, deviceScale: CGFloat) {
        let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        ctx.saveGState()
        dropShadow(ctx, deviceScale: deviceScale)
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.restoreGState()
        let ring = max(1.5, d / 15)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: r.insetBy(dx: ring, dy: ring))
        let font = NSFont.systemFont(ofSize: d * (n > 9 ? 0.44 : 0.52), weight: .bold)
        let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
        let text = NSAttributedString(string: "\(n)", attributes: [
            .font: rounded, .foregroundColor: color.isLight ? NSColor(white: 0.1, alpha: 1) : NSColor.white,
        ])
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Dims the canvas outside every spotlight.
    static func drawSpotlights(_ items: [MarkupItem], in ctx: CGContext, canvas: CGRect) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.beginTransparencyLayer(in: canvas, auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(canvas)
        ctx.setBlendMode(.clear)
        for item in items {
            guard case .spotlight(let r, let oval) = item.shape else { continue }
            if oval {
                ctx.fillEllipse(in: r)
            } else {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(8, r.width / 2), cornerHeight: min(8, r.height / 2), transform: nil))
                ctx.fillPath()
            }
        }
        ctx.endTransparencyLayer()
    }

    /// Stand-in for a region whose pixels aren't available (previews without an image).
    private static func placeholderRedaction(_ r: CGRect, in ctx: CGContext) {
        ctx.setFillColor(NSColor(white: 0.5, alpha: 0.6).cgColor)
        ctx.fill(r)
    }

    private static func dropShadow(_ ctx: CGContext, deviceScale: CGFloat, strength: CGFloat = 1) {
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * deviceScale), blur: 4 * deviceScale,
                      color: NSColor.black.withAlphaComponent(0.32 * strength).cgColor)
    }
}

extension RGBA {
    /// Relative luminance above the middle: white, yellow — dark text reads better on it.
    var isLight: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.62 }

    func darkened(_ amount: Double) -> RGBA {
        RGBA(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount), alpha: alpha)
    }
}

/// Turns a capture and its document into the finished image.
enum Compositor {
    /// The annotated, cropped capture — then framed when beautify is on, then 1× when `retina` is off.
    static func render(base: CGImage, document doc: MarkupDocument, redactions: RedactionCache?, retina: Bool = true) -> CGImage? {
        guard let annotated = annotated(base: base, document: doc, redactions: redactions) else { return nil }
        var result = annotated
        let content = doc.contentRect
        if let style = doc.beautify {
            guard let framed = Beautifier.render(annotated, size: content.size, style: style, scale: doc.scale) else { return nil }
            result = framed
            if style.aspect.pixelWidth != nil { return result }
        }
        if !retina, doc.scale > 1.01 {
            return downscaled(result, by: 1 / doc.scale) ?? result
        }
        return result
    }

    /// The capture with its annotations, cropped to the document's content rect, at the capture's scale.
    static func annotated(base: CGImage, document doc: MarkupDocument, redactions: RedactionCache?) -> CGImage? {
        let content = doc.contentRect
        let px = AreaGeometry.pixelRect(content, scale: doc.scale)
        guard let ctx = RenderContext.make(width: Int(px.width), height: Int(px.height), scale: doc.scale) else { return nil }
        ctx.translateBy(x: -content.minX, y: -content.minY)
        RenderContext.drawUpright(base, in: doc.imageBounds, ctx: ctx)
        MarkupRenderer.draw(doc.items, in: ctx, canvas: doc.imageBounds, redactions: redactions, deviceScale: doc.scale)
        return ctx.makeImage()
    }

    static func downscaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * factor).rounded())), h = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
