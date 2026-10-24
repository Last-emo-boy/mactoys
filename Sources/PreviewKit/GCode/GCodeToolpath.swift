import CoreGraphics
import Foundation
import ImageIO

/// An image embedded by the slicer (PrusaSlicer, Cura, OrcaSlicer, binary G-code thumbnail blocks).
public struct GCodeThumbnail: Sendable, Equatable {
    public enum Format: String, Sendable { case png, jpg, qoi }

    public var width: Int
    public var height: Int
    public var format: Format
    public var data: Data

    public init(width: Int, height: Int, format: Format, data: Data) {
        self.width = width
        self.height = height
        self.format = format
        self.data = data
    }

    public func image() -> CGImage? { ImageUtil.image(from: data) }
}

/// Parsed print/toolpath: points connected by moves, plus slicer metadata.
///
/// Points are stored as parallel arrays to keep large files compact: `xs[k], ys[k], zs[k]` is the
/// end of move `k` (which starts at point `k - 1`); point 0 is the start position.
public struct GCodeToolpath: Sendable {
    public enum MoveKind: UInt8, Sendable {
        /// G0 rapid move.
        case rapid = 0
        /// Linear/arc move that deposits filament.
        case extrude = 1
        /// G1/G2/G3 without extrusion: a travel in a 3D print, a cut in CNC/laser files without `E`.
        case feed = 3
    }

    public var xs: [Float] = [0]
    public var ys: [Float] = [0]
    public var zs: [Float] = [0]
    /// Kind of the move ending at each point (index 0 unused).
    public var kinds: [MoveKind] = [.rapid]
    /// Whether any move extruded (false for CNC/laser G-code).
    public var hasExtrusion = false
    public var layerCount = 0
    public var filamentMM: Double = 0
    public var estimatedTime: String?
    public var slicer: String?
    public var lineCount = 0
    /// The point limit was hit; the rest of the file was not drawn.
    public var truncated = false
    public var thumbnails: [GCodeThumbnail] = []

    public init() {}

    public var moveCount: Int { max(0, kinds.count - 1) }

    /// Whether a move counts as part of the object (extrusion, or cutting when there is no extrusion).
    public func isWorking(_ kind: MoveKind) -> Bool {
        kind == .extrude || (!hasExtrusion && kind == .feed)
    }

    /// Bounds (min, max) of the working moves, or of all moves when there are none.
    public var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var any = false
        for pass in 0..<2 {
            for k in 1..<max(1, kinds.count) where pass == 1 || isWorking(kinds[k]) {
                for j in [k - 1, k] {
                    let p = SIMD3(xs[j], ys[j], zs[j])
                    lo = simd_min(lo, p)
                    hi = simd_max(hi, p)
                }
                any = true
            }
            if any { return (lo, hi) }
        }
        return nil
    }

    /// The largest embedded thumbnail.
    public var bestThumbnail: GCodeThumbnail? {
        thumbnails.max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Human summary lines for previews and the Peek footer.
    public var summary: [(String, String)] {
        var rows: [(String, String)] = []
        if let slicer { rows.append(("Slicer", slicer)) }
        if hasExtrusion, layerCount > 0 { rows.append(("Layers", "\(layerCount)")) }
        if let b = bounds {
            let d = b.max - b.min
            rows.append(("Size", String(format: "%.1f × %.1f × %.1f mm", d.x, d.y, d.z)))
        }
        if filamentMM > 0 { rows.append(("Filament", String(format: "%.2f m", filamentMM / 1000))) }
        if let estimatedTime { rows.append(("Print time", estimatedTime)) }
        rows.append(("Moves", NumberFormatter.localizedString(from: NSNumber(value: moveCount), number: .decimal)))
        return rows
    }
}

private func simd_min(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a.replacing(with: b, where: b .< a) }
private func simd_max(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a.replacing(with: b, where: b .> a) }
