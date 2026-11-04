import CoreGraphics
import Foundation
import MacToysCore
import Testing
@testable import CameraMirror

@Suite struct CameraMirrorTests {
    let hd = CGSize(width: 1920, height: 1080)

    // MARK: Framing

    @Test func aspectFillCropsTheSidesOfAWidePicture() {
        let v = MirrorFraming.standard.visibleRect(source: hd, view: CGSize(width: 400, height: 300))
        #expect(abs(v.width - 0.75) < 1e-9)
        #expect(v.height == 1)
        #expect(abs(v.minX - 0.125) < 1e-9)
        #expect(v.minY == 0)
    }

    @Test func aspectFillCropsTopAndBottomInAWideView() {
        let v = MirrorFraming.standard.visibleRect(source: CGSize(width: 4, height: 3), view: CGSize(width: 1600, height: 900))
        #expect(v.width == 1)
        #expect(abs(v.height - 0.75) < 1e-9)
        #expect(abs(v.midY - 0.5) < 1e-9)
    }

    @Test func zoomShrinksTheVisibleRectAroundTheCenter() {
        let f = MirrorFraming(zoom: 2, center: CGPoint(x: 0.5, y: 0.45))
        let v = f.visibleRect(source: hd, view: CGSize(width: 400, height: 300))
        #expect(abs(v.width - 0.375) < 1e-9)
        #expect(abs(v.height - 0.5) < 1e-9)
        #expect(abs(v.midX - 0.5) < 1e-9)
        #expect(abs(v.midY - 0.45) < 1e-9)
    }

    @Test func centerIsClampedSoThePictureNeverEnds() {
        let f = MirrorFraming(zoom: 2, center: CGPoint(x: 0.02, y: 0.99))
        let v = f.visibleRect(source: hd, view: CGSize(width: 400, height: 300))
        #expect(v.minX == 0)
        #expect(abs(v.maxY - 1) < 1e-9)
        let clamped = f.clamped(source: hd, view: CGSize(width: 400, height: 300))
        #expect(abs(clamped.center.x - 0.1875) < 1e-9)
        #expect(abs(clamped.center.y - 0.75) < 1e-9)
    }

    @Test func zoomIsLimitedToItsRange() {
        let v = CGSize(width: 400, height: 300)
        #expect(MirrorFraming.standard.zoomed(by: 0.2, source: hd, view: v).zoom == 1)
        #expect(MirrorFraming(zoom: 2.5, center: CGPoint(x: 0.5, y: 0.5)).zoomed(by: 4, source: hd, view: v).zoom == 3)
        #expect(MirrorFraming(zoom: 9, center: CGPoint(x: 0.5, y: 0.5)).visibleRect(source: hd, view: v).width == 0.75 / 3)
    }

    @Test func layerFrameCoversTheViewWithThePicturesAspect() {
        let view = CGSize(width: 400, height: 300)
        for zoom in [1.0, 1.5, 2.0] {
            let f = MirrorFraming(zoom: zoom, center: CGPoint(x: 0.6, y: 0.4))
            let layer = f.layerFrame(source: hd, view: view)
            #expect(abs(layer.width / layer.height - 16.0 / 9.0) < 1e-6)
            #expect(layer.minX <= 0 && layer.minY <= 0)
            #expect(layer.maxX >= view.width - 1e-6 && layer.maxY >= view.height - 1e-6)
        }
        let standard = MirrorFraming.standard.layerFrame(source: hd, view: view)
        #expect(abs(standard.width - 400 / 0.75) < 1e-6)
        #expect(abs(standard.minX + 0.125 * 400 / 0.75) < 1e-6)
    }

    @Test func dragMovesThePictureWithThePointer() {
        let view = CGSize(width: 400, height: 300)
        let f = MirrorFraming(zoom: 2, center: CGPoint(x: 0.5, y: 0.5))
        // Drag right: the picture follows, so we look further left (center x decreases).
        let right = f.panned(by: CGSize(width: 40, height: 0), source: hd, view: view, mirrored: false)
        #expect(right.center.x < 0.5)
        // In a mirrored view the same drag looks further right in the camera picture.
        let mirrored = f.panned(by: CGSize(width: 40, height: 0), source: hd, view: view, mirrored: true)
        #expect(mirrored.center.x > 0.5)
        // Drag down: we see more of the top.
        let down = f.panned(by: CGSize(width: 0, height: 30), source: hd, view: view, mirrored: false)
        #expect(down.center.y < 0.5)
    }

    @Test func photoCropMatchesWhatTheMirrorShows() {
        let r = MirrorFraming.standard.cropRect(pixels: hd, view: CGSize(width: 400, height: 300))
        #expect(r == CGRect(x: 240, y: 0, width: 1440, height: 1080))
        let zoomed = MirrorFraming(zoom: 2, center: CGPoint(x: 0.5, y: 0.5)).cropRect(pixels: hd, view: CGSize(width: 400, height: 300))
        #expect(zoomed == CGRect(x: 600, y: 270, width: 720, height: 540))
    }

    @Test func framingIsStoredRounded() {
        var s = MirrorSettings()
        s.setFraming(MirrorFraming(zoom: 1.23456, center: CGPoint(x: 0.123456, y: 0.98765)))
        #expect(s.zoom == 1.23)
        #expect(s.centerX == 0.123)
        #expect(s.centerY == 0.988)
    }

    // MARK: Light check

    @Test func lightHintThresholds() {
        #expect(LightCheck.assess(LightSample(mean: 0.5, center: 0.5, edges: 0.5)) == .good)
        #expect(LightCheck.assess(LightSample(mean: 0.25, center: 0.22, edges: 0.3)) == .aBitDark)
        #expect(LightCheck.assess(LightSample(mean: 0.08, center: 0.06, edges: 0.1)) == .tooDark)
        #expect(LightCheck.assess(LightSample(mean: 0.6, center: 0.4, edges: 0.8)) == .backlit)
        #expect(LightCheck.assess(LightSample(mean: 0.95, center: 0.96, edges: 0.94)) == .tooBright)
        // Right at the dark threshold is still fine.
        #expect(LightCheck.assess(LightSample(mean: 0.3, center: LightCheck.darkCenter, edges: 0.3)) == .good)
        // A dark face against a dim room is dark, not backlit.
        #expect(LightCheck.assess(LightSample(mean: 0.3, center: 0.2, edges: 0.45)) == .aBitDark)
    }

    /// A BGRA buffer with one gray level inside `inner` (fractions of the frame) and another outside.
    private func buffer(width: Int, height: Int, inner: CGRect, innerGray: UInt8, outerGray: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let inside = inner.contains(CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height)))
                let g = inside ? innerGray : outerGray
                let i = (y * width + x) * 4
                bytes[i] = g; bytes[i + 1] = g; bytes[i + 2] = g
            }
        }
        return bytes
    }

    @Test func sampleMeasuresAUniformFrame() {
        let bytes = buffer(width: 160, height: 90, inner: .zero, innerGray: 0, outerGray: 128)
        let s = bytes.withUnsafeBytes { LightCheck.sample(bgra: $0.baseAddress!, width: 160, height: 90, bytesPerRow: 640) }
        #expect(abs(s.mean - 128.0 / 255) < 0.01)
        #expect(abs(s.center - s.mean) < 0.01)
        #expect(abs(s.edges - s.mean) < 0.01)
        #expect(LightCheck.assess(s) == .good)
    }

    @Test func sampleSeesABacklitFace() {
        let bytes = buffer(width: 160, height: 90, inner: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.65), innerGray: 70, outerGray: 235)
        let s = bytes.withUnsafeBytes { LightCheck.sample(bgra: $0.baseAddress!, width: 160, height: 90, bytesPerRow: 640) }
        #expect(s.center < 0.3)
        #expect(s.edges > 0.85)
        #expect(LightCheck.assess(s) == .backlit)
    }

    @Test func meterWaitsForTwoSamplesBeforeChanging() {
        var meter = LightMeter()
        meter.smoothing = 1 // no averaging: test the hysteresis alone
        let dark = LightSample(mean: 0.2, center: 0.2, edges: 0.2)
        let good = LightSample(mean: 0.5, center: 0.5, edges: 0.5)
        #expect(meter.add(good) == .good)
        #expect(meter.add(dark) == .good)
        #expect(meter.add(dark) == .aBitDark)
        #expect(meter.add(good) == .aBitDark)
        #expect(meter.add(dark) == .aBitDark)
        #expect(meter.add(good) == .aBitDark)
        #expect(meter.add(good) == .good)
        meter.reset()
        #expect(meter.hint == .good)
    }

    // MARK: Floating window

    @Test func circleWindowsAreSquare() {
        let size = FloatingGeometry.constrain(CGSize(width: 300, height: 180), shape: .circle, aspect: .sixteenNine,
                                              visible: CGSize(width: 1440, height: 875))
        #expect(size == CGSize(width: 300, height: 300))
    }

    @Test func aspectIsLockedToTheShape() {
        let visible = CGSize(width: 1440, height: 875)
        let wide = FloatingGeometry.constrain(CGSize(width: 320, height: 320), shape: .rounded, aspect: .sixteenNine, visible: visible)
        #expect(wide == CGSize(width: 320, height: 180))
        // Portrait shapes keep their height.
        let tall = FloatingGeometry.constrain(CGSize(width: 100, height: 400), shape: .rectangle, aspect: .portrait, visible: visible)
        #expect(tall == CGSize(width: 300, height: 400))
    }

    @Test func sizeStaysBetweenTheMinimumAndTheScreenMaximum() {
        let visible = CGSize(width: 1440, height: 875)
        let tiny = FloatingGeometry.constrain(CGSize(width: 20, height: 20), shape: .rounded, aspect: .fourThree, visible: visible)
        #expect(tiny.height == FloatingGeometry.minSide)
        #expect(tiny.width == 160)
        let huge = FloatingGeometry.constrain(CGSize(width: 5000, height: 5000), shape: .circle, aspect: .fourThree, visible: visible)
        #expect(huge.height <= visible.height * FloatingGeometry.maxScreenFraction + 0.5)
        #expect(huge.width == huge.height)
    }

    @Test func defaultFrameSitsInsideTheTopRight() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let f = FloatingGeometry.defaultFrame(in: visible, shape: .rounded, aspect: .fourThree)
        #expect(visible.contains(f))
        #expect(f.maxX == visible.maxX - 20)
        #expect(f.maxY == visible.maxY - 20)
        #expect(f.size == CGSize(width: 260, height: 195))
    }

    @Test func framesAreMovedBackOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let off = CGRect(x: 1400, y: -50, width: 200, height: 200)
        let fitted = FloatingGeometry.fit(off, in: visible)
        #expect(fitted == CGRect(x: 1240, y: 0, width: 200, height: 200))
    }

    @Test func cornerRadiiFollowTheShape() {
        #expect(FloatingGeometry.cornerRadius(shape: .circle, size: CGSize(width: 200, height: 200)) == 100)
        #expect(FloatingGeometry.cornerRadius(shape: .rounded, size: CGSize(width: 260, height: 195)) == 195 * 0.14)
        #expect(FloatingGeometry.cornerRadius(shape: .rounded, size: CGSize(width: 800, height: 600)) == 32)
        #expect(FloatingGeometry.cornerRadius(shape: .rectangle, size: CGSize(width: 800, height: 600)) == 6)
    }

    // MARK: Photos and settings

    @Test func photoNamesAreUnique() {
        let folder = URL(fileURLWithPath: "/tmp/photos")
        let date = Date(timeIntervalSince1970: 1_793_828_587) // 2026-11-04 21:43:07 UTC
        let utc = TimeZone(identifier: "UTC")!
        let first = MirrorPhoto.fileURL(in: folder, date: date, timeZone: utc, exists: { _ in false })
        #expect(first.lastPathComponent == "Mirror Photo 2026-11-04 21.43.07.jpg")
        var taken: Set<String> = [first.path]
        let second = MirrorPhoto.fileURL(in: folder, date: date, timeZone: utc, exists: { taken.contains($0.path) })
        #expect(second.lastPathComponent == "Mirror Photo 2026-11-04 21.43.07 2.jpg")
        taken.insert(second.path)
        let third = MirrorPhoto.fileURL(in: folder, date: date, timeZone: utc, exists: { taken.contains($0.path) })
        #expect(third.lastPathComponent == "Mirror Photo 2026-11-04 21.43.07 3.jpg")
    }

    @Test func croppedPhotosAreMirroredWhenAsked() throws {
        let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))   // left half red
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 0, width: 20, height: 30))  // right half blue
        let image = try #require(ctx.makeImage())
        let plain = try #require(MirrorPhoto.render(image, framing: .standard, viewSize: CGSize(width: 40, height: 30), mirrored: false))
        let flipped = try #require(MirrorPhoto.render(image, framing: .standard, viewSize: CGSize(width: 40, height: 30), mirrored: true))
        #expect(plain.width == 40 && flipped.width == 40)
        #expect((plain.color(atPixel: 2, 15)?.red ?? 0) > 0.9)
        #expect((flipped.color(atPixel: 2, 15)?.blue ?? 0) > 0.9)
    }

    @Test func settingsRoundTripKeepsAClearedShortcut() throws {
        var s = MirrorSettings()
        s.activation = nil
        s.shape = .circle
        s.floatingFrame = StoredFrame(CGRect(x: 10, y: 20, width: 260, height: 260))
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(MirrorSettings.self, from: data)
        #expect(back == s)
        #expect(back.activation == nil)
        #expect(MirrorSettings().activation == Shortcut(34, [.control, .option]))
    }
}
