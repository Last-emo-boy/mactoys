import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The three kinds of files the Optimizer handles.
public enum MediaKind: String, Codable, CaseIterable, Sendable, Comparable {
    case image, video, pdf

    public static func < (a: MediaKind, b: MediaKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// The kind of a file, or nil when the Optimizer can't handle it. Animated GIFs count as video
    /// (they are turned into MP4) when `gifAsVideo` is set.
    static func of(_ url: URL, gifAsVideo: Bool = true) -> MediaKind? {
        guard let type = contentType(of: url) else { return nil }
        return of(type: type, gifAsVideo: gifAsVideo)
    }

    static func of(type: UTType, gifAsVideo: Bool = true) -> MediaKind? {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .gif) { return gifAsVideo ? .video : .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image), isReadableImage(type) { return .image }
        return nil
    }

    static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    private static func isReadableImage(_ type: UTType) -> Bool {
        let readable = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return readable.contains { UTType($0).map { type.conforms(to: $0) } ?? false }
    }

    var title: String {
        switch self {
        case .image: String(localized: "Images", comment: "Optimizer: kind of files")
        case .video: String(localized: "Videos", comment: "Optimizer: kind of files")
        case .pdf: String(localized: "PDFs", comment: "Optimizer: kind of files")
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .pdf: "doc.richtext"
        }
    }
}

/// Image formats the Optimizer writes. Names are not translated.
public enum ImageFormat: String, Codable, CaseIterable, Sendable, Hashable {
    case jpeg, png, heic, avif, webp

    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .heic
        case .webp: .webP
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .avif: "avif"
        case .webp: "webp"
        }
    }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .webp: "WebP"
        }
    }

    var isLossy: Bool { self != .png }
    var supportsAlpha: Bool { self != .jpeg }

    /// Whether ImageIO on this Mac can encode the format (WebP, for one, is read-only on macOS 26).
    var isWritable: Bool { Self.writableIdentifiers.contains(type.identifier) }

    /// Writable formats in menu order.
    static var writable: [ImageFormat] { allCases.filter(\.isWritable) }

    static func of(type: UTType) -> ImageFormat? {
        // AVIF before HEIC: both are HEIF containers.
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: ImageFormat.avif.type) { return .avif }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .webP) { return .webp }
        return nil
    }

    private static let writableIdentifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
}
