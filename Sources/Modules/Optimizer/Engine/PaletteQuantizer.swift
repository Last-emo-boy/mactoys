import Foundation

/// A premultiplied RGBA color (each of r, g, b is at most a).
struct PaletteColor: Equatable, Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// From a little-endian packed pixel (`r | g << 8 | b << 16 | a << 24`).
    init(packed p: UInt32) {
        self.init(r: UInt8(p & 0xFF), g: UInt8((p >> 8) & 0xFF), b: UInt8((p >> 16) & 0xFF), a: UInt8(p >> 24))
    }

    var packed: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24 }

    /// Straight (non-premultiplied) components, as PNG stores them.
    var straight: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard a > 0 else { return (0, 0, 0, 0) }
        guard a < 255 else { return (r, g, b, a) }
        func un(_ c: UInt8) -> UInt8 { UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a))) }
        return (un(r), un(g), un(b), a)
    }
}

/// Reduces an image to a palette of at most 256 colors, like the lossy PNG tools do:
///
/// 1. Images that already have few enough colors get an exact palette (lossless).
/// 2. Otherwise a weighted color histogram is split by median cut, where each split cuts the box
///    with the largest perceptually weighted error along its widest channel at the weighted median.
/// 3. K-means passes over the histogram move each palette entry to the center of the colors it serves.
/// 4. Pixels are remapped with serpentine Floyd–Steinberg dithering. Dithering is selective: pixels
///    whose color is in the palette are kept exact and absorb no error, so flat areas of screenshots
///    stay clean (and compress well) while gradients and photos get smooth.
///
/// Works in premultiplied RGBA so fully transparent pixels collapse into one entry.
enum PaletteQuantizer {
    struct Result: Sendable {
        /// Premultiplied palette entries.
        var palette: [PaletteColor]
        /// One palette index per pixel, row by row.
        var indices: [UInt8]
        var width: Int
        var height: Int
        /// Mean squared error per channel against the input (0 for exact palettes).
        var meanSquaredError: Double
        /// True when every input color is in the palette.
        var isExact: Bool

        /// Peak signal-to-noise ratio in dB; infinite for exact palettes.
        var psnr: Double {
            meanSquaredError <= 0 ? .infinity : 10 * log10(255 * 255 / meanSquaredError)
        }
    }

    /// Channel weights for distances (green matters most to the eye, then red, then blue).
    /// Alpha is weighted high: wrong transparency shows as halos.
    static let weights = SIMD4<Float>(0.65, 1.0, 0.45, 1.0)

    /// - Parameters:
    ///   - rgba: tightly packed premultiplied RGBA8 pixels, `width * height * 4` bytes.
    ///   - maxColors: 2…256.
    ///   - dither: diffuse quantization error (selectively, see the type's notes).
    static func quantize(rgba: [UInt8], width: Int, height: Int, maxColors: Int = 256, dither: Bool = true) -> Result {
        let count = width * height
        precondition(rgba.count >= count * 4, "pixel buffer too small")
        let limit = min(256, max(2, maxColors))
        let pixels = packedPixels(rgba, count: count)
        if let exact = exact(pixels, width: width, height: height, limit: limit) { return exact }

        var entries = histogram(pixels)
        var palette = medianCut(&entries, colors: limit)
        palette = refine(palette, entries: entries, passes: 4)
        let colors = palette.map(Self.clampPremultiplied)
        let (indices, mse) = remap(pixels, width: width, height: height, palette: colors, dither: dither)
        return Result(palette: colors, indices: indices, width: width, height: height, meanSquaredError: mse, isExact: false)
    }

    /// The lossless palette of an image with at most `limit` colors, or nil.
    static func exact(rgba: [UInt8], width: Int, height: Int, limit: Int = 256) -> Result? {
        exact(packedPixels(rgba, count: width * height), width: width, height: height, limit: limit)
    }

    private static func exact(_ pixels: [UInt32], width: Int, height: Int, limit: Int) -> Result? {
        guard let palette = exactPalette(pixels, limit: limit) else { return nil }
        var lookup: [UInt32: UInt8] = [:]
        for (i, c) in palette.enumerated() { lookup[c.packed] = UInt8(i) }
        let indices = pixels.map { lookup[$0] ?? 0 }
        return Result(palette: palette, indices: indices, width: width, height: height, meanSquaredError: 0, isExact: true)
    }

    private static func packedPixels(_ rgba: [UInt8], count: Int) -> [UInt32] {
        rgba.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian }
        }
    }

    // MARK: Exact palettes

    /// The distinct colors when there are at most `limit`, most frequent first; nil otherwise.
    static func exactPalette(_ pixels: [UInt32], limit: Int) -> [PaletteColor]? {
        var counts: [UInt32: Int] = [:]
        counts.reserveCapacity(limit * 2)
        for p in pixels {
            counts[p, default: 0] += 1
            if counts.count > limit { return nil }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { PaletteColor(packed: $0.key) }
    }

    // MARK: Histogram

    struct Entry {
        var color: SIMD4<Float>
        var weight: Float
    }

    /// Colors bucketed at 6 bits per channel, each bucket holding the mean of its exact colors.
    /// Very large images are sampled: two million pixels describe the distribution well.
    static func histogram(_ pixels: [UInt32]) -> [Entry] {
        let step = max(1, pixels.count / 2_000_000)
        var slot: [UInt32: Int] = [:]
        var sums: [SIMD4<Float>] = []
        var weights: [Float] = []
        var i = 0
        while i < pixels.count {
            let p = pixels[i]
            let key = (p >> 2) & 0x3F3F_3F3F
            let c = SIMD4<Float>(Float(p & 0xFF), Float((p >> 8) & 0xFF), Float((p >> 16) & 0xFF), Float(p >> 24))
            if let s = slot[key] {
                sums[s] += c
                weights[s] += 1
            } else {
                slot[key] = sums.count
                sums.append(c)
                weights.append(1)
            }
            i += step
        }
        return zip(sums, weights).map { Entry(color: $0 / $1, weight: $1) }
    }

    // MARK: Median cut

    private struct Box {
        var lo: Int
        var hi: Int
        var error: Float
        var channel: Int
        var mean: SIMD4<Float>
    }

    private static func describe(_ entries: ArraySlice<Entry>, lo: Int, hi: Int) -> Box {
        var total: Float = 0
        var sum = SIMD4<Float>(repeating: 0)
        for e in entries { sum += e.color * e.weight; total += e.weight }
        let mean = total > 0 ? sum / total : .zero
        var variance = SIMD4<Float>(repeating: 0)
        for e in entries {
            let d = e.color - mean
            variance += d * d * e.weight
        }
        let weighted = variance * weights
        var channel = 0
        for c in 1..<4 where weighted[c] > weighted[channel] { channel = c }
        return Box(lo: lo, hi: hi, error: weighted.sum(), channel: channel, mean: mean)
    }

    static func medianCut(_ entries: inout [Entry], colors: Int) -> [SIMD4<Float>] {
        guard !entries.isEmpty else { return [] }
        var boxes = [describe(entries[...], lo: 0, hi: entries.count)]
        while boxes.count < colors {
            // The splittable box with the most error.
            guard let pick = boxes.indices.filter({ boxes[$0].hi - boxes[$0].lo > 1 && boxes[$0].error > 0 })
                .max(by: { boxes[$0].error < boxes[$1].error }) else { break }
            let box = boxes[pick]
            let ch = box.channel
            entries[box.lo..<box.hi].sort { $0.color[ch] < $1.color[ch] }
            // Weighted median, keeping at least one entry on each side.
            var half: Float = 0
            for e in entries[box.lo..<box.hi] { half += e.weight }
            half /= 2
            var acc: Float = 0
            var split = box.lo + 1
            for i in box.lo..<(box.hi - 1) {
                acc += entries[i].weight
                split = i + 1
                if acc >= half { break }
            }
            boxes[pick] = describe(entries[box.lo..<split], lo: box.lo, hi: split)
            boxes.append(describe(entries[split..<box.hi], lo: split, hi: box.hi))
        }
        return boxes.map(\.mean)
    }

    // MARK: K-means

    static func refine(_ palette: [SIMD4<Float>], entries: [Entry], passes: Int) -> [SIMD4<Float>] {
        var palette = palette
        for _ in 0..<passes {
            var sums = [SIMD4<Float>](repeating: .zero, count: palette.count)
            var totals = [Float](repeating: 0, count: palette.count)
            for e in entries {
                let i = nearest(e.color, in: palette)
                sums[i] += e.color * e.weight
                totals[i] += e.weight
            }
            var moved = false
            for i in palette.indices where totals[i] > 0 {
                let next = sums[i] / totals[i]
                if next != palette[i] { moved = true }
                palette[i] = next
            }
            if !moved { break }
        }
        return palette
    }

    private static func nearest(_ c: SIMD4<Float>, in palette: [SIMD4<Float>]) -> Int {
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, p) in palette.enumerated() {
            let d = c - p
            let distance = (d * d * weights).sum()
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return best
    }

    private static func clampPremultiplied(_ c: SIMD4<Float>) -> PaletteColor {
        func byte(_ v: Float, max m: UInt8 = 255) -> UInt8 { UInt8(min(Float(m), max(0, v.rounded()))) }
        let a = byte(c.w)
        return PaletteColor(r: byte(c.x, max: a), g: byte(c.y, max: a), b: byte(c.z, max: a), a: a)
    }

    // MARK: Remapping

    /// Maps each pixel to a palette index; returns the indices and the mean squared error.
    static func remap(_ pixels: [UInt32], width: Int, height: Int, palette: [PaletteColor], dither: Bool) -> ([UInt8], Double) {
        var finder = NearestColor(palette)
        var indices = [UInt8](repeating: 0, count: pixels.count)
        var squaredError: Double = 0
        let strength: Float = 0.85
        // Error rows padded by one pixel on each side.
        var current = [SIMD4<Float>](repeating: .zero, count: width + 2)
        var next = current
        let entries = palette.map { SIMD4<Float>(Float($0.r), Float($0.g), Float($0.b), Float($0.a)) }

        for y in 0..<height {
            let forward = y % 2 == 0
            var x = forward ? 0 : width - 1
            let dx = forward ? 1 : -1
            for _ in 0..<width {
                let i = y * width + x
                let p = pixels[i]
                let (exact, exactDistance) = finder.nearest(p)
                var chosen = exact
                if exactDistance > 0, dither {
                    let original = SIMD4<Float>(Float(p & 0xFF), Float((p >> 8) & 0xFF), Float((p >> 16) & 0xFF), Float(p >> 24))
                    var v = original + current[x + 1] * strength
                    v.w = min(255, max(0, v.w))
                    v.x = min(v.w, max(0, v.x))
                    v.y = min(v.w, max(0, v.y))
                    v.z = min(v.w, max(0, v.z))
                    let rounded = UInt32(v.x.rounded()) | UInt32(v.y.rounded()) << 8 | UInt32(v.z.rounded()) << 16
                        | UInt32(v.w.rounded()) << 24
                    chosen = finder.nearest(rounded).index
                    let e = v - entries[chosen]
                    current[x + 1 + dx] += e * (7.0 / 16)
                    next[x + 1 - dx] += e * (3.0 / 16)
                    next[x + 1] += e * (5.0 / 16)
                    next[x + 1 + dx] += e * (1.0 / 16)
                }
                indices[i] = UInt8(chosen)
                let q = palette[chosen]
                let dr = Double(Int(p & 0xFF) - Int(q.r)), dg = Double(Int((p >> 8) & 0xFF) - Int(q.g))
                let db = Double(Int((p >> 16) & 0xFF) - Int(q.b)), da = Double(Int(p >> 24) - Int(q.a))
                squaredError += dr * dr + dg * dg + db * db + da * da
                x += dx
            }
            swap(&current, &next)
            for k in next.indices { next[k] = .zero }
        }
        let mse = pixels.isEmpty ? 0 : squaredError / Double(pixels.count * 4)
        return (indices, mse)
    }
}

/// Nearest palette entry under the weighted distance, with a direct-mapped cache: screenshots and
/// even dithered photos repeat colors a lot. The search walks out from the entry closest in green and
/// stops once green alone can't beat the best match.
struct NearestColor {
    private let colors: [SIMD4<Int32>]     // sorted by green
    private let order: [Int]               // sorted position → palette index
    private var cacheKeys: [UInt64]
    private var cacheValues: [UInt32]      // index | distance << 8 (distance saturated)
    private static let w = SIMD4<Int32>(13, 20, 9, 20)   // ≈ PaletteQuantizer.weights × 20

    init(_ palette: [PaletteColor]) {
        let indexed = palette.enumerated().map { ($0.offset, SIMD4<Int32>(Int32($0.element.r), Int32($0.element.g),
                                                                         Int32($0.element.b), Int32($0.element.a))) }
            .sorted { $0.1.y < $1.1.y }
        colors = indexed.map(\.1)
        order = indexed.map(\.0)
        cacheKeys = [UInt64](repeating: .max, count: 1 << 16)
        cacheValues = [UInt32](repeating: 0, count: 1 << 16)
    }

    /// The palette index nearest to a packed premultiplied pixel and its weighted distance.
    mutating func nearest(_ p: UInt32) -> (index: Int, distance: Int32) {
        let slot = Int((p &* 2_654_435_761) >> 16)
        if cacheKeys[slot] == UInt64(p) {
            let v = cacheValues[slot]
            return (Int(v & 0xFF), Int32(v >> 8))
        }
        let c = SIMD4<Int32>(Int32(p & 0xFF), Int32((p >> 8) & 0xFF), Int32((p >> 16) & 0xFF), Int32(p >> 24))
        // Binary search the first entry with green ≥ c.g.
        var lo = 0, hi = colors.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if colors[mid].y < c.y { lo = mid + 1 } else { hi = mid }
        }
        var best = 0
        var bestDistance = Int32.max
        var up = lo, down = lo - 1
        while up < colors.count || down >= 0 {
            if up < colors.count {
                let dg = colors[up].y - c.y
                if dg * dg * Self.w.y >= bestDistance { up = colors.count } else {
                    let d = colors[up] &- c
                    let distance = (d &* d &* Self.w).wrappedSum()
                    if distance < bestDistance { bestDistance = distance; best = up }
                    up += 1
                }
            }
            if down >= 0 {
                let dg = c.y - colors[down].y
                if dg * dg * Self.w.y >= bestDistance { down = -1 } else {
                    let d = colors[down] &- c
                    let distance = (d &* d &* Self.w).wrappedSum()
                    if distance < bestDistance { bestDistance = distance; best = down }
                    down -= 1
                }
            }
        }
        let index = order[best]
        cacheKeys[slot] = UInt64(p)
        cacheValues[slot] = UInt32(index) | UInt32(min(bestDistance, 0xFF_FFFF)) << 8
        return (index, bestDistance)
    }
}
