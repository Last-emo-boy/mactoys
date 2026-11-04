import CoreGraphics
import CoreImage
import Foundation

/// Blur and pixelate regions. The math is pure; the image work runs on Core Graphics / Core Image.
enum Redaction {
    /// A region in image points → the pixels it covers (rounded outward, clamped to the image).
    static func pixelRect(_ r: CGRect, scale: CGFloat, imagePixels: CGSize) -> CGRect {
        let s = max(scale, 0.01)
        let minX = max(0, floor(r.minX * s)), minY = max(0, floor(r.minY * s))
        let maxX = min(imagePixels.width, ceil(r.maxX * s)), maxY = min(imagePixels.height, ceil(r.maxY * s))
        guard maxX > minX, maxY > minY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Pixel size of the mosaic cells for a region: about a twelfth of its short side, never below
    /// 10 points (small text stays unreadable) and never more than half the short side.
    static func blockSize(for pixels: CGRect, scale: CGFloat) -> Int {
        let short = min(pixels.width, pixels.height)
        guard short >= 1 else { return 1 }
        let target = max(10 * scale, short / 12)
        return max(1, Int(min(target, max(1, short / 2)).rounded()))
    }

    /// Blur radius in pixels for a region: strong enough to wipe out text of any size inside it.
    static func blurRadius(for pixels: CGRect, scale: CGFloat) -> CGFloat {
        let short = min(pixels.width, pixels.height)
        return max(8 * scale, min(short / 5, 40 * scale))
    }

    /// Mosaic cells covering a `width`×`height` region, as (columns, rows). Edge cells may be partial.
    static func grid(width: Int, height: Int, block: Int) -> (columns: Int, rows: Int) {
        let b = max(1, block)
        return ((width + b - 1) / b, (height + b - 1) / b)
    }

    /// Replaces every `block`×`block` cell of an RGBA8 buffer with its average color (in place).
    /// Cells start at the buffer's top-left corner.
    static func pixelate(_ pixels: inout [UInt8], width: Int, height: Int, block: Int) {
        let b = max(1, block)
        let (cols, rows) = grid(width: width, height: height, block: b)
        for row in 0..<rows {
            let y0 = row * b, y1 = min(height, y0 + b)
            for col in 0..<cols {
                let x0 = col * b, x1 = min(width, x0 + b)
                var sum = (0, 0, 0, 0)
                for y in y0..<y1 {
                    var i = (y * width + x0) * 4
                    for _ in x0..<x1 {
                        sum.0 += Int(pixels[i]); sum.1 += Int(pixels[i + 1]); sum.2 += Int(pixels[i + 2]); sum.3 += Int(pixels[i + 3])
                        i += 4
                    }
                }
                let n = max(1, (y1 - y0) * (x1 - x0))
                let avg = (UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n), UInt8(sum.3 / n))
                for y in y0..<y1 {
                    var i = (y * width + x0) * 4
                    for _ in x0..<x1 {
                        pixels[i] = avg.0; pixels[i + 1] = avg.1; pixels[i + 2] = avg.2; pixels[i + 3] = avg.3
                        i += 4
                    }
                }
            }
        }
    }

    /// The pixelated image of one region of `image` (pixel rect, top-left origin).
    static func pixelated(_ image: CGImage, region px: CGRect, block: Int) -> CGImage? {
        guard !px.isNull, let cropped = image.cropping(to: px) else { return nil }
        let w = cropped.width, h = cropped.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        var bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        // The bitmap's first row is the image's top row, so cells line up with the region's top-left corner.
        pixelate(&bytes, width: w, height: h, block: block)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    /// The blurred image of one region (pixel rect, top-left origin). Edges are clamped, so the blur
    /// doesn't fade to transparent, and the region is shrunk first so nothing of the original survives.
    static func blurred(_ image: CGImage, region px: CGRect, scale: CGFloat) -> CGImage? {
        guard !px.isNull, let cropped = image.cropping(to: px) else { return nil }
        let radius = blurRadius(for: px, scale: scale)
        let down: CGFloat = 0.25
        let input = CIImage(cgImage: cropped)
        let small = input.transformed(by: CGAffineTransform(scaleX: down, y: down))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: radius * down / 2)
            .transformed(by: CGAffineTransform(scaleX: 1 / down, y: 1 / down))
            .cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent)
    }
}

/// Caches redacted regions so dragging a handle doesn't redo the work for every other region.
final class RedactionCache {
    private var images: [String: CGImage] = [:]
    private let source: CGImage
    private let scale: CGFloat

    init(source: CGImage, scale: CGFloat) {
        self.source = source
        self.scale = scale
    }

    private var pixels: CGSize { CGSize(width: source.width, height: source.height) }

    func blur(_ r: CGRect) -> (CGImage, CGRect)? {
        let px = Redaction.pixelRect(r, scale: scale, imagePixels: pixels)
        guard !px.isNull else { return nil }
        let key = "b\(px)"
        if let hit = images[key] { return (hit, rectInPoints(px)) }
        guard let img = Redaction.blurred(source, region: px, scale: scale) else { return nil }
        store(key, img)
        return (img, rectInPoints(px))
    }

    func pixelate(_ r: CGRect) -> (CGImage, CGRect)? {
        let px = Redaction.pixelRect(r, scale: scale, imagePixels: pixels)
        guard !px.isNull else { return nil }
        let key = "p\(px)"
        if let hit = images[key] { return (hit, rectInPoints(px)) }
        guard let img = Redaction.pixelated(source, region: px, block: Redaction.blockSize(for: px, scale: scale)) else { return nil }
        store(key, img)
        return (img, rectInPoints(px))
    }

    private func rectInPoints(_ px: CGRect) -> CGRect {
        CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
    }

    private func store(_ key: String, _ image: CGImage) {
        if images.count > 48 { images.removeAll() }
        images[key] = image
    }
}
