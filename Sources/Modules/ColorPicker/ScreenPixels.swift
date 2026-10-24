import CoreGraphics
import Foundation

/// A captured screen redrawn into 8-bit sRGB so every pixel read returns the color the
/// formats will print, plus the matching `CGImage` for display.
struct ScreenPixels {
    let image: CGImage
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    /// Converts any capture (display P3, 10-bit, …) to sRGB RGBA8.
    init?(_ source: CGImage) {
        let w = source.width, h = source.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data, let image = ctx.makeImage() else { return nil }
        self.image = image
        self.width = w
        self.height = h
        self.bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    /// Color at a pixel (origin top-left); `nil` outside the image.
    func color(x: Int, y: Int) -> ColorValue? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return ColorValue(red: bytes[i], green: bytes[i + 1], blue: bytes[i + 2])
    }

    /// An `size`×`size` crop centered on a pixel, transparent beyond the edges — the loupe's content.
    func patch(centerX cx: Int, centerY cy: Int, size: Int) -> CGImage? {
        let half = size / 2
        var out = [UInt8](repeating: 0, count: size * size * 4)
        for row in 0..<size {
            let sy = cy - half + row
            guard sy >= 0, sy < height else { continue }
            for col in 0..<size {
                let sx = cx - half + col
                guard sx >= 0, sx < width else { continue }
                let s = (sy * width + sx) * 4, d = (row * size + col) * 4
                out[d] = bytes[s]; out[d + 1] = bytes[s + 1]; out[d + 2] = bytes[s + 2]; out[d + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
