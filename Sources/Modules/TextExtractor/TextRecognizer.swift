import CoreGraphics
import Foundation
import Vision

/// On-device OCR through Vision (`VNRecognizeTextRequest`, accurate level).
enum TextRecognizer {
    struct Options: Sendable {
        /// A Vision language code (`"en-US"`, `"zh-Hans"`), or nil to detect automatically.
        var language: String?
        var languageCorrection = true
        /// Also measure each word (for picking a word and splitting table cells).
        var words = false
    }

    /// Recognized lines with boxes in the image's pixel space (top-left origin).
    static func recognize(_ image: CGImage, options: Options) throws -> [TextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.languageCorrection
        if let language = options.language {
            request.recognitionLanguages = [language]
            request.automaticallyDetectsLanguage = false
        } else {
            request.automaticallyDetectsLanguage = true
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation -> TextBox? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            var words: [TextBox.Word] = []
            if options.words {
                text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
                    guard let word, let box = try? candidate.boundingBox(for: range) else { return }
                    words.append(TextBox.Word(word, pixelRect(box.boundingBox, in: size)))
                }
            }
            return TextBox(text, pixelRect(observation.boundingBox, in: size), words: words)
        }
    }

    /// Vision's normalized bottom-left rect → pixels, top-left origin.
    static func pixelRect(_ r: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private static var automatic: String {
        String(localized: "Automatic", comment: "Recognition language: detect it automatically")
    }

    /// Languages Vision can read at the accurate level, as (code, display name in the UI language).
    static let languages: [(code: String, name: String)] = {
        let codes = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        return codes.map { code in
            (code, Locale.current.localizedString(forIdentifier: code) ?? code)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func name(for code: String?) -> String {
        guard let code else { return automatic }
        return languages.first { $0.code == code }?.name ?? Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Short label for the overlay, e.g. "English" for en-US.
    static func shortName(for code: String?) -> String {
        guard let code else { return automatic }
        let lang = Locale(identifier: code).language
        if code.hasPrefix("zh") || code.hasPrefix("yue") { return name(for: code) }
        return lang.languageCode.flatMap { Locale.current.localizedString(forLanguageCode: $0.identifier) } ?? name(for: code)
    }
}
