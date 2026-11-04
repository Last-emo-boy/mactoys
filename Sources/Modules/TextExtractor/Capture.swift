import Foundation
import MacToysCore
import NaturalLanguage
import Observation

/// One finished capture: what was copied and where it came from. Kept in the recent list.
struct Capture: Identifiable, Codable, Equatable, Sendable {
    enum Source: Codable, Equatable, Sendable {
        case screen
        /// A file's name (images and PDFs, from Finder, a drop or a URL).
        case file(String)
        case clipboard
    }

    var id = UUID()
    var date = Date()
    /// The recognized text, laid out in `mode`.
    var text: String
    var mode: TextExtractorSettings.Mode
    var source: Source
    /// BCP 47 code of the text's dominant language, when it could be told.
    var language: String?
    var barcodes: [Barcode] = []
    /// The codes' payloads were copied rather than the text (a QR code with a caption, a ticket).
    var barcodeFirst = false

    /// What copying the codes gives, one per line.
    var barcodeText: String { barcodes.map(\.copyText).joined(separator: "\n") }

    /// What was copied.
    var copiedText: String { barcodeFirst ? barcodeText : text }

    /// Whether the codes win over the text: they do unless the text is more than a short caption.
    static func prefersBarcodes(text: String, barcodes: [Barcode]) -> Bool {
        guard !barcodes.isEmpty else { return false }
        let lines = text.split(whereSeparator: \.isNewline).count
        return lines <= 2 && text.count <= 60
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && barcodes.isEmpty }

    var lineCount: Int { text.split(whereSeparator: \.isNewline).count }
}

/// The dominant language of a text, for the card label, read aloud and translation.
enum LanguageDetector {
    /// A BCP 47 code (`en`, `zh-Hans`), or nil for text too short or too mixed to tell.
    static func dominant(_ text: String) -> String? {
        let sample = String(text.prefix(2000))
        guard sample.contains(where: \.isLetter) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              language != .undetermined, confidence > 0.4 else { return nil }
        return language.rawValue
    }

    /// "English", "Chinese, Simplified" in the UI language.
    static func name(_ code: String?) -> String? {
        guard let code else { return nil }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Recent captures: in memory while MacToys runs, optionally saved between launches.
@MainActor
@Observable
final class CaptureHistory {
    private(set) var items: [Capture] = []
    @ObservationIgnored var limit = 20
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var persists = false
    @ObservationIgnored private let log = Log.for("textextractor")

    /// `file` nil keeps everything in memory (previews, tests).
    init(file: URL?) {
        self.file = file
    }

    /// Turns saving on or off; turning it off deletes the saved list, turning it on loads it.
    func setPersistence(_ on: Bool) {
        guard on != persists else { return }
        persists = on
        guard let file else { return }
        if on {
            guard let data = try? Data(contentsOf: file) else { save(); return }
            do {
                let saved = try JSONDecoder().decode([Capture].self, from: data)
                let known = Set(items.map(\.id))
                items = (items + saved.filter { !known.contains($0.id) }).sorted { $0.date > $1.date }
                trim()
            } catch {
                log.error("Could not read recent captures: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func add(_ capture: Capture) {
        items.removeAll { $0.id == capture.id || ($0.text == capture.text && $0.barcodes == capture.barcodes) }
        items.insert(capture, at: 0)
        trim()
        save()
    }

    /// Replaces a capture after it was laid out again (joined lines) — same id, same place.
    func update(_ capture: Capture) {
        guard let i = items.firstIndex(where: { $0.id == capture.id }) else { return }
        items[i] = capture
        save()
    }

    func remove(_ id: Capture.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func trim() {
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    private func save() {
        guard persists, let file else { return }
        do {
            try JSONEncoder().encode(items).write(to: file, options: .atomic)
        } catch {
            log.error("Could not save recent captures: \(error.localizedDescription, privacy: .public)")
        }
    }
}
