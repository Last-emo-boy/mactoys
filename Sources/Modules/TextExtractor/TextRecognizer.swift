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
        try analyze(image, options: options, barcodes: false).boxes
    }

    /// Text and, with `barcodes`, QR codes and barcodes, in one pass over the image.
    static func analyze(_ image: CGImage, options: Options, barcodes: Bool) throws -> (boxes: [TextBox], barcodes: [Barcode]) {
        let request = textRequest(options)
        let barcodeRequest = barcodes ? VNDetectBarcodesRequest() : nil
        try VNImageRequestHandler(cgImage: image).perform([request] + (barcodeRequest.map { [$0] } ?? []))
        let size = CGSize(width: image.width, height: image.height)
        let boxes = (request.results ?? []).compactMap { observation -> TextBox? in
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
        return (boxes, barcodeResults(barcodeRequest?.results ?? []))
    }

    /// Only QR codes and barcodes (a PDF page that already has a text layer).
    static func barcodes(in image: CGImage) throws -> [Barcode] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return barcodeResults(request.results ?? [])
    }

    /// Payloads in reading order, each once.
    private static func barcodeResults(_ observations: [VNBarcodeObservation]) -> [Barcode] {
        var seen = Set<String>()
        return observations
            .sorted { ($0.boundingBox.maxY, -$0.boundingBox.minX) > ($1.boundingBox.maxY, -$1.boundingBox.minX) }
            .compactMap { o -> Barcode? in
                guard let payload = o.payloadStringValue, !payload.isEmpty, seen.insert(payload).inserted else { return nil }
                let name = o.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
                return Barcode(symbology: name, payload: payload)
            }
    }

    private static func textRequest(_ options: Options) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.languageCorrection
        if let language = options.language {
            request.recognitionLanguages = [language]
            request.automaticallyDetectsLanguage = false
        } else {
            request.automaticallyDetectsLanguage = true
        }
        return request
    }

    /// Boxes laid out the way a mode asks for.
    static func text(_ boxes: [TextBox], mode: TextExtractorSettings.Mode) -> String {
        switch mode {
        case .lines: TextLayout.lines(boxes)
        case .paragraphs: TextLayout.paragraphs(boxes)
        case .singleLine: TextLayout.singleLine(boxes)
        case .table: TextLayout.table(boxes)
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
