import CoreGraphics
import Foundation
import Vision

/// On-device text recognition for "Copy Text".
enum TextReader {
    /// The text in an image, top to bottom, one recognized line per line.
    static func text(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { obs -> (CGRect, String)? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                return (obs.boundingBox, text)
            }
            return order(lines).joined(separator: "\n")
        }.value
    }

    /// Lines in reading order: top to bottom (Vision's boxes are bottom-left based), then left to right.
    static func order(_ lines: [(CGRect, String)]) -> [String] {
        lines.sorted { a, b in
            if abs(a.0.midY - b.0.midY) > min(a.0.height, b.0.height) / 2 { return a.0.midY > b.0.midY }
            return a.0.minX < b.0.minX
        }
        .map(\.1)
    }
}
