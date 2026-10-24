import CoreGraphics
import Foundation

/// What to do with one image: scale to `scaledSize`, then keep `crop` (in the scaled image,
/// top-left origin) — or keep the original size when `unchanged`.
public struct ResizePlan: Equatable, Sendable {
    public var scaledSize: CGSize
    /// The kept part of the scaled image (Fill crops the overflow, centered).
    public var crop: CGRect
    /// True when the image keeps its size (shrink-only, or both sides auto).
    public var unchanged: Bool

    /// The pixel size written.
    public var outputSize: CGSize { crop.size }
}

/// PowerToys' size arithmetic (`ResizeOperation.Transform`), unit conversion included.
public enum ResizeMath {
    /// Converts a preset value to pixels for an image side of `original` pixels.
    public static func pixels(_ value: Double, unit: ResizeUnit, original: Double, dpi: Double) -> Double {
        switch unit {
        case .pixel: value
        case .percent: value * original / 100
        case .inch: value * dpi
        case .centimeter: value * dpi / 2.54
        }
    }

    /// - Parameters:
    ///   - source: the upright (orientation applied) pixel size.
    ///   - dpi: the image's resolution, used for inches and centimeters (72 when unknown).
    public static func plan(source: CGSize, preset: ResizePreset, shrinkOnly: Bool, ignoreOrientation: Bool,
                            dpi: Double = 72) -> ResizePlan {
        let ow = Double(source.width), oh = Double(source.height)
        let keep = ResizePlan(scaledSize: source, crop: CGRect(origin: .zero, size: source), unchanged: true)
        guard ow > 0, oh > 0 else { return keep }

        let autoW = preset.width <= 0, autoH = preset.height <= 0
        guard !(autoW && autoH) else { return keep }
        var width = autoW ? 0 : pixels(preset.width, unit: preset.unit, original: ow, dpi: dpi)
        var height = autoH ? 0 : pixels(preset.height, unit: preset.unit, original: oh, dpi: dpi)

        if ignoreOrientation, !autoW, !autoH, preset.unit != .percent,
           (ow < oh && width > height) || (ow > oh && width < height) {
            swap(&width, &height)
        }

        var scaleX = autoW ? 0 : width / ow
        var scaleY = autoH ? 0 : height / oh
        if autoW {
            scaleX = scaleY
        } else if autoH {
            scaleY = scaleX
        } else {
            switch preset.fit {
            case .fit: scaleX = min(scaleX, scaleY); scaleY = scaleX
            case .fill: scaleX = max(scaleX, scaleY); scaleY = scaleX
            case .stretch: break
            }
        }

        if shrinkOnly, preset.unit != .percent, scaleX >= 1 || scaleY >= 1 { return keep }

        let scaled = CGSize(width: max(1, (ow * scaleX).rounded()), height: max(1, (oh * scaleY).rounded()))
        var crop = CGRect(origin: .zero, size: scaled)
        if preset.fit == .fill, !autoW, !autoH {
            let w = max(1, min(scaled.width, width.rounded()))
            let h = max(1, min(scaled.height, height.rounded()))
            if w < scaled.width || h < scaled.height {
                crop = CGRect(x: ((scaled.width - w) / 2).rounded(.down), y: ((scaled.height - h) / 2).rounded(.down),
                              width: w, height: h)
            }
        }
        return ResizePlan(scaledSize: scaled, crop: crop, unchanged: false)
    }
}
