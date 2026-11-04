import AppKit
import CoreGraphics
import Foundation
import MacToysCore

/// The background frame around a capture: padding, a backdrop, rounded corners and a shadow.
public struct BeautifyStyle: Codable, Equatable, Sendable {
    public var backdrop: Backdrop = .preset(.dusk)
    /// Space around the capture, in points.
    public var padding: Double = 56
    /// Corner radius of the capture, in points (clamped to half its short side).
    public var cornerRadius: Double = 10
    /// Shadow strength, 0…1.
    public var shadow: Double = 0.6
    public var alignment: BeautifyAlignment = .center
    public var aspect: AspectPreset = .auto

    public init() {}
}

/// What fills the frame behind the capture.
public enum Backdrop: Codable, Equatable, Sendable, Hashable {
    /// Transparent (padding and shadow only).
    case none
    case solid(RGBA)
    case preset(BackdropPreset)
}

/// Generated backdrops (no bundled images): smooth gradients and soft, wallpaper-like color fields.
public enum BackdropPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case dusk, ocean, sunset, meadow, lavender, citrus, aurora, bloom, sky, midnight, graphite, paper
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .dusk: String(localized: "Dusk", comment: "Background name")
        case .ocean: String(localized: "Ocean", comment: "Background name")
        case .sunset: String(localized: "Sunset", comment: "Background name")
        case .meadow: String(localized: "Meadow", comment: "Background name")
        case .lavender: String(localized: "Lavender", comment: "Background name")
        case .citrus: String(localized: "Citrus", comment: "Background name")
        case .aurora: String(localized: "Aurora", comment: "Background name")
        case .bloom: String(localized: "Bloom", comment: "Background name")
        case .sky: String(localized: "Sky", comment: "Background name")
        case .midnight: String(localized: "Midnight", comment: "Background name")
        case .graphite: String(localized: "Graphite", comment: "Background name")
        case .paper: String(localized: "Paper", comment: "Background name")
        }
    }

    enum Paint {
        /// Colors along a line at `angle` degrees (0 = left to right, 90 = top to bottom).
        case linear([RGBA], angle: CGFloat)
        /// A base color with soft color blobs at relative positions (x, y, radius as a fraction of the diagonal).
        case field(RGBA, [(RGBA, CGFloat, CGFloat, CGFloat)])
    }

    var paint: Paint {
        func c(_ hex: String) -> RGBA { RGBA(hex: hex) ?? .black }
        switch self {
        case .dusk: return .linear([c("#17215C"), c("#3D2B8F"), c("#99408A"), c("#E08A6B")], angle: 35)
        case .ocean: return .linear([c("#0F3D7A"), c("#1279C6"), c("#3FC3E0")], angle: 60)
        case .sunset: return .linear([c("#FF5E62"), c("#FF9966"), c("#FFC371")], angle: 25)
        case .meadow: return .linear([c("#0B8457"), c("#43C59E"), c("#C8F0A6")], angle: 45)
        case .lavender: return .linear([c("#B993D6"), c("#8CA6DB"), c("#E3D4F5")], angle: 135)
        case .citrus: return .linear([c("#F7B733"), c("#FC8C3A"), c("#F4555E")], angle: 70)
        case .aurora:
            return .field(c("#0B1E3F"), [(c("#1FD1A0"), 0.15, 0.2, 0.55), (c("#5B5CE6"), 0.85, 0.3, 0.6),
                                        (c("#C13FD0"), 0.55, 1.0, 0.55)])
        case .bloom:
            return .field(c("#FCE3EC"), [(c("#FF7AA8"), 0.1, 0.9, 0.6), (c("#FFB36B"), 0.9, 0.85, 0.55),
                                        (c("#A88BFF"), 0.75, 0.05, 0.55)])
        case .sky:
            return .field(c("#DDEBFF"), [(c("#7FB8FF"), 0.0, 0.0, 0.7), (c("#FFFFFF"), 0.8, 0.9, 0.6),
                                        (c("#A6E1FF"), 1.0, 0.2, 0.5)])
        case .midnight:
            return .field(c("#07070C"), [(c("#25307A"), 0.2, 0.15, 0.6), (c("#4A1F5E"), 0.9, 0.95, 0.6)])
        case .graphite: return .linear([c("#3A3A40"), c("#1C1C21")], angle: 90)
        case .paper: return .linear([c("#F5F3EE"), c("#E7E3DA")], angle: 90)
        }
    }

    /// Whether dark text or light text reads on it (for labels drawn over it).
    var isDark: Bool {
        switch self {
        case .sky, .paper, .bloom, .lavender, .citrus, .sunset, .meadow: false
        default: true
        }
    }
}

/// Where the capture sits when the frame has more room on one side (an aspect preset).
public enum BeautifyAlignment: String, Codable, CaseIterable, Sendable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    public var id: String { rawValue }

    /// Horizontal and vertical position of the capture in the free space, 0…1.
    var fractions: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: (0, 0)
        case .top: (0.5, 0)
        case .topRight: (1, 0)
        case .left: (0, 0.5)
        case .center: (0.5, 0.5)
        case .right: (1, 0.5)
        case .bottomLeft: (0, 1)
        case .bottom: (0.5, 1)
        case .bottomRight: (1, 1)
        }
    }

    var title: String {
        switch self {
        case .topLeft: String(localized: "Top left", comment: "Position of the screenshot in its background frame")
        case .top: String(localized: "Top", comment: "Position of the screenshot in its background frame")
        case .topRight: String(localized: "Top right", comment: "Position of the screenshot in its background frame")
        case .left: String(localized: "Left", comment: "Position of the screenshot in its background frame")
        case .center: String(localized: "Center", comment: "Position of the screenshot in its background frame")
        case .right: String(localized: "Right", comment: "Position of the screenshot in its background frame")
        case .bottomLeft: String(localized: "Bottom left", comment: "Position of the screenshot in its background frame")
        case .bottom: String(localized: "Bottom", comment: "Position of the screenshot in its background frame")
        case .bottomRight: String(localized: "Bottom right", comment: "Position of the screenshot in its background frame")
        }
    }
}

/// Output shapes for the frame.
public enum AspectPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto, square, fourThree, sixteenNine, xPost
    public var id: String { rawValue }

    /// Width ÷ height, or nil to follow the capture.
    var ratio: CGFloat? {
        switch self {
        case .auto: nil
        case .square: 1
        case .fourThree: 4.0 / 3.0
        case .sixteenNine, .xPost: 16.0 / 9.0
        }
    }

    /// A fixed output width in pixels (the X post size, 1200 × 675).
    var pixelWidth: CGFloat? { self == .xPost ? 1200 : nil }

    var title: String {
        switch self {
        case .auto: String(localized: "Auto", comment: "Background frame shape: follow the screenshot")
        case .square: "1:1"
        case .fourThree: "4:3"
        case .sixteenNine: "16:9"
        case .xPost: String(localized: "X post", comment: "Background frame shape: an image for a post on X (Twitter), 1200 × 675")
        }
    }
}

/// Where everything goes in a beautified image. Pure, for tests and for mapping clicks in the editor.
struct BeautifyLayout: Equatable {
    /// The whole frame, in points.
    var canvas: CGSize
    /// The capture inside the frame, in points.
    var content: CGRect
    var cornerRadius: CGFloat
    /// Output pixels per point.
    var pixelScale: CGFloat

    var pixelSize: (width: Int, height: Int) {
        (Int((canvas.width * pixelScale).rounded()), Int((canvas.height * pixelScale).rounded()))
    }

    /// - Parameters:
    ///   - size: the capture (after cropping), in points.
    ///   - scale: the capture's pixels per point.
    static func make(content size: CGSize, style: BeautifyStyle, scale: CGFloat) -> BeautifyLayout {
        let pad = CGFloat(max(0, style.padding))
        var canvas = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)
        if let ratio = style.aspect.ratio, canvas.height > 0 {
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        let free = CGSize(width: canvas.width - size.width - pad * 2, height: canvas.height - size.height - pad * 2)
        let f = style.alignment.fractions
        let content = CGRect(x: pad + free.width * f.x, y: pad + free.height * f.y, width: size.width, height: size.height)
        let radius = min(CGFloat(max(0, style.cornerRadius)), min(size.width, size.height) / 2)
        var pixelScale = scale
        if let width = style.aspect.pixelWidth, canvas.width > 0 { pixelScale = width / canvas.width }
        return BeautifyLayout(canvas: canvas, content: content, cornerRadius: radius, pixelScale: pixelScale)
    }

    /// The shadow under the capture for a strength 0…1, in points.
    static func shadow(strength: Double) -> (blur: CGFloat, offset: CGFloat, alpha: CGFloat) {
        let s = CGFloat(min(max(strength, 0), 1))
        return (blur: 10 + 34 * s, offset: 4 + 12 * s, alpha: 0.5 * s)
    }
}

/// Paints backdrops and framed captures with Core Graphics.
enum Beautifier {
    /// Fills `rect` of a y-down context with a backdrop.
    static func paint(_ backdrop: Backdrop, in ctx: CGContext, rect: CGRect) {
        switch backdrop {
        case .none: break
        case .solid(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(rect)
        case .preset(let p): paint(p, in: ctx, rect: rect)
        }
    }

    static func paint(_ preset: BackdropPreset, in ctx: CGContext, rect: CGRect) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: rect)
        switch preset.paint {
        case .linear(let colors, let angle):
            guard let gradient = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
            let a = angle * .pi / 180
            let half = (abs(cos(a)) * rect.width + abs(sin(a)) * rect.height) / 2
            let dx = cos(a) * half, dy = sin(a) * half
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.midX - dx, y: rect.midY - dy),
                                   end: CGPoint(x: rect.midX + dx, y: rect.midY + dy),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .field(let base, let blobs):
            ctx.setFillColor(base.cgColor)
            ctx.fill(rect)
            let diagonal = hypot(rect.width, rect.height)
            for (color, fx, fy, fr) in blobs {
                guard let gradient = CGGradient(colorsSpace: space,
                                                colors: [color.withAlpha(0.95).cgColor, color.withAlpha(0.45).cgColor,
                                                         color.withAlpha(0).cgColor] as CFArray,
                                                locations: [0, 0.45, 1]) else { continue }
                let center = CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
                ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: diagonal * fr, options: [])
            }
        }
    }

    /// The capture framed by `style`. `image` is the capture with its annotations, `size` its size in points.
    static func render(_ image: CGImage, size: CGSize, style: BeautifyStyle, scale: CGFloat) -> CGImage? {
        let layout = BeautifyLayout.make(content: size, style: style, scale: scale)
        let (w, h) = layout.pixelSize
        guard w > 0, h > 0, let ctx = RenderContext.make(width: w, height: h, scale: layout.pixelScale) else { return nil }
        draw(image, layout: layout, style: style, in: ctx, deviceScale: layout.pixelScale)
        return ctx.makeImage()
    }

    /// Draws the frame into a y-down context whose user space is the layout's points.
    /// `deviceScale` is device pixels per point (shadows are measured in device pixels).
    static func draw(_ image: CGImage, layout: BeautifyLayout, style: BeautifyStyle, in ctx: CGContext, deviceScale: CGFloat) {
        drawFrame(layout: layout, style: style, in: ctx, deviceScale: deviceScale) { ctx in
            RenderContext.drawUpright(image, in: layout.content, ctx: ctx)
        }
    }

    /// Paints the backdrop, then `content` clipped to the rounded capture rect, casting the shadow.
    static func drawFrame(layout: BeautifyLayout, style: BeautifyStyle, in ctx: CGContext, deviceScale: CGFloat,
                          content: (CGContext) -> Void) {
        paint(style.backdrop, in: ctx, rect: CGRect(origin: .zero, size: layout.canvas))
        let shape = CGPath(roundedRect: layout.content, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius,
                           transform: nil)
        let shadow = BeautifyLayout.shadow(strength: style.shadow)
        ctx.saveGState()
        if shadow.alpha > 0 {
            // Shadows are in device pixels with y up, whatever the transform: scale them and point them down.
            ctx.setShadow(offset: CGSize(width: 0, height: -shadow.offset * deviceScale),
                          blur: shadow.blur * deviceScale, color: NSColor.black.withAlphaComponent(shadow.alpha).cgColor)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(shape)
        ctx.clip()
        content(ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// Bitmap contexts in the module's convention: sRGB, premultiplied alpha, y-down, user space in points.
enum RenderContext {
    static func make(width: Int, height: Int, scale: CGFloat) -> CGContext? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Draws an image the right way up into a y-down context.
    static func drawUpright(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }
}
