import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MacToysCore
import UniformTypeIdentifiers

/// Turns a captured still into the photo the mirror showed and writes it to disk.
enum MirrorPhoto {
    /// "Mirror Photo 2026-11-04 21.43.07.jpg" style name (locale-independent timestamp), made
    /// unique in `folder` with " 2", " 3"… when needed.
    static func fileURL(in folder: URL, date: Date, timeZone: TimeZone = .current,
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = String(localized: "Mirror Photo \(f.string(from: date))",
                          comment: "File name of a photo taken in Camera Mirror; the placeholder is a date and time like 2026-11-04 21.43.07")
        var url = folder.appendingPathComponent(base).appendingPathExtension("jpg")
        var n = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("jpg")
            n += 1
        }
        return url
    }

    /// Crops `image` to what a view of `viewSize` showed with `framing`, and flips it when `mirrored`.
    static func render(_ image: CGImage, framing: MirrorFraming, viewSize: CGSize, mirrored: Bool) -> CGImage? {
        let pixels = CGSize(width: image.width, height: image.height)
        let crop = framing.cropRect(pixels: pixels, view: viewSize)
        guard let cropped = image.cropping(to: crop) else { return nil }
        guard mirrored else { return cropped }
        guard let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cropped }
        ctx.translateBy(x: CGFloat(cropped.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return ctx.makeImage() ?? cropped
    }

    /// Writes a JPEG; throws a localized error.
    static func write(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// The camera shutter, or a short system sound when that file is missing.
    @MainActor
    static func playShutter() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Shutter.aif"
        let sound = NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop")
        sound?.volume = 0.6
        sound?.play()
    }
}
