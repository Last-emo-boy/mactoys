import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Optimizer

/// Test images drawn in code; files go to a fresh temp folder per test.
private enum Fixtures {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("optimizer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func context(_ w: Int, _ h: Int, alpha: Bool = false, space: CFString = CGColorSpace.sRGB) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: space)!,
                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    }

    /// A window-like screenshot: flat panels, anti-aliased text, a gradient toolbar, a rounded shadowed card.
    static func screenshot(_ w: Int = 480, _ h: Int = 320) -> CGImage {
        let ctx = context(w, h)
        ctx.setFillColor(CGColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let bar = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1), CGColor(red: 0.55, green: 0.3, blue: 0.85, alpha: 1)] as CFArray,
            locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: h - 48, width: w, height: 48))
        ctx.drawLinearGradient(bar, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [])
        ctx.restoreGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: CGColor(gray: 0, alpha: 0.25))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 40, y: 40, width: w - 80, height: h - 130), cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0)
        let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        for (i, line) in ["Release notes 0.102", "Mouse Button Lock and CursorHide", "join the mouse utilities family."].enumerated() {
            let s = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font,
                                                                  .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1)])
            ctx.textPosition = CGPoint(x: 64, y: Double(h - 110 - i * 26))
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        return ctx.makeImage()!
    }

    /// Smooth color gradients with fine noise: thousands of colors, like a photo.
    static func photo(_ w: Int = 320, _ h: Int = 240, alpha: Bool = false) -> CGImage {
        let ctx = context(w, h, alpha: alpha)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let n = Int(seed >> 29) - 4
                let o = y * ctx.bytesPerRow + x * 4
                let a = alpha ? UInt8(255 * x / w) : 255
                func c(_ v: Int) -> UInt8 { UInt8(max(0, min(Int(a), v * Int(a) / 255))) }
                data[o] = c(40 + 200 * x / w + n)
                data[o + 1] = c(30 + 180 * y / h + n)
                data[o + 2] = c(220 - 160 * (x + y) / (w + h) + n)
                data[o + 3] = a
            }
        }
        return ctx.makeImage()!
    }

    /// Six flat color blocks, some translucent.
    static func flat(_ w: Int = 120, _ h: Int = 80) -> CGImage {
        let ctx = context(w, h, alpha: true)
        let colors = [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0.6, blue: 0.2, alpha: 1),
                      CGColor(red: 0, green: 0, blue: 1, alpha: 0.5), CGColor(gray: 1, alpha: 1),
                      CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        for (i, c) in colors.enumerated() {
            ctx.setBlendMode(.copy)
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: i * w / 6, y: 0, width: w / 6, height: h))
        }
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [String: Any] = [:]) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        RGBACanvas(image)!.pixels
    }

    static func properties(_ data: Data) -> [String: Any] {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    }

    static func decode(_ data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

@Suite struct OptimizerTests {
    // MARK: Quantizer

    @Test func fewColorsGetAnExactPalette() {
        let image = Fixtures.flat()
        let r = PaletteQuantizer.quantize(rgba: Fixtures.rgba(image), width: image.width, height: image.height)
        #expect(r.isExact)
        #expect(r.palette.count == 6)
        #expect(r.meanSquaredError == 0)
        #expect(r.psnr == .infinity)
    }

    @Test func screenshotsQuantizeFaithfullyWithinThePaletteSize() {
        let image = Fixtures.screenshot()
        let pixels = Fixtures.rgba(image)
        let r = PaletteQuantizer.quantize(rgba: pixels, width: image.width, height: image.height, maxColors: 256)
        #expect(!r.isExact)
        #expect(r.palette.count <= 256)
        #expect(r.indices.count == image.width * image.height)
        #expect(r.psnr > 36)
        // Flat background pixels (bottom left, outside the card's shadow) come out exact.
        let i = (image.height - 4) * image.width + 4
        let background = PaletteColor(r: pixels[i * 4], g: pixels[i * 4 + 1], b: pixels[i * 4 + 2], a: pixels[i * 4 + 3])
        #expect(r.palette[Int(r.indices[i])] == background)
    }

    @Test func smallPalettesStillTrackTheImage() {
        let image = Fixtures.photo()
        let pixels = Fixtures.rgba(image)
        let r16 = PaletteQuantizer.quantize(rgba: pixels, width: image.width, height: image.height, maxColors: 16)
        let r256 = PaletteQuantizer.quantize(rgba: pixels, width: image.width, height: image.height, maxColors: 256)
        #expect(r16.palette.count <= 16)
        #expect(Set(r16.indices).count <= 16)
        #expect(r256.psnr > r16.psnr)
        #expect(r256.psnr > 30)
        #expect(r16.psnr > 20)
    }

    @Test func ditheringKeepsAverageColorsCloser() {
        // A smooth ramp quantized to 4 colors: dithering keeps local averages near the original.
        let w = 256, h = 8
        let ctx = Fixtures.context(w, h)
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { let o = y * ctx.bytesPerRow + x * 4; data[o] = UInt8(x); data[o + 1] = UInt8(x); data[o + 2] = UInt8(x); data[o + 3] = 255 } }
        let image = ctx.makeImage()!
        let pixels = Fixtures.rgba(image)
        func blockError(_ r: PaletteQuantizer.Result) -> Double {
            var total = 0.0
            for bx in stride(from: 0, to: w, by: 16) {
                var mean = 0.0, original = 0.0
                for y in 0..<h { for x in bx..<(bx + 16) {
                    mean += Double(r.palette[Int(r.indices[y * w + x])].g)
                    original += Double(pixels[(y * w + x) * 4 + 1])
                } }
                total += abs(mean - original) / Double(16 * h)
            }
            return total
        }
        let plain = PaletteQuantizer.quantize(rgba: pixels, width: w, height: h, maxColors: 4, dither: false)
        let dithered = PaletteQuantizer.quantize(rgba: pixels, width: w, height: h, maxColors: 4, dither: true)
        #expect(blockError(dithered) < blockError(plain))
    }

    // MARK: PNG writer

    @Test func palettePNGsDecodeToTheSamePixels() throws {
        let image = Fixtures.flat()
        let r = PaletteQuantizer.quantize(rgba: Fixtures.rgba(image), width: image.width, height: image.height)
        let data = try PNGWriter.indexed(width: r.width, height: r.height, palette: r.palette, indices: r.indices,
                                         profile: .init(isSRGB: true, iccData: nil), dpi: 144)
        let props = Fixtures.properties(data)
        #expect(props[kCGImagePropertyDPIWidth as String] as? Int == 144)
        #expect((props[kCGImagePropertyPNGDictionary as String] as? [String: Any]) != nil)
        let decoded = try #require(Fixtures.decode(data))
        #expect(decoded.width == image.width && decoded.height == image.height)
        let a = Fixtures.rgba(image), b = Fixtures.rgba(decoded)
        let maxDifference = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(maxDifference <= 1)   // un-premultiplying translucent blue rounds by at most one step
        #expect(PNGWriter.bitDepth(forColors: 6) == 4)
        #expect(PNGWriter.bitDepth(forColors: 2) == 1)
        #expect(PNGWriter.bitDepth(forColors: 200) == 8)
    }

    @Test func translucentEntriesComeFirst() {
        let palette = [PaletteColor(r: 255, g: 0, b: 0, a: 255), PaletteColor(r: 0, g: 0, b: 0, a: 0),
                       PaletteColor(r: 10, g: 10, b: 10, a: 20), PaletteColor(r: 1, g: 2, b: 3, a: 255)]
        let (ordered, remap) = PNGWriter.orderForTransparency(palette, used: [0, 0, 0, 1, 2])
        #expect(ordered.count == 3)   // entry 3 is unused
        #expect(ordered.prefix(2).allSatisfy { $0.a < 255 })
        #expect(ordered[Int(remap[0])] == palette[0])
    }

    // MARK: Image pipeline

    @Test func screenshotPNGsShrinkWithReducedColors() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("Screenshot.png")
        try Fixtures.write(Fixtures.screenshot(960, 640), to: url, type: .png, properties: [kCGImagePropertyDPIWidth as String: 144,
                                                                                        kCGImagePropertyDPIHeight as String: 144])
        let original = FileSize.of(url)
        let result = try ImageOptimizer.optimize(url: url, plan: ImagePlan(ImageSettings()))
        #expect(result.format == .png)
        #expect(result.colors != nil)
        #expect(SizeGate.keeps(original: original, candidate: Int64(result.data.count)))
        #expect(Fixtures.properties(result.data)[kCGImagePropertyDPIWidth as String] as? Int == 144)
    }

    @Test func faithfulnessGateRejectsBadPalettes() throws {
        var settings = ImageSettings()
        settings.maxColors = 2
        let image = Fixtures.photo()
        let canvas = try #require(RGBACanvas(image))
        #expect(ImageOptimizer.paletteCandidate(canvas, plan: ImagePlan(settings), dpi: 72) == nil)
        settings.maxColors = 256
        #expect(ImageOptimizer.paletteCandidate(canvas, plan: ImagePlan(settings), dpi: 72) != nil)
        // Without color reduction only lossless palettes are made.
        settings.reduceColors = false
        #expect(ImageOptimizer.paletteCandidate(canvas, plan: ImagePlan(settings), dpi: 72) == nil)
        let flat = try #require(RGBACanvas(Fixtures.flat()))
        #expect(ImageOptimizer.paletteCandidate(flat, plan: ImagePlan(settings), dpi: 72)?.lossless == true)
    }

    @Test func opaquePNGsConvertOnlyWhenAllowed() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("photo.png")
        try Fixtures.write(Fixtures.photo(640, 480), to: url, type: .png)
        var settings = ImageSettings()
        settings.reduceColors = false
        #expect(try ImageOptimizer.optimize(url: url, plan: ImagePlan(settings)).format == .png)
        settings.convertOpaquePNG = .jpeg
        #expect(try ImageOptimizer.optimize(url: url, plan: ImagePlan(settings)).format == .jpeg)
        // Transparency rules conversion out.
        let translucent = dir.appendingPathComponent("translucent.png")
        try Fixtures.write(Fixtures.photo(640, 480, alpha: true), to: translucent, type: .png)
        #expect(try ImageOptimizer.optimize(url: translucent, plan: ImagePlan(settings)).format == .png)
    }

    @Test func strippingMetadataKeepsOrientationAndProfile() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("IMG_4821.jpg")
        let ctx = Fixtures.context(400, 300, space: CGColorSpace.displayP3)
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        try Fixtures.write(ctx.makeImage()!, to: url, type: .jpeg, properties: [
            kCGImagePropertyOrientation as String: 6,
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifUserComment as String: String(repeating: "x", count: 4000)],
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 48.85, kCGImagePropertyGPSLatitudeRef as String: "N"],
        ])
        let result = try ImageOptimizer.optimize(url: url, plan: ImagePlan(ImageSettings()))
        let props = Fixtures.properties(result.data)
        #expect(result.format == .jpeg)
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 6)
        #expect(props[kCGImagePropertyGPSDictionary as String] == nil)
        #expect((props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] == nil)
        #expect(props[kCGImagePropertyProfileName as String] as? String == "Display P3")
        #expect(result.pixelSize == CGSize(width: 300, height: 400))   // upright size

        // The lossless copy keeps them too.
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let stripped = try #require(ImageOptimizer.strippedCopy(src, format: .jpeg, orientation: 6))
        #expect(Fixtures.properties(stripped)[kCGImagePropertyOrientation as String] as? Int == 6)
        #expect(Fixtures.properties(stripped)[kCGImagePropertyGPSDictionary as String] == nil)
    }

    @Test func keepingMetadataKeepsIt() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("tagged.jpg")
        try Fixtures.write(Fixtures.photo(), to: url, type: .jpeg, properties: [
            kCGImageDestinationLossyCompressionQuality as String: 1.0,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Canon"],
        ])
        var settings = ImageSettings()
        settings.stripMetadata = false
        let result = try ImageOptimizer.optimize(url: url, plan: ImagePlan(settings))
        let tiff = Fixtures.properties(result.data)[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake as String] as? String == "Canon")
    }

    @Test func downscalingDrawsUprightAndHalvesTheResolution() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("rotated.jpg")
        try Fixtures.write(Fixtures.photo(400, 300), to: url, type: .jpeg, properties: [
            kCGImagePropertyOrientation as String: 6, kCGImagePropertyDPIWidth as String: 144, kCGImagePropertyDPIHeight as String: 144])
        let result = try ImageOptimizer.optimize(url: url, plan: ImagePlan(ImageSettings(), factor: 0.5))
        let props = Fixtures.properties(result.data)
        #expect(result.pixelSize == CGSize(width: 150, height: 200))
        #expect(props[kCGImagePropertyPixelWidth as String] as? Int == 150)
        #expect(props[kCGImagePropertyOrientation as String] as? Int == 1)
        #expect(props[kCGImagePropertyDPIWidth as String] as? Int == 72)
    }

    @Test func conversionWritesTheTargetFormat() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("flat.png")
        try Fixtures.write(Fixtures.flat(), to: url, type: .png)
        let jpeg = try ImageOptimizer.optimize(url: url, plan: ImagePlan(ImageSettings(), target: .jpeg))
        #expect(jpeg.format == .jpeg)
        #expect(UTType(CGImageSourceGetType(CGImageSourceCreateWithData(jpeg.data as CFData, nil)!)! as String) == .jpeg)
        if ImageFormat.heic.isWritable {
            #expect(try ImageOptimizer.optimize(url: url, plan: ImagePlan(ImageSettings(), target: .heic)).format == .heic)
        }
        if !ImageFormat.webp.isWritable {
            #expect(throws: ImageOptimizer.Failure.cannotEncode(.webp)) {
                try ImageOptimizer.optimize(url: url, plan: ImagePlan(ImageSettings(), target: .webp))
            }
        }
    }

    @Test func aggressivePlansTradeQuality() {
        var s = ImageSettings()
        s.quality = 80
        s.maxColors = 256
        let normal = ImagePlan(s), aggressive = ImagePlan(s, aggressive: true)
        #expect(aggressive.quality < normal.quality)
        #expect(aggressive.maxColors == 128)
        #expect(aggressive.minimumPSNR < normal.minimumPSNR)
        s.downscale = .maxSide
        s.maxSide = 1920
        #expect(ImagePlan(s).maxSide == 1920)
        s.downscale = .factor
        s.factor = 0.5
        #expect(ImagePlan(s, factor: 0.3).factor == 0.3)
        #expect(ImagePlan(s, factor: 0.75).factor == 0.5)
    }

    // MARK: Math

    @Test func keepOnlyIfSmaller() {
        #expect(SizeGate.keeps(original: 100_000, candidate: 50_000))
        #expect(!SizeGate.keeps(original: 100_000, candidate: 100_000))
        #expect(!SizeGate.keeps(original: 100_000, candidate: 99_500))   // under 1 %: not worth it
        #expect(SizeGate.keeps(original: 100_000, candidate: 99_000))
        #expect(!SizeGate.keeps(original: 100_000, candidate: 120_000))
        #expect(!SizeGate.keeps(original: 100_000, candidate: 0))
        #expect(abs(SizeGate.saving(original: 4_000_000, result: 1_000_000) - 0.75) < 1e-9)
    }

    @Test func downscaleMath() {
        let s = CGSize(width: 4032, height: 3024)
        #expect(DownscaleMath.target(s) == s)
        #expect(DownscaleMath.target(s, factor: 0.5) == CGSize(width: 2016, height: 1512))
        #expect(DownscaleMath.target(s, maxSide: 2048) == CGSize(width: 2048, height: 1536))
        #expect(DownscaleMath.target(s, maxSide: 8000) == s)                // never upscales
        #expect(DownscaleMath.target(s, maxSide: 2048, factor: 0.25) == CGSize(width: 1008, height: 756))
        #expect(DownscaleMath.target(CGSize(width: 3, height: 1), factor: 0.1) == CGSize(width: 1, height: 1))
        #expect(DownscaleMath.nextFactor(after: 1) == 0.75)
        #expect(DownscaleMath.nextFactor(after: 0.75) == 0.5)
        #expect(DownscaleMath.nextFactor(after: 0.5) == 0.4)
        #expect(DownscaleMath.nextFactor(after: 0.1) == nil)
        #expect(DownscaleMath.videoTarget(CGSize(width: 2880, height: 1800), shortSide: 1080, factor: 1) == CGSize(width: 1728, height: 1080))
        #expect(DownscaleMath.videoTarget(CGSize(width: 1080, height: 1920), shortSide: 720, factor: 1) == CGSize(width: 720, height: 1280))
        #expect(DownscaleMath.videoTarget(CGSize(width: 1001, height: 563), shortSide: nil, factor: 1) == CGSize(width: 1000, height: 562))
    }

    // MARK: Naming, backups, undo

    @Test func outputNames() {
        let original = URL(fileURLWithPath: "/tmp/x/Screenshot 2026-11-04.png")
        let taken: Set<String> = ["/tmp/x/Screenshot 2026-11-04.png", "/tmp/x/Screenshot 2026-11-04.jpg",
                                  "/tmp/x/Screenshot 2026-11-04-optimized.png"]
        let exists = { (u: URL) in taken.contains(u.path) }
        #expect(OutputNamer.optimizedURL(for: original, fileExtension: "png", mode: .replace, exists: exists).path
                == "/tmp/x/Screenshot 2026-11-04.png")
        #expect(OutputNamer.optimizedURL(for: original, fileExtension: "jpg", mode: .replace, exists: exists).path
                == "/tmp/x/Screenshot 2026-11-04 2.jpg")
        #expect(OutputNamer.optimizedURL(for: original, fileExtension: "png", mode: .alongside, exists: exists).path
                == "/tmp/x/Screenshot 2026-11-04-optimized 2.png")
        // A job's own earlier result may be overwritten.
        let previous = URL(fileURLWithPath: "/tmp/x/Screenshot 2026-11-04-optimized.png")
        #expect(OutputNamer.optimizedURL(for: original, fileExtension: "png", mode: .alongside, reusing: previous, exists: exists)
                == previous)
        #expect(OutputNamer.convertedURL(for: original, fileExtension: "heic", exists: exists).path == "/tmp/x/Screenshot 2026-11-04.heic")
        #expect(OutputNamer.convertedURL(for: original, fileExtension: "jpg", exists: exists).path == "/tmp/x/Screenshot 2026-11-04 2.jpg")
        #expect(OutputNamer.convertedURL(for: original, fileExtension: "png", exists: { _ in false }).path
                == "/tmp/x/Screenshot 2026-11-04 2.png")   // never the original itself
    }

    @Test func backupsRestoreAndExpire() throws {
        let dir = try Fixtures.folder()
        let store = BackupStore(root: dir.appendingPathComponent("Backups"))
        let file = dir.appendingPathComponent("report.png")
        try Data("original".utf8).write(to: file)
        let backup = try store.backup(file)
        #expect(backup.lastPathComponent == "report.png")
        try Data("optimized".utf8).write(to: file)
        try store.restore(backup, to: file)
        #expect(try Data(contentsOf: file) == Data("original".utf8))
        #expect(FileManager.default.fileExists(atPath: backup.path))   // still there for another undo
        // Restoring to a path that no longer exists (the format changed) recreates it.
        try FileManager.default.removeItem(at: file)
        try store.restore(backup, to: file)
        #expect(try Data(contentsOf: file) == Data("original".utf8))

        let clip = try store.store(Data([1, 2, 3]), name: "Clipboard.png")
        #expect(try Data(contentsOf: clip) == Data([1, 2, 3]))
        #expect(store.folders().count == 2)
        #expect(store.totalSize() > 0)
        #expect(store.prune(before: Date().addingTimeInterval(-3600)) == 0)
        #expect(store.prune(before: Date().addingTimeInterval(3600)) == 2)
        #expect(store.folders().isEmpty)
    }

    @Test func markedFilesAreRecognized() throws {
        let dir = try Fixtures.folder()
        let file = dir.appendingPathComponent("a.png")
        try Data([0]).write(to: file)
        #expect(!FileMarker.isMarked(file))
        FileMarker.mark(file)
        #expect(FileMarker.isMarked(file))
    }

    // MARK: PDF

    @Test func imageHeavyPDFsShrinkAndKeepTheirText() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("Quarterly Report.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let photo = Fixtures.photo(1600, 1200)
        for page in 1...2 {
            pdf.beginPDFPage(nil)
            pdf.draw(photo, in: CGRect(x: 36, y: 320, width: 540, height: 405))
            let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
            let s = NSAttributedString(string: "Quarterly report page \(page)", attributes: [.init(kCTFontAttributeName as String): font])
            pdf.textPosition = CGPoint(x: 36, y: 240)
            CTLineDraw(CTLineCreateWithAttributedString(s), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let output = dir.appendingPathComponent("out.pdf")
        let result = try PDFOptimizer.optimize(url, to: output, resolution: 150, quality: 0.7)
        #expect(result.pageCount == 2)
        #expect(SizeGate.keeps(original: FileSize.of(url), candidate: FileSize.of(output)))
        let text = PDFDocument(url: output)?.string ?? ""
        #expect(text.contains("Quarterly report page 1"))
        #expect(text.contains("Quarterly report page 2"))
    }

    @Test func pdfFilterCarriesTheSettings() {
        let p = PDFOptimizer.filterProperties(resolution: 100, quality: 0.6)
        let image = ((p["FilterData"] as? [String: Any])?["ColorSettings"] as? [String: Any])?["ImageSettings"] as? [String: Any]
        #expect(image?["Compression Quality"] as? Double == 0.6)
        #expect((image?["ImageScaleSettings"] as? [String: Any])?["ImageResolution"] as? Int == 100)
    }

    // MARK: Video

    @Test func videoPlansFollowTheSettings() {
        let recording = VideoSourceInfo(naturalSize: CGSize(width: 2880, height: 1800), frameRate: 60, bitrate: 40_000_000,
                                        duration: 30, hasAudio: true)
        var s = VideoSettings()
        var plan = VideoPlan.make(source: recording, settings: s, fileExtension: "mov")
        #expect(plan.codec == .hevc)
        #expect(plan.fileType == .mov)
        #expect(plan.outputSize == CGSize(width: 2880, height: 1800))
        #expect(plan.frameRate == 60)
        #expect(plan.includesAudio)
        #expect(plan.bitrate <= 36_000_000)
        #expect(plan.bitrate == Int((2880.0 * 1800 * 60 * 0.08 / 1000).rounded()) * 1000)

        s.maxResolution = .p1080
        s.maxFrameRate = .fps30
        s.removeAudio = true
        s.codec = .h264
        s.quality = .smaller
        plan = VideoPlan.make(source: recording, settings: s, fileExtension: "mp4")
        #expect(plan.outputSize == CGSize(width: 1728, height: 1080))
        #expect(plan.frameRate == 30)
        #expect(!plan.includesAudio)
        #expect(plan.fileType == .mp4)
        #expect(plan.bitrate == Int((1728.0 * 1080 * 30 * 0.075 / 1000).rounded()) * 1000)
        let settings = plan.videoSettings(includingQuality: false)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .h264)
        #expect(settings[AVVideoWidthKey] as? Int == 1728)
        #expect((settings[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoQualityKey] == nil)

        // Speed doubles the frame rate before the cap and the data rate ceiling.
        s = VideoSettings()
        plan = VideoPlan.make(source: recording, settings: s, fileExtension: "mov", speed: 2)
        #expect(plan.speed == 2)
        #expect(plan.frameRate == 120)
        let aggressive = VideoPlan.make(source: recording, settings: s, fileExtension: "mov", aggressive: true)
        #expect(aggressive.bitrate < VideoPlan.make(source: recording, settings: s, fileExtension: "mov").bitrate)
        #expect(aggressive.audioBitrate < 128_000)
        // Downscaling from a result card.
        #expect(VideoPlan.make(source: recording, settings: s, fileExtension: "mov", factor: 0.5).outputSize
                == CGSize(width: 1440, height: 900))
        // Low-bitrate sources are never given more bits than they had.
        let small = VideoSourceInfo(naturalSize: CGSize(width: 1920, height: 1080), frameRate: 30, bitrate: 1_000_000, duration: 10, hasAudio: false)
        #expect(VideoPlan.make(source: small, settings: s, fileExtension: "mp4").bitrate == 900_000)
    }

    @Test func videoContainers() {
        #expect(VideoPlan.outputExtension(forSource: "MOV") == "mov")
        #expect(VideoPlan.outputExtension(forSource: "gif") == "mp4")
        #expect(VideoPlan.outputExtension(forSource: "avi") == "mp4")
        #expect(VideoPlan.fileType(forExtension: "m4v") == .m4v)
    }

    @Test func frameLimiterKeepsAnEvenGrid() {
        let limiter = FrameLimiter(fps: 30)
        let kept = (0..<60).map { Double($0) / 60 }.filter { limiter.keeps($0) }
        #expect(kept.count == 30)
        // After a pause the grid restarts instead of keeping a burst.
        #expect(limiter.keeps(5.0))
        #expect(!limiter.keeps(5.0 + 1.0 / 60))
        #expect(limiter.keeps(5.0 + 2.0 / 60))
        let all = FrameLimiter(fps: nil)
        #expect((0..<10).allSatisfy { all.keeps(Double($0) / 120) })
    }

    @Test func gifInfoUsesBrowserDelays() throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("loading.gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for delay in [0.05, 0.0, 0.2] {
            CGImageDestinationAddImage(dest, Fixtures.flat(), [kCGImagePropertyGIFDictionary as String:
                                                                [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        let info = try VideoTranscoder.gifInfo(url)
        #expect(info.delays.count == 3)
        #expect(abs(info.delays[1] - 0.1) < 0.001)
        #expect(abs(info.info.duration - 0.35) < 0.01)
        #expect(MediaKind.of(url) == .video)
        #expect(MediaKind.of(url, gifAsVideo: false) == .image)
    }

    @Test func mediaKinds() {
        #expect(MediaKind.of(type: .png) == .image)
        #expect(MediaKind.of(type: .quickTimeMovie) == .video)
        #expect(MediaKind.of(type: .pdf) == .pdf)
        #expect(MediaKind.of(type: .plainText) == nil)
        #expect(ImageFormat.of(type: .jpeg) == .jpeg)
        #expect(ImageFormat.of(type: .heic) == .heic)
        #expect(ImageFormat.of(type: .png) == .png)
        #expect(ImageFormat.jpeg.isWritable && ImageFormat.png.isWritable)
    }

    // MARK: Real encodes (slow; hardware encoders may be missing on CI virtual machines)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPTIMIZER_ENCODE_TESTS"] != nil))
    func gifsBecomeSmallVideos() async throws {
        let dir = try Fixtures.folder()
        let url = dir.appendingPathComponent("spinner.gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 30, nil))
        for i in 0..<30 {
            let ctx = Fixtures.context(320, 240)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 40 + i * 6, y: 80, width: 80, height: 80))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary as String:
                                                                   [kCGImagePropertyGIFDelayTime as String: 0.04]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        let info = try await VideoTranscoder.info(of: url)
        let plan = VideoPlan.make(source: info, settings: VideoSettings(), fileExtension: "mp4")
        let output = dir.appendingPathComponent("spinner.mp4")
        try await VideoTranscoder().run(source: url, output: output, plan: plan) { _ in }
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.2) < 0.1)
        #expect(FileSize.of(output) > 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OPTIMIZER_ENCODE_TESTS"] != nil))
    func videosReencodeDownscaledAndFaster() async throws {
        let dir = try Fixtures.folder()
        let source = dir.appendingPathComponent("Screen Recording.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 400,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 20_000_000]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 400])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<120 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<400 { for x in 0..<640 { let o = y * bpr + x * 4
                base[o] = UInt8((x + i * 3) & 255); base[o + 1] = UInt8(y & 255); base[o + 2] = UInt8((x ^ y) & 255); base[o + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(i), timescale: 60))
        }
        input.markAsFinished()
        await writer.finishWriting()

        let info = try await VideoTranscoder.info(of: source)
        #expect(abs(info.frameRate - 60) < 1)
        var settings = VideoSettings()
        settings.maxFrameRate = .fps30
        let plan = VideoPlan.make(source: info, settings: settings, fileExtension: "mov", factor: 0.5, speed: 2)
        let output = dir.appendingPathComponent("out.mov")
        let progress = ProgressBox()
        try await VideoTranscoder().run(source: source, output: output, plan: plan) { progress.value = $0 }
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 200))
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1)
        #expect(progress.value == 1)
        #expect(FileSize.of(output) < FileSize.of(source))
    }
}

private final class ProgressBox: @unchecked Sendable {
    var value = 0.0
}
