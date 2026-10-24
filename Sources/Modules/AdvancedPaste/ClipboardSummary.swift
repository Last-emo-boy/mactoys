import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one-line clipboard preview at the top of the window: a snippet and what it is ("CSV · 3 rows").
struct ClipboardSummary: Equatable {
    var symbol: String
    var snippet: String
    var detail: String

    init(symbol: String, snippet: String, detail: String) {
        self.symbol = symbol
        self.snippet = snippet
        self.detail = detail
    }

    init(_ input: AdvancedPasteTransforms.Input) {
        if !input.files.isEmpty {
            let files = input.files
            if files.count > 1 {
                self.init(symbol: "doc.on.doc", snippet: files.map(\.lastPathComponent).joined(separator: ", "),
                          detail: "\(files.count) files")
                return
            }
            let type = UTType(filenameExtension: files[0].pathExtension)
            let kind: (String, String) = if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                ("film", "Video file")
            } else if type?.conforms(to: .audio) == true {
                ("waveform", "Audio file")
            } else if type?.conforms(to: .image) == true {
                ("photo", "Image file")
            } else {
                ("doc", "File")
            }
            self.init(symbol: kind.0, snippet: files[0].lastPathComponent, detail: kind.1)
            return
        }
        if !input.hasText, let image = input.image {
            self.init(symbol: "photo", snippet: "Image", detail: Self.imageDetail(image))
            return
        }
        let text = AdvancedPasteTransforms.plainText(input)
        let snippet = Self.snippet(text)
        if input.html != nil || input.rtf != nil {
            let detail: String = if case .delimited(_, let rows) = JSONConverter.detect(text) {
                "Table · \(rows) row\(rows == 1 ? "" : "s")"
            } else {
                input.html != nil ? "Rich text · HTML" : "Rich text"
            }
            self.init(symbol: "doc.richtext", snippet: snippet, detail: detail)
            return
        }
        self.init(symbol: "doc.on.clipboard", snippet: snippet, detail: Self.textDetail(text))
    }

    static func snippet(_ text: String, limit: Int = 160) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ↵ ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func textDetail(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Empty" }
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed), url.scheme != nil, url.host() != nil {
            return "Link"
        }
        let format = JSONConverter.detect(trimmed)
        if case .lines = format {
            let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
            return "Text · \(words) word\(words == 1 ? "" : "s")"
        }
        return format.label
    }

    static func imageDetail(_ data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return "Image" }
        return "Image · \(w) × \(h)"
    }
}
