import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small `CGImage` helpers shared by the renderers.
public enum ImageUtil {
    public static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// An RGBA8 premultiplied bitmap context, origin bottom-left.
    public static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Decodes PNG/JPEG/… (anything ImageIO reads) or QOI.
    public static func image(from data: Data) -> CGImage? {
        if data.count >= 4, data.prefix(4) == Data("qoif".utf8) { return try? QOI.image(data) }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Pixel dimensions of an image file without decoding it.
    public static func pixelSize(of url: URL) -> CGSize? {
        if url.pathExtension.lowercased() == "qoi", let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 14), let h = try? QOI.header(head) {
                return CGSize(width: h.width, height: h.height)
            }
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// `size` scaled down (never up) to fit in `bounds`, keeping its aspect ratio.
    public static func fit(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let s = min(1, min(bounds.width / size.width, bounds.height / size.height))
        return CGSize(width: max(1, (size.width * s).rounded()), height: max(1, (size.height * s).rounded()))
    }

    /// Scales an image down to fit `maxSize` (aspect kept).
    public static func scaled(_ image: CGImage, toFit maxSize: CGSize) -> CGImage {
        let target = fit(CGSize(width: image.width, height: image.height), in: maxSize)
        guard Int(target.width) < image.width || Int(target.height) < image.height,
              let ctx = context(width: Int(target.width), height: Int(target.height)) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: target))
        return ctx.makeImage() ?? image
    }

    /// Draws a transparency checkerboard (for SVG and other images with alpha).
    public static func drawCheckerboard(in ctx: CGContext, rect: CGRect, square: CGFloat = 8, dark: Bool = false) {
        let a: CGFloat = dark ? 0.16 : 1.0, b: CGFloat = dark ? 0.22 : 0.9
        ctx.setFillColor(CGColor(gray: a, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(gray: b, alpha: 1))
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : square)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: square, height: square).intersection(rect))
                x += square * 2
            }
            y += square
            row += 1
        }
    }

    /// Composites `image` over a background (checkerboard or solid color).
    public static func flatten(_ image: CGImage, background: ImageBackground) -> CGImage {
        guard background != .transparent, let ctx = context(width: image.width, height: image.height) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        switch background {
        case .transparent: break
        case .checkerboard: drawCheckerboard(in: ctx, rect: rect, square: max(6, CGFloat(min(image.width, image.height)) / 40))
        case .checkerboardDark: drawCheckerboard(in: ctx, rect: rect, square: max(6, CGFloat(min(image.width, image.height)) / 40), dark: true)
        case .white: ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(rect)
        case .black: ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(rect)
        }
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}

/// What shows through transparent parts of a preview.
public enum ImageBackground: String, Codable, CaseIterable, Sendable {
    case transparent, checkerboard, checkerboardDark, white, black

    public var title: String {
        switch self {
        case .transparent: "Transparent"
        case .checkerboard: "Light checkerboard"
        case .checkerboardDark: "Dark checkerboard"
        case .white: "White"
        case .black: "Black"
        }
    }
}
