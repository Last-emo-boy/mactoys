import Foundation
import UniformTypeIdentifiers

/// How an image is fitted into the preset's box.
public enum ResizeFit: String, Codable, CaseIterable, Sendable {
    /// Fills the whole box, keeping proportions; the overflow is cropped (centered).
    case fill
    /// Fits the whole image inside the box, keeping proportions; nothing is cropped.
    case fit
    /// Fills the whole box, distorting proportions as needed; nothing is cropped.
    case stretch

    public var title: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        }
    }
}

public enum ResizeUnit: String, Codable, CaseIterable, Sendable {
    case pixel, percent, centimeter, inch

    public var title: String {
        switch self {
        case .pixel: "Pixels"
        case .percent: "Percent"
        case .centimeter: "Centimeters"
        case .inch: "Inches"
        }
    }

    public var symbol: String {
        switch self {
        case .pixel: "px"
        case .percent: "%"
        case .centimeter: "cm"
        case .inch: "in"
        }
    }
}

/// A named size. A width or height of 0 means "auto": proportional to the other side.
public struct ResizePreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var fit: ResizeFit
    public var width: Double
    public var height: Double
    public var unit: ResizeUnit

    public init(id: UUID = UUID(), name: String, fit: ResizeFit = .fit, width: Double, height: Double,
                unit: ResizeUnit = .pixel) {
        self.id = id
        self.name = name
        self.fit = fit
        self.width = width
        self.height = height
        self.unit = unit
    }

    public var hasAutoSide: Bool { width <= 0 || height <= 0 }

    /// "1366 × 768 px · fit", "50 % · stretch", "800 × auto px · fit".
    public var summary: String {
        func f(_ v: Double) -> String { v <= 0 ? "auto" : ResizeFileNamer.format(v) }
        return "\(f(width)) × \(f(height)) \(unit.symbol) · \(fit.rawValue)"
    }

    /// PowerToys' default sizes.
    public static let defaults: [ResizePreset] = [
        ResizePreset(name: "Small", width: 854, height: 480),
        ResizePreset(name: "Medium", width: 1366, height: 768),
        ResizePreset(name: "Large", width: 1920, height: 1080),
        ResizePreset(name: "Phone", width: 320, height: 568),
    ]

    public static let defaultCustom = ResizePreset(name: "Custom", width: 1024, height: 640)
}

/// The format used when the original one can't be written (for example a RAW photo or a PDF).
public enum FallbackEncoder: String, Codable, CaseIterable, Sendable {
    case png, jpeg, tiff, bmp, gif, heic

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .gif: "GIF"
        case .heic: "HEIC"
        }
    }

    public var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        case .heic: .heic
        }
    }
}

public enum PNGInterlace: String, Codable, CaseIterable, Sendable {
    case `default`, on, off

    public var title: String { rawValue.capitalized }
}

public enum TIFFCompression: String, Codable, CaseIterable, Sendable {
    case `default`, none, ccitt3, ccitt4, lzw, rle, zip

    public var title: String {
        switch self {
        case .default: "Default"
        case .none: "None"
        case .ccitt3: "CCITT3"
        case .ccitt4: "CCITT4"
        case .lzw: "LZW"
        case .rle: "RLE (PackBits)"
        case .zip: "Zip (Deflate)"
        }
    }

    /// The TIFF compression tag value, nil for "let ImageIO decide".
    public var tag: Int? {
        switch self {
        case .default: nil
        case .none: 1
        case .ccitt3: 3
        case .ccitt4: 4
        case .lzw: 5
        case .rle: 32773
        case .zip: 8
        }
    }
}

public struct EncoderSettings: Codable, Equatable, Sendable {
    public var fallback: FallbackEncoder = .png
    /// 1…100.
    public var jpegQuality = 90
    /// 1…100.
    public var heicQuality = 85
    public var pngInterlace: PNGInterlace = .default
    public var tiffCompression: TIFFCompression = .default

    public init() {}
}

/// How a batch is resized and saved.
public struct ResizeOptions: Codable, Equatable, Sendable {
    /// Never enlarge (ignored for percentages, as in PowerToys).
    public var shrinkOnly = false
    /// Overwrite the originals instead of writing copies next to them.
    public var replaceOriginals = false
    /// Swap the box's width and height to match each picture's orientation.
    public var ignoreOrientation = true
    /// Drop metadata that doesn't affect rendering (EXIF, GPS, IPTC, XMP…). Color profiles are kept.
    public var removeMetadata = false
    /// Give each resized file the original's modification date.
    public var keepDateModified = false
    /// `%1` original name, `%2` size name, `%3`/`%4` selected width/height, `%5`/`%6` actual width/height.
    /// A `/` makes subfolders: `%2/%1`.
    public var fileNameFormat = "%1 (%2)"
    public var encoder = EncoderSettings()
    /// Write copies here instead of next to the originals.
    public var destination: URL?

    public init() {}
}
