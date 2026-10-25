import Foundation
import Testing
@testable import ScreenRuler
@testable import MacToysCore

@Suite struct ScreenRulerTests {
    /// RGBA word for a gray level (little-endian byte order R, G, B, A).
    private func gray(_ v: Int, alpha: Int = 255) -> UInt32 {
        UInt32(v) | UInt32(v) << 8 | UInt32(v) << 16 | UInt32(alpha) << 24
    }

    private func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    /// A white canvas with filled rectangles painted on top, in order.
    private func canvas(_ w: Int, _ h: Int, background: UInt32? = nil,
                        rects: [(PixelRect, UInt32)] = []) -> PixelBuffer {
        var px = [UInt32](repeating: background ?? gray(255), count: w * h)
        for (r, color) in rects {
            for y in r.top...r.bottom { for x in r.left...r.right { px[y * w + x] = color } }
        }
        return PixelBuffer(width: w, height: h, pixels: px)
    }

    // MARK: Pixel comparison

    @Test func perChannelAndSummedTolerance() {
        let a = rgb(100, 100, 100), b = rgb(110, 95, 100)
        #expect(EdgeDetector.close(a, b, tolerance: 10, perChannel: true))
        #expect(!EdgeDetector.close(a, b, tolerance: 9, perChannel: true))
        #expect(EdgeDetector.close(a, b, tolerance: 15, perChannel: false))
        #expect(!EdgeDetector.close(a, b, tolerance: 14, perChannel: false))
        #expect(EdgeDetector.close(a, a, tolerance: 0, perChannel: false))
        #expect(!EdgeDetector.close(gray(0), gray(0, alpha: 0), tolerance: 254, perChannel: true))
    }

    // MARK: Solid blocks

    @Test func solidBlockBounds() {
        let block = PixelRect(left: 10, top: 5, right: 29, bottom: 24)
        let img = canvas(50, 40, rects: [(block, rgb(255, 45, 85))])
        #expect(EdgeDetector.edges(in: img, x: 15, y: 15, tolerance: 0, perChannel: false) == block)
        #expect(EdgeDetector.edges(in: img, x: 29, y: 24, tolerance: 30, perChannel: true) == block)
        #expect(block.width == 20 && block.height == 20)
    }

    @Test func spacingBetweenBlocksReachesTheirEdges() {
        let left = PixelRect(left: 0, top: 0, right: 9, bottom: 39)
        let right = PixelRect(left: 40, top: 0, right: 49, bottom: 39)
        let img = canvas(50, 40, rects: [(left, gray(0)), (right, gray(0))])
        let r = EdgeDetector.edges(in: img, x: 25, y: 20, tolerance: 10, perChannel: false)
        #expect(r.left == 10 && r.right == 39)
        #expect(r.top == 0 && r.bottom == 39)
        #expect(r.width == 30)
    }

    @Test func openCanvasRunsToTheImageBorder() {
        let img = canvas(30, 20)
        #expect(EdgeDetector.edges(in: img, x: 4, y: 4, tolerance: 0, perChannel: true)
                == PixelRect(left: 0, top: 0, right: 29, bottom: 19))
    }

    @Test func startIsClampedInsideTheBorder() {
        // A one-pixel frame: starting on it would otherwise measure the frame itself.
        let img = canvas(20, 20, background: gray(0), rects: [(PixelRect(left: 1, top: 1, right: 18, bottom: 18), gray(255))])
        #expect(EdgeDetector.edges(in: img, x: 0, y: 0, tolerance: 0, perChannel: true)
                == PixelRect(left: 1, top: 1, right: 18, bottom: 18))
    }

    @Test func tinyImagesDoNotCrash() {
        let one = PixelBuffer(width: 1, height: 1, pixels: [gray(10)])
        #expect(EdgeDetector.edges(in: one, x: 5, y: -3, tolerance: 0, perChannel: true)
                == PixelRect(left: 0, top: 0, right: 0, bottom: 0))
        let two = PixelBuffer(width: 2, height: 1, pixels: [gray(10), gray(10)])
        #expect(EdgeDetector.edges(in: two, x: 1, y: 0, tolerance: 0, perChannel: true).width == 2)
    }

    // MARK: Gradients and tolerance

    /// 256 columns, each one gray level brighter than the last.
    private var horizontalGradient: PixelBuffer {
        var px: [UInt32] = []
        for _ in 0..<8 { for x in 0..<256 { px.append(gray(x)) } }
        return PixelBuffer(width: 256, height: 8, pixels: px)
    }

    @Test func gradientExtendsByTolerancePerChannel() {
        let g = horizontalGradient
        // Every step of one level differs by 1 per channel; compared to the start pixel, the
        // run stops once the accumulated difference exceeds the tolerance.
        let r = EdgeDetector.edges(in: g, x: 100, y: 4, tolerance: 15, perChannel: true)
        #expect(r.left == 85 && r.right == 115)
        #expect(r.top == 0 && r.bottom == 7)
        let zero = EdgeDetector.edges(in: g, x: 100, y: 4, tolerance: 0, perChannel: true)
        #expect(zero.left == 100 && zero.right == 100)
    }

    @Test func gradientSummedChannelsAreStricter() {
        // R, G and B all change, so the summed difference grows three times as fast.
        let r = EdgeDetector.edges(in: horizontalGradient, x: 100, y: 4, tolerance: 15, perChannel: false)
        #expect(r.left == 95 && r.right == 105)
    }

    @Test func higherToleranceSwallowsSoftShadows() {
        // A box with a 3-pixel soft shadow (each ring 6 levels darker than the background).
        let box = PixelRect(left: 20, top: 20, right: 39, bottom: 39)
        var rects: [(PixelRect, UInt32)] = []
        for i in 0..<3 {
            let d = 3 - i
            rects.append((PixelRect(left: box.left - d, top: box.top - d, right: box.right + d, bottom: box.bottom + d),
                          gray(255 - 6 * (3 - d + 1))))
        }
        rects.append((box, gray(40)))
        let img = canvas(60, 60, rects: rects)
        let strict = EdgeDetector.edges(in: img, x: 5, y: 30, tolerance: 3, perChannel: true)
        #expect(strict.right == 16)
        let loose = EdgeDetector.edges(in: img, x: 5, y: 30, tolerance: 20, perChannel: true)
        #expect(loose.right == 19)
    }

    @Test func dragSpansEitherDirection() {
        #expect(PixelRect.spanning(30, 5, 10, 25) == PixelRect(left: 10, top: 5, right: 30, bottom: 25))
        #expect(PixelRect.spanning(7, 7, 7, 7).width == 1)
    }

    // MARK: Units and text

    @Test func unitConversion() {
        // A 2× display 302.4 mm wide with 3024 backing pixels: exactly 254 pixels per inch.
        let m = DisplayMetrics(pixelsPerPoint: 2, pixelWidth: 3024, physicalWidthMM: 302.4)
        #expect(abs(m.pixelsPerInch - 254) < 1e-9)
        #expect(abs(m.convert(254, to: .inches) - 1) < 1e-9)
        #expect(abs(m.convert(254, to: .centimeters) - 2.54) < 1e-9)
        #expect(abs(m.convert(254, to: .millimeters) - 25.4) < 1e-9)
        #expect(m.convert(236, to: .points) == 118)
        let unknown = DisplayMetrics(pixelsPerPoint: 1, pixelsPerInch: 0)
        #expect(unknown.convert(144, to: .inches) == 2)
    }

    @Test func labels() {
        let m = DisplayMetrics(pixelsPerPoint: 2, pixelsPerInch: 254)
        let en = Locale(identifier: "en_US")
        #expect(MeasurementText.label(width: 236, height: 250, extra: .none, metrics: m, locale: en) == "236 × 250 px")
        #expect(MeasurementText.label(width: 236, height: nil, extra: .none, metrics: m, locale: en) == "236 px")
        #expect(MeasurementText.label(width: nil, height: 250, extra: .points, metrics: m, locale: en) == "250 px\n125 pt")
        #expect(MeasurementText.label(width: 236, height: 250, extra: .inches, metrics: m, locale: en) == "236 × 250 px\n0.9291 × 0.9843 in")
        #expect(MeasurementText.label(width: 254, height: 127, extra: .centimeters, metrics: m, locale: en) == "254 × 127 px\n2.54 × 1.27 cm")
        #expect(MeasurementText.clipboard(width: 236, height: 250) == "236 × 250")
        #expect(MeasurementText.clipboard(width: nil, height: 250) == "250")
        #expect(MeasurementText.number(1234.4, locale: en) == "1234")
        #expect(MeasurementText.number(0.00123, locale: en) == "0.00123")
        #expect(MeasurementText.number(12345, locale: en) == "12345")
    }

    @Test func labelsFollowTheLocale() {
        let m = DisplayMetrics(pixelsPerPoint: 2, pixelsPerInch: 254)
        let de = Locale(identifier: "de_DE")
        #expect(MeasurementText.number(0.00123, locale: de) == "0,00123")
        let label = MeasurementText.label(width: 254, height: 127, extra: .centimeters, metrics: m, locale: de)
        #expect(label.hasPrefix("254 × 127 px\n2,54 × 1,27"))
        let ru = MeasurementText.label(width: 254, height: 127, extra: .centimeters, metrics: m, locale: Locale(identifier: "ru_RU"))
        #expect(ru.hasSuffix("см"))
    }

    @Test func settingsRoundTrip() throws {
        var s = ScreenRulerSettings()
        s.defaultMode = .spacing
        s.extraUnit = .centimeters
        let back = try JSONDecoder().decode(ScreenRulerSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(RulerDefaultMode.spacing.tool == .spacing && RulerDefaultMode.none.tool == nil)
        #expect(RulerTool.horizontal.measuresWidth && !RulerTool.horizontal.measuresHeight)
    }
}
