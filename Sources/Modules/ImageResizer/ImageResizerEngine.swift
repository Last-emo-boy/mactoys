import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Resizes images with ImageIO and Core Graphics only. Usable from the app, the CLI and tests.
///
///     let written = try ImageResizerEngine.resize(urls: files, preset: ResizePreset.defaults[0], options: ResizeOptions())
public enum ImageResizerEngine {
    public struct FileError: Error, LocalizedError, Sendable {
        public let url: URL
        public let message: String
        public var errorDescription: String? { "\(url.lastPathComponent): \(message)" }
    }

    /// Thrown by the batch call when some images failed; `outputs` lists the files that were written.
    public struct BatchError: Error, LocalizedError, Sendable {
        public let outputs: [URL]
        public let failures: [FileError]
        public var errorDescription: String? {
            "\(failures.count) of \(failures.count + outputs.count) images could not be resized: "
                + failures.map { $0.errorDescription ?? "" }.joined(separator: "; ")
        }
    }

    /// Resizes every image and returns the files written, in order. When any image fails the others
    /// are still written and a `BatchError` is thrown.
    public static func resize(urls: [URL], preset: ResizePreset, options: ResizeOptions,
                              progress: ((Int, URL) -> Void)? = nil) throws -> [URL] {
        var outputs: [URL] = []
        var failures: [FileError] = []
        for (i, url) in urls.enumerated() {
            progress?(i, url)
            do {
                outputs.append(try resize(url: url, preset: preset, options: options))
            } catch let e as FileError {
                failures.append(e)
            } catch {
                failures.append(FileError(url: url, message: error.localizedDescription))
            }
        }
        if !failures.isEmpty { throw BatchError(outputs: outputs, failures: failures) }
        return outputs
    }

    /// Resizes one image and returns the file written.
    public static func resize(url: URL, preset: ResizePreset, options: ResizeOptions) throws -> URL {
        func fail(_ message: String) -> FileError { FileError(url: url, message: message) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0, let sourceTypeID = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else {
            throw fail("Not an image MacToys can read")
        }
        let info = ImageInfo(props)
        let sourceType = UTType(sourceTypeID)
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let outType = writable.contains(sourceTypeID) ? (sourceType ?? options.encoder.fallback.type)
                                                      : options.encoder.fallback.type
        let sameType = outType.identifier == sourceTypeID
        let ext = sameType && !url.pathExtension.isEmpty ? url.pathExtension : (outType.preferredFilenameExtension ?? "png")

        let plan = ResizeMath.plan(source: info.uprightSize, preset: preset, shrinkOnly: options.shrinkOnly,
                                   ignoreOrientation: options.ignoreOrientation, dpi: info.dpi)
        let size = plan.outputSize

        // Where the result goes.
        let fm = FileManager.default
        let target: URL
        if options.replaceOriginals {
            target = sameType ? url : ResizeFileNamer.uniqueURL(in: url.deletingLastPathComponent(),
                                                                components: [url.deletingPathExtension().lastPathComponent],
                                                                pathExtension: ext)
        } else {
            let values = ResizeFileNamer.Values(original: url.deletingPathExtension().lastPathComponent, sizeName: preset.name,
                                                selectedWidth: preset.width, selectedHeight: preset.height,
                                                actualWidth: Int(size.width), actualHeight: Int(size.height))
            let comps = ResizeFileNamer.components(format: options.fileNameFormat, values: values)
            target = ResizeFileNamer.uniqueURL(in: options.destination ?? url.deletingLastPathComponent(),
                                               components: comps, pathExtension: ext)
        }
        let originalDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw fail("Could not create the folder: \(error.localizedDescription)")
        }

        // Encode next to the target, then move it into place.
        let temp = target.deletingLastPathComponent().appendingPathComponent(".mactoys-resize-\(UUID().uuidString).\(ext)")
        defer { try? fm.removeItem(at: temp) }
        let frames = Self.supportsFrames(outType) ? CGImageSourceGetCount(src) : 1
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, outType.identifier as CFString, frames, nil) else {
            throw fail("Can’t write \(outType.localizedDescription ?? outType.identifier) files")
        }
        if let container = CGImageSourceCopyProperties(src, nil) as? [String: Any],
           let gif = container[kCGImagePropertyGIFDictionary as String] {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: gif] as CFDictionary)
        }
        for i in 0..<frames {
            guard let image = CGImageSourceCreateImageAtIndex(src, i, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw fail("Frame \(i + 1) could not be decoded")
            }
            let frameProps = i == 0 ? props : (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any] ?? [:])
            let frameInfo = i == 0 ? info : ImageInfo(frameProps)
            let framePlan = i == 0 ? plan : ResizeMath.plan(source: frameInfo.uprightSize, preset: preset,
                                                            shrinkOnly: options.shrinkOnly,
                                                            ignoreOrientation: options.ignoreOrientation, dpi: frameInfo.dpi)
            guard let resized = render(image, orientation: frameInfo.orientation, plan: framePlan,
                                       opaque: outType.conforms(to: .jpeg)) else {
                throw fail("The image could not be drawn")
            }
            CGImageDestinationAddImage(dest, resized, outputProperties(frameProps, type: outType, size: framePlan.outputSize,
                                                                       options: options) as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw fail("The resized image could not be saved") }

        do {
            if options.replaceOriginals && sameType {
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
            if options.keepDateModified, let originalDate {
                try fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: target.path)
            }
            if options.replaceOriginals && !sameType {
                try fm.trashItem(at: url, resultingItemURL: nil)
            }
        } catch {
            throw fail(error.localizedDescription)
        }
        return target
    }

    // MARK: Drawing

    /// Scales, crops and uprights `image` (raw pixels with EXIF `orientation`) according to `plan`.
    static func render(_ image: CGImage, orientation: Int, plan: ResizePlan, opaque: Bool) -> CGImage? {
        let out = plan.outputSize
        let w = Int(out.width), h = Int(out.height)
        guard w > 0, h > 0 else { return nil }
        let ctx = makeContext(like: image, width: w, height: h, opaque: opaque)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx else { return nil }
        ctx.interpolationQuality = .high
        if opaque {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let scaled = plan.scaledSize
        // Core Graphics is bottom-left; the crop is top-left.
        ctx.translateBy(x: -plan.crop.minX, y: -(scaled.height - plan.crop.maxY))
        ctx.concatenate(orientationTransform(orientation, width: scaled.width, height: scaled.height))
        let rotated = (5...8).contains(orientation)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rotated ? scaled.height : scaled.width,
                                   height: rotated ? scaled.width : scaled.height))
        return ctx.makeImage()
    }

    /// Maps the stored image, drawn at its raw size, onto an upright `width` × `height` box.
    static func orientationTransform(_ orientation: Int, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        let t = CGAffineTransform.identity
        switch orientation {
        case 2: return t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case 3: return t.translatedBy(x: w, y: h).rotated(by: .pi)
        case 4: return t.translatedBy(x: 0, y: h).scaledBy(x: 1, y: -1)
        case 5: return t.translatedBy(x: w, y: 0).rotated(by: .pi / 2).translatedBy(x: h, y: 0).scaledBy(x: -1, y: 1)
        case 6: return t.translatedBy(x: 0, y: h).rotated(by: -.pi / 2)
        case 7: return t.translatedBy(x: 0, y: h).rotated(by: -.pi / 2).translatedBy(x: h, y: 0).scaledBy(x: -1, y: 1)
        case 8: return t.translatedBy(x: w, y: 0).rotated(by: .pi / 2)
        default: return t
        }
    }

    /// A bitmap context in the image's own color space and depth where Core Graphics supports it.
    private static func makeContext(like image: CGImage, width: Int, height: Int, opaque: Bool) -> CGContext? {
        let alpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: false
            default: !opaque
            }
        }()
        let bpc = image.bitsPerComponent > 8 ? 16 : 8
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var space = srgb
        var info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        if let cs = image.colorSpace, cs.supportsOutput {
            switch cs.model {
            case .rgb:
                space = cs
            case .monochrome where !alpha:
                space = cs
                info = CGImageAlphaInfo.none.rawValue
            case .cmyk where !alpha:
                space = cs
                info = CGImageAlphaInfo.none.rawValue
                return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: space, bitmapInfo: info)
            default:
                break
            }
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc, bytesPerRow: 0,
                         space: space, bitmapInfo: info)
    }

    // MARK: Properties

    /// Formats that hold several frames (animations, pages).
    static func supportsFrames(_ type: UTType) -> Bool {
        type.conforms(to: .gif) || type.conforms(to: .png) || type.conforms(to: .tiff)
            || type.identifier == "public.heics"
    }

    /// The properties written with a frame: the source metadata (unless removed) with orientation reset
    /// (pixels are already upright) and the new size, plus encoder settings.
    static func outputProperties(_ source: [String: Any], type: UTType, size: CGSize, options: ResizeOptions) -> [String: Any] {
        var p: [String: Any] = [:]
        let gifKey = kCGImagePropertyGIFDictionary as String
        if options.removeMetadata {
            // Only what changes how the image looks: resolution and animation timing.
            for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let v = source[key as String] { p[key as String] = v }
            }
            if let gif = source[gifKey] { p[gifKey] = gif }
        } else {
            p = source
            for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                        kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                        kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed] {
                p.removeValue(forKey: key as String)
            }
            if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif[kCGImagePropertyExifPixelXDimension as String] = Int(size.width)
                exif[kCGImagePropertyExifPixelYDimension as String] = Int(size.height)
                p[kCGImagePropertyExifDictionary as String] = exif
            }
        }
        p[kCGImagePropertyOrientation as String] = 1
        var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1

        let enc = options.encoder
        if type.conforms(to: .jpeg) {
            p[kCGImageDestinationLossyCompressionQuality as String] = Double(min(100, max(1, enc.jpegQuality))) / 100
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            p[kCGImageDestinationLossyCompressionQuality as String] = Double(min(100, max(1, enc.heicQuality))) / 100
        } else if type.conforms(to: .png), enc.pngInterlace != .default {
            var png = p[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
            png[kCGImagePropertyPNGInterlaceType as String] = enc.pngInterlace == .on ? 1 : 0
            p[kCGImagePropertyPNGDictionary as String] = png
        } else if type.conforms(to: .tiff), let tag = enc.tiffCompression.tag {
            tiff[kCGImagePropertyTIFFCompression as String] = tag
        }
        p[kCGImagePropertyTIFFDictionary as String] = tiff
        return p
    }
}

/// The parts of the ImageIO properties the resizer needs.
struct ImageInfo {
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
