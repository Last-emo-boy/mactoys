import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MacToysCore
import UniformTypeIdentifiers

/// Names saved captures from a template with date tokens (`$YYYY-$MM-$DD at $hh.$mm.$ss`).
enum FileNamer {
    static let defaultTemplate = "Screenshot $YYYY-$MM-$DD at $hh.$mm.$ss"

    /// The file name (with extension) for `date`, unique in the folder according to `exists`.
    static func name(template: String, date: Date, format: ImageFormat, calendar: Calendar = .current,
                     locale: Locale = .current, exists: (String) -> Bool = { _ in false }) -> String {
        let base = baseName(template: template, date: date, calendar: calendar, locale: locale)
        var candidate = "\(base).\(format.fileExtension)"
        var n = 2
        while exists(candidate) && n < 10_000 {
            candidate = "\(base) \(n).\(format.fileExtension)"
            n += 1
        }
        return candidate
    }

    /// The expanded template without extension, made safe for a file name.
    static func baseName(template: String, date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let expanded = DateTokens.expand(template, date: date, calendar: calendar, locale: locale)
        return sanitized(expanded)
    }

    /// Replaces characters Finder can't show in names, trims, and never returns an empty or hidden name.
    static func sanitized(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        s = String(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 200 { s = String(s.prefix(200)) }
        return s.isEmpty ? "Screenshot" : s
    }
}

/// Encodes images for files and the pasteboard.
enum ImageEncoder {
    enum EncodeError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let type): "Couldn't encode the image as \(type)"
            }
        }
    }

    /// PNG, JPEG or HEIC data. Lossy formats get transparent areas flattened onto white.
    static func data(_ image: CGImage, format: ImageFormat, quality: Double, scale: CGFloat = 2) throws -> Data {
        let source = format.isLossy && hasAlpha(image) ? (flattened(image) ?? image) : image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
            throw EncodeError.failed(format.title)
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.1), 1) }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EncodeError.failed(format.title) }
        return data as Data
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func flattened(_ image: CGImage, onto color: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(color)
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    /// Writes the image into `folder` with a templated name; returns the file.
    static func save(_ image: CGImage, to folder: URL, settings s: ScreenshotSettings, scale: CGFloat, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNamer.name(template: s.fileNameTemplate, date: date, format: s.format) { candidate in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
        let url = folder.appendingPathComponent(name)
        try data(image, format: s.format, quality: s.jpegQuality, scale: scale).write(to: url, options: .atomic)
        return url
    }
}

/// Puts captures on the pasteboard and in temporary files for dragging.
enum CaptureTransfer {
    /// PNG and TIFF, so image editors, chat apps and documents all accept it.
    static func copy(_ image: CGImage, scale: CGFloat) {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: CGFloat(image.width) / max(scale, 1), height: CGFloat(image.height) / max(scale, 1))
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// A file in MacToys' temporary folder (for drag and drop and sharing), named like a saved capture.
    static func temporaryFile(_ image: CGImage, settings s: ScreenshotSettings, scale: CGFloat, date: Date) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacToys Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = FileNamer.name(template: s.fileNameTemplate, date: date, format: s.format)
        let url = folder.appendingPathComponent(name)
        try ImageEncoder.data(image, format: s.format, quality: s.jpegQuality, scale: scale).write(to: url, options: .atomic)
        return url
    }

    /// Loads an image file for annotating or pinning; `scale` from its DPI (144 → 2×).
    static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = max(1, min(3, (dpi / 72).rounded()))
        return (image, CGFloat(scale))
    }

    /// The shutter sound macOS plays for screenshots.
    static func playShutter() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Grab"))?.play()
    }
}
