import AppKit
import CoreGraphics

/// Rasterizes SVG: `NSImage` (macOS's own SVG support) first, an offscreen WebKit snapshot when
/// `NSImage` can't read the file or draws nothing.
public enum SVGRenderer {
    /// Intrinsic size in points (from `NSImage`, which reads width/height/viewBox).
    public static func intrinsicSize(_ data: Data) -> CGSize? {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        return img.size
    }

    /// Draws the SVG to fill `maxSize` (scaling up or down, aspect kept) over `background`.
    public static func renderWithImageKit(_ data: Data, maxSize: CGSize, background: ImageBackground = .transparent) -> CGImage? {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let s = min(maxSize.width / img.size.width, maxSize.height / img.size.height)
        let w = max(1, Int((img.size.width * s).rounded())), h = max(1, Int((img.size.height * s).rounded()))
        guard let ctx = ImageUtil.context(width: w, height: h) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        img.draw(in: CGRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let raster = ctx.makeImage(), !isBlank(raster) else { return nil }
        return ImageUtil.flatten(raster, background: background)
    }

    /// WebKit fallback; runs on the main actor.
    @MainActor
    public static func renderWithWebKit(_ data: Data, maxSize: CGSize, background: ImageBackground = .transparent) async -> CGImage? {
        let size = intrinsicSize(data).map { ImageUtil.fit($0, in: maxSize) } ?? maxSize
        let points = CGSize(width: max(16, size.width / 2), height: max(16, size.height / 2))
        let bg: String
        switch background {
        case .transparent, .white: bg = "#fff"
        case .black: bg = "#141414"
        case .checkerboard: bg = "repeating-conic-gradient(#e6e6e6 0% 25%, #fff 0% 50%) 50% / 16px 16px"
        case .checkerboardDark: bg = "repeating-conic-gradient(#292929 0% 25%, #383838 0% 50%) 50% / 16px 16px"
        }
        let html = """
        <!DOCTYPE html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:\(bg);overflow:hidden}
        img{display:block;width:100%;height:100%;object-fit:contain}</style></head>
        <body><img src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
        """
        return await HTMLSnapshotter.snapshot(html: html, size: points, scale: 2)
    }

    /// `NSImage` first, then WebKit.
    public static func render(_ data: Data, maxSize: CGSize, background: ImageBackground = .transparent) async -> CGImage? {
        if let image = renderWithImageKit(data, maxSize: maxSize, background: background) { return image }
        return await renderWithWebKit(data, maxSize: maxSize, background: background)
    }

    /// True when every sampled pixel is fully transparent.
    static func isBlank(_ image: CGImage) -> Bool {
        let w = min(64, image.width), h = min(64, image.height)
        guard let ctx = ImageUtil.context(width: w, height: h) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * h)
        for y in 0..<h {
            for x in 0..<w where bytes[y * ctx.bytesPerRow + x * 4 + 3] != 0 { return false }
        }
        return true
    }
}
