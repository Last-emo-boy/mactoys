import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ImageResizer

@Suite struct ImageResizerTests {
    // MARK: Size math

    private func plan(_ w: CGFloat, _ h: CGFloat, _ preset: ResizePreset, shrinkOnly: Bool = false,
                      ignoreOrientation: Bool = false, dpi: Double = 72) -> ResizePlan {
        ResizeMath.plan(source: CGSize(width: w, height: h), preset: preset, shrinkOnly: shrinkOnly,
                        ignoreOrientation: ignoreOrientation, dpi: dpi)
    }

    private let medium = ResizePreset(name: "Medium", fit: .fit, width: 1366, height: 768)

    @Test func fitKeepsTheWholePicture() {
        let p = plan(4000, 3000, medium)
        #expect(p.outputSize == CGSize(width: 1024, height: 768))
        #expect(p.crop.origin == .zero)
        #expect(!p.unchanged)
    }

    @Test func fillCoversAndCropsCentered() {
        var fill = medium
        fill.fit = .fill
        let p = plan(4000, 3000, fill)
        #expect(p.scaledSize == CGSize(width: 1366, height: 1025))
        #expect(p.outputSize == CGSize(width: 1366, height: 768))
        #expect(p.crop.origin == CGPoint(x: 0, y: 128))
        let tall = plan(1000, 3000, ResizePreset(name: "Square", fit: .fill, width: 500, height: 500))
        #expect(tall.scaledSize == CGSize(width: 500, height: 1500))
        #expect(tall.crop == CGRect(x: 0, y: 500, width: 500, height: 500))
    }

    @Test func stretchDistorts() {
        var stretch = medium
        stretch.fit = .stretch
        #expect(plan(4000, 3000, stretch).outputSize == CGSize(width: 1366, height: 768))
        #expect(plan(100, 100, stretch).outputSize == CGSize(width: 1366, height: 768))
    }

    @Test func orientationSwapOnlyWhenIgnoringOrientation() {
        #expect(plan(3000, 4000, medium).outputSize == CGSize(width: 576, height: 768))
        #expect(plan(3000, 4000, medium, ignoreOrientation: true).outputSize == CGSize(width: 768, height: 1024))
        // Same orientation: nothing to swap.
        #expect(plan(4000, 3000, medium, ignoreOrientation: true).outputSize == CGSize(width: 1024, height: 768))
        // Square pictures never swap.
        #expect(plan(1000, 1000, medium, ignoreOrientation: true).outputSize == CGSize(width: 768, height: 768))
    }

    @Test func percentUnits() {
        let half = ResizePreset(name: "Half", fit: .stretch, width: 50, height: 50, unit: .percent)
        #expect(plan(4000, 3000, half).outputSize == CGSize(width: 2000, height: 1500))
        let wide = ResizePreset(name: "Wide", fit: .stretch, width: 50, height: 25, unit: .percent)
        #expect(plan(4000, 3000, wide).outputSize == CGSize(width: 2000, height: 750))
        let fitPercent = ResizePreset(name: "Fit", fit: .fit, width: 50, height: 25, unit: .percent)
        #expect(plan(4000, 3000, fitPercent).outputSize == CGSize(width: 1000, height: 750))
        // Percent never swaps for orientation and ignores shrink-only.
        #expect(plan(3000, 4000, wide, ignoreOrientation: true).outputSize == CGSize(width: 1500, height: 1000))
        let double = ResizePreset(name: "2x", fit: .fit, width: 200, height: 200, unit: .percent)
        #expect(plan(100, 50, double, shrinkOnly: true).outputSize == CGSize(width: 200, height: 100))
    }

    @Test func inchesAndCentimetersUseTheResolution() {
        let inches = ResizePreset(name: "Print", fit: .fit, width: 4, height: 3, unit: .inch)
        #expect(plan(4000, 3000, inches).outputSize == CGSize(width: 288, height: 216))
        #expect(plan(4000, 3000, inches, dpi: 300).outputSize == CGSize(width: 1200, height: 900))
        let cm = ResizePreset(name: "Passport", fit: .stretch, width: 2.54, height: 5.08, unit: .centimeter)
        #expect(plan(4000, 3000, cm, dpi: 300).outputSize == CGSize(width: 300, height: 600))
        #expect(ResizeMath.pixels(10, unit: .centimeter, original: 1, dpi: 254) == 1000)
        #expect(ResizeMath.pixels(25, unit: .percent, original: 640, dpi: 72) == 160)
    }

    @Test func autoSideKeepsProportions() {
        let autoH = ResizePreset(name: "800w", fit: .fill, width: 800, height: 0)
        #expect(plan(4000, 3000, autoH).outputSize == CGSize(width: 800, height: 600))
        let autoW = ResizePreset(name: "300h", fit: .stretch, width: 0, height: 300)
        #expect(plan(4000, 3000, autoW).outputSize == CGSize(width: 400, height: 300))
        let percent = ResizePreset(name: "50%w", fit: .fit, width: 50, height: 0, unit: .percent)
        #expect(plan(4000, 3000, percent).outputSize == CGSize(width: 2000, height: 1500))
        let none = ResizePreset(name: "auto", width: 0, height: 0)
        #expect(plan(4000, 3000, none).unchanged)
        #expect(autoH.summary == "800 × auto px · fill")
    }

    @Test func shrinkOnlyNeverEnlarges() {
        let p = plan(800, 600, medium, shrinkOnly: true)
        #expect(p.unchanged)
        #expect(p.outputSize == CGSize(width: 800, height: 600))
        #expect(!plan(800, 600, medium).unchanged)
        #expect(plan(800, 600, medium).outputSize == CGSize(width: 1024, height: 768))
        // One side bigger is enough to keep the original (PowerToys rule).
        var stretch = medium
        stretch.fit = .stretch
        #expect(plan(2000, 700, stretch, shrinkOnly: true).unchanged)
        #expect(!plan(4000, 3000, medium, shrinkOnly: true).unchanged)
    }

    @Test func tinyResultsAreAtLeastOnePixel() {
        let p = plan(10_000, 10, ResizePreset(name: "x", fit: .fit, width: 100, height: 100))
        #expect(p.outputSize == CGSize(width: 100, height: 1))
    }

    // MARK: File names

    private func values(_ name: String = "example", size: String = "Small", w: Double = 854, h: Double = 480,
                        aw: Int = 854, ah: Int = 480) -> ResizeFileNamer.Values {
        ResizeFileNamer.Values(original: name, sizeName: size, selectedWidth: w, selectedHeight: h, actualWidth: aw, actualHeight: ah)
    }

    @Test func fileNameParameters() {
        #expect(ResizeFileNamer.components(format: "%1 (%2)", values: values()) == ["example (Small)"])
        #expect(ResizeFileNamer.components(format: "%1_%4", values: values(size: "Medium", w: 1366, h: 768)) == ["example_768"])
        #expect(ResizeFileNamer.components(format: "%1-%3x%4-%5x%6", values: values(aw: 853, ah: 480))
                == ["example-854x480-853x480"])
        #expect(ResizeFileNamer.components(format: "%1 %3%", values: values(w: 50)) == ["example 50%"])
        #expect(ResizeFileNamer.components(format: "%1 w%3", values: values(w: 2.5)) == ["example w2.5"])
        #expect(ResizeFileNamer.components(format: "%1 %3 %4", values: values(w: 800, h: 0)) == ["example 800"])
        #expect(ResizeFileNamer.components(format: "%9 %1", values: values()) == ["%9 example"])
    }

    @Test func fileNameSubfoldersAndSanitizing() {
        #expect(ResizeFileNamer.components(format: "%2/%1", values: values()) == ["Small", "example"])
        #expect(ResizeFileNamer.components(format: "%2\\%1", values: values()) == ["Small", "example"])
        #expect(ResizeFileNamer.components(format: "%1 (%2)", values: values(size: "A/B: c")) == ["example (A_B_ c)"])
        #expect(ResizeFileNamer.components(format: "../%1", values: values()) == ["example"])
        #expect(ResizeFileNamer.components(format: "", values: values()) == ["example"])
    }

    @Test func uniqueURLsAddANumber() {
        let base = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.jpg", "/tmp/x/a (2).jpg"]
        let url = ResizeFileNamer.uniqueURL(in: base, components: ["a"], pathExtension: "jpg") { taken.contains($0.path) }
        #expect(url.path == "/tmp/x/a (3).jpg")
        let sub = ResizeFileNamer.uniqueURL(in: base, components: ["Small", "a"], pathExtension: "png") { _ in false }
        #expect(sub.path == "/tmp/x/Small/a.png")
    }

    // MARK: Real images

    /// Writes a `w`×`h` image: red top-left quadrant, green top-right, blue bottom-left, white bottom-right.
    @discardableResult
    private func makeImage(_ url: URL, _ w: Int, _ h: Int, type: UTType, properties: [CFString: Any] = [:]) throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let hw = CGFloat(w) / 2, hh = CGFloat(h) / 2
        // Core Graphics is bottom-left: the top half is y >= hh.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: hh, width: hw, height: hh))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); ctx.fill(CGRect(x: hw, y: hh, width: hw, height: hh))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: hw, y: 0, width: hw, height: hh))
        let image = try #require(ctx.makeImage())
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    private struct Decoded {
        let width: Int
        let height: Int
        let props: [String: Any]
        let type: String
        let image: CGImage

        /// RGB at a pixel, top-left origin, 0…255.
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
            return (Int(px[0]), Int(px[1]), Int(px[2]))
        }
    }

    private func decode(_ url: URL) throws -> Decoded {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        return Decoded(width: image.width, height: image.height, props: props,
                       type: CGImageSourceGetType(src) as String? ?? "", image: image)
    }

    private func isRed(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
    private func isGreen(_ c: (Int, Int, Int)) -> Bool { c.0 < 60 && c.1 > 200 && c.2 < 60 }
    private func isBlue(_ c: (Int, Int, Int)) -> Bool { c.0 < 60 && c.1 < 60 && c.2 > 200 }
    private func isWhite(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 > 200 && c.2 > 200 }

    @Test func resizesPNGWithTheNameFormat() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("photo.png"), 400, 300, type: .png)
        var options = ResizeOptions()
        options.fileNameFormat = "%1 (%2) %5x%6"
        let out = try ImageResizerEngine.resize(urls: [src], preset: ResizePreset(name: "Small", width: 200, height: 200),
                                                options: options)
        #expect(out.map(\.lastPathComponent) == ["photo (Small) 200x150.png"])
        let d = try decode(out[0])
        #expect(d.width == 200 && d.height == 150)
        #expect(d.type == UTType.png.identifier)
        #expect(isRed(d.rgb(10, 10)) && isGreen(d.rgb(190, 10)) && isBlue(d.rgb(10, 140)) && isWhite(d.rgb(190, 140)))
        // The original is untouched; a second run doesn't overwrite the first copy.
        #expect(try decode(src).width == 400)
        let again = try ImageResizerEngine.resize(urls: [src], preset: ResizePreset(name: "Small", width: 200, height: 200),
                                                  options: options)
        #expect(again[0].lastPathComponent == "photo (Small) 200x150 (2).png")
    }

    @Test func fillCropsTheMiddleOfARealImage() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("wide.png"), 400, 100, type: .png)
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Square", fit: .fill, width: 100, height: 100),
                                                options: ResizeOptions())
        let d = try decode(out)
        #expect(d.width == 100 && d.height == 100)
        // The middle of a 400-wide picture straddles the red/green boundary.
        #expect(isRed(d.rgb(5, 5)) && isGreen(d.rgb(95, 5)))
    }

    @Test func exifOrientationIsAppliedAndReset() throws {
        let dir = try FileOpsScratch()
        // Raw 300×200, orientation 6: shown rotated 90° clockwise as 200×300.
        let src = try makeImage(dir.url.appendingPathComponent("rotated.jpg"), 300, 200, type: .jpeg,
                                properties: [kCGImagePropertyOrientation: 6])
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Half", fit: .stretch, width: 50, height: 50, unit: .percent),
                                                options: ResizeOptions())
        let d = try decode(out)
        #expect(d.width == 100 && d.height == 150)
        #expect((d.props[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
        // Raw top-left (red) is now top-right; raw top-right (green) bottom-right; raw bottom-left (blue) top-left.
        #expect(isRed(d.rgb(90, 10)))
        #expect(isGreen(d.rgb(90, 140)))
        #expect(isBlue(d.rgb(10, 10)))
        #expect(isWhite(d.rgb(10, 140)))
    }

    @Test func everyOrientationEndsUpUpright() throws {
        // For each orientation, where raw red (top-left) appears in the upright result.
        let redCorner: [Int: (x: Bool, y: Bool)] = [1: (false, false), 2: (true, false), 3: (true, true), 4: (false, true),
                                                   5: (false, false), 6: (true, false), 7: (true, true), 8: (false, true)]
        let dir = try FileOpsScratch()
        for o in 1...8 {
            let src = try makeImage(dir.url.appendingPathComponent("o\(o).png"), 120, 80, type: .png,
                                    properties: [kCGImagePropertyOrientation: o])
            let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Same", fit: .stretch, width: 100, height: 100, unit: .percent),
                                                    options: ResizeOptions())
            let d = try decode(out)
            let rotated = o >= 5
            #expect(d.width == (rotated ? 80 : 120) && d.height == (rotated ? 120 : 80), "orientation \(o)")
            let corner = try #require(redCorner[o])
            let x = corner.x ? d.width - 5 : 5, y = corner.y ? d.height - 5 : 5
            #expect(isRed(d.rgb(x, y)), "orientation \(o)")
        }
    }

    @Test func ignoreOrientationSwapsTheBoxForPortraitPictures() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("portrait.png"), 300, 400, type: .png)
        var options = ResizeOptions()
        options.ignoreOrientation = true
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Box", fit: .fit, width: 200, height: 150),
                                                options: options)
        let d = try decode(out)
        #expect(d.width == 150 && d.height == 200)
    }

    @Test func shrinkOnlyCopiesSmallPicturesAtTheirSize() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("small.png"), 80, 60, type: .png)
        var options = ResizeOptions()
        options.shrinkOnly = true
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Big", width: 800, height: 600), options: options)
        let d = try decode(out)
        #expect(d.width == 80 && d.height == 60)
    }

    @Test func metadataIsKeptOrRemoved() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("meta.jpg"), 200, 100, type: .jpeg, properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "TestCam"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.5, kCGImagePropertyGPSLatitudeRef: "N"],
        ])
        let preset = ResizePreset(name: "Half", width: 100, height: 50)
        let kept = try decode(try ImageResizerEngine.resize(url: src, preset: preset, options: ResizeOptions()))
        let tiff = kept.props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = kept.props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel as String] as? String == "TestCam")
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String == "2020:01:02 03:04:05")
        #expect(exif?[kCGImagePropertyExifPixelXDimension as String] as? Int == 100)
        #expect(kept.props[kCGImagePropertyGPSDictionary as String] != nil)

        var strip = ResizeOptions()
        strip.removeMetadata = true
        let removed = try decode(try ImageResizerEngine.resize(url: src, preset: preset, options: strip))
        let tiff2 = removed.props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif2 = removed.props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        #expect(tiff2?[kCGImagePropertyTIFFModel as String] == nil)
        #expect(exif2?[kCGImagePropertyExifDateTimeOriginal as String] == nil)
        #expect(removed.props[kCGImagePropertyGPSDictionary as String] == nil)
    }

    @Test func jpegQualityChangesTheFileSize() throws {
        let dir = try FileOpsScratch()
        // Noise compresses badly, so quality makes a clear difference.
        let w = 256, h = 256
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 1
        for i in 0..<bytes.count { seed = seed &* 1_664_525 &+ 1_013_904_223; bytes[i] = i % 4 == 3 ? 255 : UInt8(seed >> 24) }
        let ctx = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(ctx.makeImage())
        let src = dir.url.appendingPathComponent("noise.jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        func size(quality: Int) throws -> Int {
            var o = ResizeOptions()
            o.encoder.jpegQuality = quality
            o.fileNameFormat = "%1 q\(quality)"
            let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Same", fit: .fit, width: 200, height: 200), options: o)
            return try out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        #expect(try size(quality: 10) * 2 < size(quality: 95))
    }

    @Test func pngInterlacingAndTIFFCompression() throws {
        let dir = try FileOpsScratch()
        let png = try makeImage(dir.url.appendingPathComponent("a.png"), 64, 64, type: .png)
        var o = ResizeOptions()
        o.encoder.pngInterlace = .on
        let p = try decode(try ImageResizerEngine.resize(url: png, preset: ResizePreset(name: "s", width: 32, height: 32), options: o))
        let pngDict = p.props[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        #expect(pngDict?[kCGImagePropertyPNGInterlaceType as String] as? Int == 1)

        let tif = try makeImage(dir.url.appendingPathComponent("b.tiff"), 64, 64, type: .tiff)
        o.encoder.tiffCompression = .lzw
        let t = try decode(try ImageResizerEngine.resize(url: tif, preset: ResizePreset(name: "s", width: 32, height: 32), options: o))
        let tiffDict = t.props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        #expect(tiffDict?[kCGImagePropertyTIFFCompression as String] as? Int == 5)
        #expect(t.width == 32)
    }

    @Test func fallbackEncoderForUnwritableFormats() throws {
        let dir = try FileOpsScratch()
        // Radiance HDR can be read but not written by ImageIO.
        var hdr = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 4 +X 6\n".utf8)
        for _ in 0..<24 { hdr.append(contentsOf: [128, 64, 32, 129]) }
        let src = dir.url.appendingPathComponent("light.hdr")
        try hdr.write(to: src)
        var o = ResizeOptions()
        o.encoder.fallback = .tiff
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "2x", fit: .fit, width: 12, height: 8), options: o)
        #expect(out.pathExtension == "tiff")
        let d = try decode(out)
        #expect(d.type == UTType.tiff.identifier && d.width == 12 && d.height == 8)
    }

    @Test func replacingOriginalsAndKeepingTheDate() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("orig.png"), 400, 200, type: .png)
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: src.path)
        var o = ResizeOptions()
        o.replaceOriginals = true
        o.keepDateModified = true
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "s", width: 100, height: 100), options: o)
        #expect(out.path == src.path)
        #expect(try decode(src).width == 100)
        #expect(try dir.list() == ["orig.png"])
        let date = try src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(date.map { abs($0.timeIntervalSince(old)) < 1 } == true)
    }

    @Test func subfolderFormatAndDestination() throws {
        let dir = try FileOpsScratch()
        let src = try makeImage(dir.url.appendingPathComponent("pic.png"), 100, 100, type: .png)
        var o = ResizeOptions()
        o.fileNameFormat = "%2/%1"
        o.destination = dir.url.appendingPathComponent("out", isDirectory: true)
        let out = try ImageResizerEngine.resize(url: src, preset: ResizePreset(name: "Thumbs", width: 10, height: 10), options: o)
        #expect(out.path == dir.url.appendingPathComponent("out/Thumbs/pic.png").path)
    }

    @Test func batchReportsFailuresButWritesTheRest() throws {
        let dir = try FileOpsScratch()
        let good = try makeImage(dir.url.appendingPathComponent("good.png"), 50, 50, type: .png)
        let bad = try dir.make("bad.png", contents: "not an image")
        do {
            _ = try ImageResizerEngine.resize(urls: [bad, good], preset: ResizePreset(name: "s", width: 10, height: 10), options: ResizeOptions())
            Issue.record("expected a batch error")
        } catch let e as ImageResizerEngine.BatchError {
            #expect(e.outputs.map(\.lastPathComponent) == ["good (s).png"])
            #expect(e.failures.map(\.url) == [bad])
        }
    }

    @Test func animatedGIFKeepsItsFrames() throws {
        let dir = try FileOpsScratch()
        let url = dir.url.appendingPathComponent("anim.gif")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<3 {
            let ctx = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(red: CGFloat(i) / 2, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(dest))
        let out = try ImageResizerEngine.resize(url: url, preset: ResizePreset(name: "s", width: 20, height: 10), options: ResizeOptions())
        let src = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(src) == 3)
        #expect(try decode(out).width == 20)
    }

    // MARK: Settings

    @Test func settingsRoundTripAndSelection() throws {
        var s = ImageResizerSettings()
        #expect(s.selectedPreset.name == "Medium")
        s.selectedIndex = -1
        #expect(s.selectedPreset.name == "Custom")
        s.selectedIndex = 99
        #expect(s.selectedPreset.name == "Small")
        s.options.encoder.tiffCompression = .zip
        let back = try JSONDecoder().decode(ImageResizerSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(ResizePreset.defaults.map(\.summary) == ["854 × 480 px · fit", "1366 × 768 px · fit", "1920 × 1080 px · fit", "320 × 568 px · fit"])
    }
}
