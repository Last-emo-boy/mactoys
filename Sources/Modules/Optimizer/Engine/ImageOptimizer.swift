import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How to encode one image.
struct ImagePlan: Sendable, Equatable {
    /// Lossy quality, 0…1.
    var quality = 0.8
    var reduceColors = true
    var maxColors = 256
    var dither = true
    /// PNGs without transparency may also be tried in this format.
    var convertOpaquePNG: ImageFormat?
    var stripMetadata = true
    var maxSide: Int?
    var factor = 1.0
    /// Write this format (a conversion) instead of the source's.
    var target: ImageFormat?

    /// Palette results with less fidelity than this (dB) are rejected; exact palettes always pass.
    var minimumPSNR: Double { 22 + 10 * quality }

    init() {}

    /// The plan for the user's settings. `aggressive` (⌥ held when dropping) trades more quality for size;
    /// `factor` downscales relative to the original (result card "Downscale").
    init(_ s: ImageSettings, aggressive: Bool = false, factor: Double? = nil, target: ImageFormat? = nil) {
        quality = Double(min(100, max(10, s.quality))) / 100
        if aggressive { quality = max(0.4, quality - 0.15) }
        reduceColors = s.reduceColors || aggressive
        maxColors = aggressive ? min(s.maxColors, 128) : s.maxColors
        dither = s.dither
        convertOpaquePNG = s.convertOpaquePNG
        stripMetadata = s.stripMetadata
        switch s.downscale {
        case .off: break
        case .maxSide: maxSide = s.maxSide
        case .factor: self.factor = min(1, max(0.05, s.factor))
        }
        if let factor { self.factor = min(self.factor, factor) }
        self.target = target
    }
}

/// An encoded result, not yet written anywhere.
struct EncodedImage: Sendable {
    var data: Data
    var format: ImageFormat
    var pixelSize: CGSize
    /// Palette size when the colors were reduced.
    var colors: Int?
    /// True when pixels are unchanged (palette from an image that had few colors, or metadata removed only).
    var lossless: Bool
}

/// Shrinks images with ImageIO and the palette quantizer: tries every sensible encoding of the
/// (optionally downscaled) image and returns the smallest. The caller decides whether it is small
/// enough to keep (`SizeGate`).
///
/// - JPEG, HEIC, AVIF: metadata removed losslessly, and a re-encode at the plan's quality.
/// - PNG and other lossless sources: a palette PNG (reduced colors, if the result is faithful enough),
///   a lossless re-encode, and, for opaque images when enabled, JPEG or HEIC.
///
/// Orientation and the color profile always survive: lossy re-encodes keep the orientation tag,
/// everything else is drawn upright; profiles are embedded (`sRGB` / `iCCP` for palette PNGs).
enum ImageOptimizer {
    enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case animated
        case cannotEncode(ImageFormat)

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Not an image MacToys can read")
            case .animated: String(localized: "Animated and multi-page images are left as they are")
            case .cannotEncode(let f): String(localized: "This Mac can’t write \(f.title) images",
                                              comment: "Optimizer error; the value is an image format such as WebP")
            }
        }
    }

    static func optimize(url: URL, plan: ImagePlan) throws -> EncodedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadable
        }
        return try optimize(src, plan: plan)
    }

    static func optimize(data: Data, plan: ImagePlan) throws -> EncodedImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadable
        }
        return try optimize(src, plan: plan)
    }

    static func optimize(_ src: CGImageSource, plan: ImagePlan) throws -> EncodedImage {
        guard CGImageSourceGetCount(src) > 0, let typeID = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            throw Failure.unreadable
        }
        guard CGImageSourceGetCount(src) == 1 else { throw Failure.animated }
        let info = SourceInfo(props)
        guard info.pixelSize.width > 0, info.pixelSize.height > 0 else { throw Failure.unreadable }
        let sourceFormat = UTType(typeID).flatMap(ImageFormat.of(type:))
        let target = DownscaleMath.target(info.uprightSize, maxSide: plan.maxSide, factor: plan.factor)
        let scaled = target != info.uprightSize
        let dpi = scaled ? max(72, info.dpi * Double(target.width / info.uprightSize.width)) : info.dpi

        let family: ImageFormat
        if let t = plan.target {
            guard t.isWritable else { throw Failure.cannotEncode(t) }
            family = t
        } else if let s = sourceFormat, s.isWritable {
            family = s
        } else {
            family = .png   // TIFF, BMP, WebP…: optimized as PNG
        }

        var candidates: [EncodedImage] = []
        if family == .png {
            guard let image = upright(src, info: info, size: target), let canvas = RGBACanvas(image) else {
                throw Failure.unreadable
            }
            if let palette = paletteCandidate(canvas, plan: plan, dpi: dpi) { candidates.append(palette) }
            let lossless = try encode(image, as: .png, properties: properties(props, plan: plan, format: .png, orientation: 1, dpi: dpi))
            candidates.append(EncodedImage(data: lossless, format: .png, pixelSize: canvas.size, colors: nil, lossless: !scaled))
            if plan.target == nil, let other = plan.convertOpaquePNG, other.isWritable, canvas.isOpaque {
                let data = try encode(image, as: other, properties: properties(props, plan: plan, format: other, orientation: 1, dpi: dpi))
                candidates.append(EncodedImage(data: data, format: other, pixelSize: canvas.size, colors: nil, lossless: false))
            }
        } else {
            if !scaled, plan.target == nil, plan.stripMetadata, family == sourceFormat,
               let stripped = strippedCopy(src, format: family, orientation: info.orientation) {
                candidates.append(EncodedImage(data: stripped, format: family, pixelSize: info.uprightSize, colors: nil, lossless: true))
            }
            // Unscaled: keep the stored pixels and their orientation tag. Scaled: draw upright.
            let orientation = scaled ? 1 : info.orientation
            let raw = scaled ? upright(src, info: info, size: target)
                             : CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            guard var image = raw else { throw Failure.unreadable }
            if !family.supportsAlpha, let flat = flattened(image) { image = flat }
            let data = try encode(image, as: family, properties: properties(props, plan: plan, format: family,
                                                                             orientation: orientation, dpi: dpi))
            let size = scaled ? CGSize(width: image.width, height: image.height) : info.uprightSize
            candidates.append(EncodedImage(data: data, format: family, pixelSize: size, colors: nil, lossless: false))
        }
        guard let best = candidates.min(by: { $0.data.count < $1.data.count }) else { throw Failure.unreadable }
        return best
    }

    // MARK: Candidates

    /// A palette PNG: exact when the image has few colors, otherwise quantized if the plan allows it
    /// and the result is faithful enough.
    static func paletteCandidate(_ canvas: RGBACanvas, plan: ImagePlan, dpi: Double) -> EncodedImage? {
        let result: PaletteQuantizer.Result
        if plan.reduceColors {
            result = PaletteQuantizer.quantize(rgba: canvas.pixels, width: canvas.width, height: canvas.height,
                                               maxColors: plan.maxColors, dither: plan.dither)
            guard result.isExact || result.psnr >= plan.minimumPSNR else { return nil }
        } else {
            guard let exact = PaletteQuantizer.exact(rgba: canvas.pixels, width: canvas.width, height: canvas.height) else { return nil }
            result = exact
        }
        guard let data = try? PNGWriter.indexed(width: result.width, height: result.height, palette: result.palette,
                                                indices: result.indices, profile: canvas.profile, dpi: dpi) else { return nil }
        let used = Set(result.indices).count
        return EncodedImage(data: data, format: .png, pixelSize: canvas.size, colors: used, lossless: result.isExact)
    }

    /// Re-attaches the compressed image data with new metadata (no re-encode): EXIF, GPS and XMP go,
    /// the orientation stays, the color profile is part of the image data.
    static func strippedCopy(_ src: CGImageSource, format: ImageFormat, orientation: Int) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { return nil }
        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                         orientation as CFNumber)
        }
        let options: [String: Any] = [kCGImageDestinationMetadata as String: metadata,
                                      kCGImageDestinationMergeMetadata as String: false,
                                      kCGImageMetadataShouldExcludeXMP as String: true,
                                      kCGImageMetadataShouldExcludeGPS as String: true]
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil) else { return nil }
        return data as Data
    }

    // MARK: Encoding

    static func encode(_ image: CGImage, as format: ImageFormat, properties: [String: Any]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw Failure.cannotEncode(format)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.cannotEncode(format) }
        return data as Data
    }

    /// Frame properties: quality, orientation and resolution; the source's metadata only when kept.
    static func properties(_ source: [String: Any], plan: ImagePlan, format: ImageFormat, orientation: Int, dpi: Double) -> [String: Any] {
        var p: [String: Any] = [:]
        if !plan.stripMetadata {
            p = source
            for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyHasAlpha,
                        kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed,
                        kCGImagePropertyPNGDictionary, kCGImagePropertyJFIFDictionary] {
                p.removeValue(forKey: key as String)
            }
            if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
                p[kCGImagePropertyExifDictionary as String] = exif
            }
        }
        p[kCGImagePropertyOrientation as String] = orientation
        var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = orientation
        p[kCGImagePropertyTIFFDictionary as String] = tiff
        p[kCGImagePropertyDPIWidth as String] = dpi
        p[kCGImagePropertyDPIHeight as String] = dpi
        if format.isLossy { p[kCGImageDestinationLossyCompressionQuality as String] = plan.quality }
        return p
    }

    // MARK: Pixels

    /// The image drawn upright at `size` (ImageIO's thumbnailer applies the orientation and scales well).
    static func upright(_ src: CGImageSource, info: SourceInfo, size: CGSize) -> CGImage? {
        if size == info.uprightSize, info.orientation == 1 {
            return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
                                        kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// The image over white, for formats without transparency.
    static func flattened(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

/// An image as tightly packed premultiplied RGBA8 in its own RGB color space (sRGB for others).
struct RGBACanvas {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let profile: PNGWriter.ColorProfile

    var size: CGSize { CGSize(width: width, height: height) }

    var isOpaque: Bool {
        var i = 3
        while i < pixels.count {
            if pixels[i] != 255 { return false }
            i += 4
        }
        return true
    }

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil } ?? srgb
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer
        let isSRGB = (space.name as String?) == (CGColorSpace.sRGB as String)
        profile = PNGWriter.ColorProfile(isSRGB: isSRGB, iccData: isSRGB ? nil : space.copyICCData() as Data?)
    }
}

/// The parts of ImageIO's properties the optimizer needs.
struct SourceInfo {
    let pixelSize: CGSize
    let orientation: Int
    let dpi: Double

    init(_ props: [String: Any]) {
        let w = (props[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue ?? 0
        pixelSize = CGSize(width: w, height: h)
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let o = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
            ?? (tiff?[kCGImagePropertyTIFFOrientation as String] as? NSNumber)?.intValue ?? 1
        orientation = (1...8).contains(o) ? o : 1
        let d = (props[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue ?? 72
        dpi = d > 0 ? d : 72
    }

    /// The size as displayed (orientations 5–8 swap the sides).
    var uprightSize: CGSize {
        (5...8).contains(orientation) ? CGSize(width: pixelSize.height, height: pixelSize.width) : pixelSize
    }
}
