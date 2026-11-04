import CoreGraphics
import Foundation

/// Sizes for downscaling images and videos.
enum DownscaleMath {
    /// The steps "Downscale" walks through on a result card: 75 %, 50 %, then down by tenths to 10 %.
    static let steps: [Double] = [0.75, 0.5, 0.4, 0.3, 0.2, 0.1]

    /// The next smaller step after `factor` (relative to the original), or nil at the smallest.
    static func nextFactor(after factor: Double) -> Double? {
        steps.first { $0 < factor - 0.001 }
    }

    /// The size `size` scales to: limited to `maxSide` on its longest side and multiplied by `factor`.
    /// Never upscales; keeps the aspect ratio; at least 1 × 1.
    static func target(_ size: CGSize, maxSide: Int? = nil, factor: Double = 1) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var scale = min(1, max(0.01, factor))
        if let maxSide, maxSide > 0 {
            scale = min(scale, Double(maxSide) / Double(max(size.width, size.height)))
        }
        guard scale < 1 else { return size }
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// Like `target`, but limits the short side (video resolutions are named by it: 1080p) and rounds
    /// both sides down to even numbers, which the H.264 and HEVC encoders need.
    static func videoTarget(_ size: CGSize, shortSide: Int?, factor: Double) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var scale = min(1, max(0.01, factor))
        if let shortSide, shortSide > 0 {
            scale = min(scale, Double(shortSide) / Double(min(size.width, size.height)))
        }
        func even(_ v: CGFloat) -> CGFloat { max(2, (v / 2).rounded(.down) * 2) }
        return CGSize(width: even((size.width * scale).rounded()), height: even((size.height * scale).rounded()))
    }
}

/// Whether an optimized file is worth keeping.
enum SizeGate {
    /// Results must be at least 1 % smaller than the original; anything less isn't worth a re-encode.
    static let minimumSaving = 0.01

    static func keeps(original: Int64, candidate: Int64) -> Bool {
        candidate > 0 && original > 0 && Double(candidate) <= Double(original) * (1 - minimumSaving)
    }

    /// Fraction saved, 0.74 for 74 % smaller (negative when larger).
    static func saving(original: Int64, result: Int64) -> Double {
        original > 0 ? 1 - Double(result) / Double(original) : 0
    }
}

/// File names for results.
enum OutputNamer {
    /// Where an optimized file goes. Replacing keeps the path (with the new extension if the format
    /// changed); copies are named `name-optimized.ext`. `reusing` is the job's previous result, which
    /// may be overwritten.
    static func optimizedURL(for original: URL, fileExtension ext: String, mode: OutputMode, reusing previous: URL? = nil,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        switch mode {
        case .replace:
            let same = folder.appendingPathComponent(base).appendingPathExtension(ext)
            if same.path == original.path || same.path == previous?.path { return same }
            return unique(in: folder, base: base, ext: ext, reusing: previous, exists: exists)
        case .alongside:
            return unique(in: folder, base: "\(base)-optimized", ext: ext, reusing: previous, exists: exists)
        }
    }

    /// Where a converted copy goes: the same name with the new extension, numbered when taken.
    static func convertedURL(for original: URL, fileExtension ext: String, reusing previous: URL? = nil,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        unique(in: original.deletingLastPathComponent(), base: original.deletingPathExtension().lastPathComponent,
               ext: ext, reusing: previous, exists: { $0.path == original.path || exists($0) })
    }

    /// `base.ext`, else `base 2.ext`, `base 3.ext`… (as the Finder numbers copies).
    static func unique(in folder: URL, base: String, ext: String, reusing previous: URL? = nil,
                       exists: (URL) -> Bool) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) \(n)"
            let url = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if url.path == previous?.path || !exists(url) { return url }
            n += 1
        }
    }
}
