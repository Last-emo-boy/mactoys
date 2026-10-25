import AppKit
import ImageIO
import MacToysCore
import UniformTypeIdentifiers
import Vision

/// Every Advanced Paste transform, without UI: the window, the direct shortcuts, URL
/// commands and the `mactoys` CLI all go through `apply(_:to:)`.
///
///     let out = try await AdvancedPasteTransforms.apply(.markdown, to: .init(html: "<b>Hi</b>"))
public enum AdvancedPasteTransforms {
    public enum Action: Hashable, Sendable {
        case plainText, markdown, json
        case txtFile, htmlFile, pngFile
        case imageToText
        case transcodeMP3, transcodeM4A, transcodeMP4
        /// Free-form instructions run through an AI provider.
        case ai(prompt: String, provider: AIProvider)

        /// The local actions, in window order.
        public static let builtIns: [Action] = [.plainText, .markdown, .json, .txtFile, .htmlFile, .pngFile, .imageToText,
                                                .transcodeMP3, .transcodeM4A, .transcodeMP4]

        /// Stable name used in settings, URLs (`?as=`) and the CLI (`--action`).
        public var name: String {
            switch self {
            case .plainText: "plain-text"
            case .markdown: "markdown"
            case .json: "json"
            case .txtFile: "paste-as-txt-file"
            case .htmlFile: "paste-as-html-file"
            case .pngFile: "paste-as-png-file"
            case .imageToText: "image-to-text"
            case .transcodeMP3: "transcode-to-mp3"
            case .transcodeM4A: "transcode-to-m4a"
            case .transcodeMP4: "transcode-to-mp4"
            case .ai: "paste-with-ai"
            }
        }

        /// Display name (localized; Markdown and JSON are format names).
        public var title: String {
            switch self {
            case .plainText: String(localized: "Plain text", comment: "Advanced Paste action: paste without formatting")
            case .markdown: "Markdown"
            case .json: "JSON"
            case .txtFile: String(localized: ".txt file", comment: "Advanced Paste action: paste the text as a .txt file")
            case .htmlFile: String(localized: ".html file", comment: "Advanced Paste action: paste rich text as an .html file")
            case .pngFile: String(localized: ".png file", comment: "Advanced Paste action: paste the image as a .png file")
            case .imageToText: String(localized: "Text from image (OCR)")
            case .transcodeMP3: String(localized: "Transcode to .mp3")
            case .transcodeM4A: String(localized: "Transcode to .m4a (AAC)")
            case .transcodeMP4: String(localized: "Transcode to .mp4 (H.264/AAC)")
            case .ai: String(localized: "Paste with AI")
            }
        }

        public var symbol: String {
            switch self {
            case .plainText: "text.alignleft"
            case .markdown: "number"
            case .json: "curlybraces"
            case .txtFile: "doc.text"
            case .htmlFile: "chevron.left.forwardslash.chevron.right"
            case .pngFile: "photo"
            case .imageToText: "text.viewfinder"
            case .transcodeMP3, .transcodeM4A: "waveform"
            case .transcodeMP4: "film"
            case .ai: "sparkles"
            }
        }

        public var isAI: Bool { if case .ai = self { true } else { false } }

        /// Long-running actions show progress and can be cancelled.
        public var isLongRunning: Bool {
            switch self {
            case .transcodeMP3, .transcodeM4A, .transcodeMP4, .ai, .imageToText: true
            default: false
            }
        }

        /// Parses a name (`"json"`, `"paste-as-txt-file"`) or a short alias (`"md"`, `"txt"`, `"ocr"`,
        /// `"mp3"`), ignoring case, spaces and underscores. AI actions need a provider and aren't parsed.
        public init?(name raw: String) {
            let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
            let aliases: [String: Action] = [
                "plain": .plainText, "plaintext": .plainText, "text": .plainText, "plain-text": .plainText,
                "md": .markdown, "markdown": .markdown,
                "json": .json,
                "txt": .txtFile, "txt-file": .txtFile, "paste-as-txt": .txtFile, "paste-as-txt-file": .txtFile,
                "html": .htmlFile, "html-file": .htmlFile, "paste-as-html": .htmlFile, "paste-as-html-file": .htmlFile,
                "png": .pngFile, "png-file": .pngFile, "paste-as-png": .pngFile, "paste-as-png-file": .pngFile,
                "ocr": .imageToText, "image-to-text": .imageToText, "text-from-image": .imageToText,
                "mp3": .transcodeMP3, "transcode-to-mp3": .transcodeMP3,
                "m4a": .transcodeM4A, "aac": .transcodeM4A, "transcode-to-m4a": .transcodeM4A,
                "mp4": .transcodeMP4, "transcode-to-mp4": .transcodeMP4,
            ]
            guard let action = aliases[key] else { return nil }
            self = action
        }

        /// Whether this action can run on `input`.
        public func accepts(_ input: Input) -> Bool {
            switch self {
            case .plainText, .markdown, .json, .txtFile: input.hasText
            case .htmlFile: input.html != nil || input.rtf != nil
            case .pngFile, .imageToText: input.image != nil || input.imageFile != nil
            case .transcodeMP3, .transcodeM4A: input.mediaFile != nil
            case .transcodeMP4: input.mediaFile.map(MediaTranscoder.isVideo) ?? false
            case .ai: input.hasText || input.image != nil || input.imageFile != nil
            }
        }

        /// What the action needs, for error messages.
        var requirement: String {
            switch self {
            case .plainText, .markdown, .json, .txtFile:
                String(localized: "\(title) needs text on the clipboard.", comment: "%@ is an Advanced Paste action, e.g. Markdown")
            case .htmlFile: String(localized: ".html file needs rich text or HTML on the clipboard.")
            case .pngFile, .imageToText:
                String(localized: "\(title) needs an image on the clipboard.", comment: "%@ is an Advanced Paste action, e.g. .png file")
            case .transcodeMP3, .transcodeM4A:
                String(localized: "\(title) needs one audio or video file on the clipboard.",
                       comment: "%@ is an Advanced Paste action, e.g. Transcode to .mp3")
            case .transcodeMP4:
                String(localized: "\(title) needs one video file on the clipboard.",
                       comment: "%@ is an Advanced Paste action, e.g. Transcode to .mp4")
            case .ai: String(localized: "Paste with AI needs text or an image on the clipboard.")
            }
        }
    }

    /// Clipboard content (or a file's) handed to a transform.
    public struct Input: Sendable, Equatable {
        public var text: String?
        public var html: String?
        public var rtf: Data?
        /// Image data in any ImageIO format (the clipboard gives PNG).
        public var image: Data?
        public var files: [URL]

        public init(text: String? = nil, html: String? = nil, rtf: Data? = nil, image: Data? = nil, files: [URL] = []) {
            self.text = text
            self.html = html
            self.rtf = rtf
            self.image = image
            self.files = files
        }

        public init(_ item: ClipItem) {
            switch item.kind {
            case .files: self.init(files: item.files)
            case .image: self.init(text: item.text, image: item.image)
            default: self.init(text: item.text, html: item.html, rtf: item.rtf)
            }
        }

        /// Everything a pasteboard offers at once, so a spreadsheet copy (HTML, RTF, text and an
        /// image) can become Markdown, JSON or a .png alike. Copied files are taken on their own.
        public init(pasteboard pb: NSPasteboard) {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                self.init(files: urls)
                return
            }
            self.init(text: pb.string(forType: .string), html: pb.string(forType: .html), rtf: pb.data(forType: .rtf),
                      image: pb.data(forType: .png) ?? pb.data(forType: .tiff))
        }

        public var isEmpty: Bool { !hasText && image == nil && files.isEmpty }

        /// Reads a file: text formats become text, HTML becomes html, images become image data,
        /// audio and video stay files (for transcoding).
        public init(contentsOf url: URL) throws {
            let type = UTType(filenameExtension: url.pathExtension)
            if let type, type.conforms(to: .audiovisualContent) {
                self.init(files: [url])
            } else if let type, type.conforms(to: .image) {
                self.init(image: try Data(contentsOf: url))
            } else if let type, type.conforms(to: .html) {
                let html = try String(contentsOf: url, encoding: .utf8)
                self.init(html: html)
            } else if let type, type.conforms(to: .rtf) {
                self.init(rtf: try Data(contentsOf: url))
            } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                self.init(text: text)
            } else {
                self.init(files: [url])
            }
        }

        public var hasText: Bool { !(text ?? "").isEmpty || html != nil || rtf != nil }

        /// The one audio/video file on the clipboard.
        var mediaFile: URL? { files.count == 1 && MediaTranscoder.isMedia(files[0]) ? files[0] : nil }

        /// The one image file on the clipboard.
        var imageFile: URL? {
            guard files.count == 1, let type = UTType(filenameExtension: files[0].pathExtension), type.conforms(to: .image) else { return nil }
            return files[0]
        }
    }

    public enum Output: Sendable, Equatable {
        case text(String)
        /// A generated file; pasting puts its URL on the pasteboard so Finder and file fields accept it.
        case file(URL)

        /// What to write to the pasteboard.
        public var clipItem: ClipItem {
            switch self {
            case .text(let s): ClipItem(kind: .text, text: s)
            case .file(let url): ClipItem(kind: .files, text: url.path, files: [url])
            }
        }
    }

    public enum TransformError: LocalizedError, Equatable {
        case unsupportedInput(String)
        case noTextFound
        case encoderMissing(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedInput(let m), .encoderMissing(let m), .failed(let m): m
            case .noTextFound: String(localized: "No text was found in the image.")
            }
        }
    }

    /// Runs `action` on `input`. Long actions report 0…1 through `progress` and stop when the task is cancelled.
    public static func apply(_ action: Action, to input: Input,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> Output {
        guard action.accepts(input) else { throw TransformError.unsupportedInput(action.requirement) }
        switch action {
        case .plainText:
            return .text(plainText(input))
        case .markdown:
            return .text(markdown(input))
        case .json:
            return .text(JSONConverter.convert(plainText(input)))
        case .txtFile:
            return .file(try write(Data(plainText(input).utf8), extension: "txt"))
        case .htmlFile:
            return .file(try write(Data(htmlDocument(input).utf8), extension: "html"))
        case .pngFile:
            return .file(try write(try png(from: imageData(input)), extension: "png"))
        case .imageToText:
            return .text(try recognizeText(in: imageData(input)))
        case .transcodeMP3, .transcodeM4A, .transcodeMP4:
            guard let file = input.mediaFile else { throw TransformError.unsupportedInput(action.requirement) }
            let format: MediaTranscoder.Format = action == .transcodeMP3 ? .mp3 : action == .transcodeM4A ? .m4a : .mp4
            return .file(try await MediaTranscoder.transcode(file, to: format, into: try newOutputFolder(), progress: progress))
        case .ai(let prompt, let provider):
            let content: String
            if input.hasText {
                content = input.html != nil || input.rtf != nil ? markdown(input) : plainText(input)
            } else {
                content = try recognizeText(in: imageData(input))
            }
            let key = Keychain.get(provider.keychainAccount)
            return .text(try await AIClient.complete(provider: provider, apiKey: key, instructions: prompt, content: content))
        }
    }

    // MARK: Text

    static func plainText(_ input: Input) -> String {
        if let text = input.text, !text.isEmpty { return text }
        if let html = input.html { return HTMLToMarkdown.plainText(html) }
        if let rtf = input.rtf, let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil) { return attributed.string }
        return ""
    }

    static func markdown(_ input: Input) -> String {
        if let html = input.html { return HTMLToMarkdown.convert(html) }
        if let rtf = input.rtf, let html = html(fromRTF: rtf) { return HTMLToMarkdown.convert(html) }
        return input.text ?? ""
    }

    static func htmlDocument(_ input: Input) -> String {
        let html = input.html ?? input.rtf.flatMap(html(fromRTF:)) ?? ""
        if html.range(of: "<html", options: .caseInsensitive) != nil { return html }
        return "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n</head>\n<body>\n\(html)\n</body>\n</html>\n"
    }

    static func html(fromRTF rtf: Data) -> String? {
        guard let attributed = NSAttributedString(rtf: rtf, documentAttributes: nil),
              let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                                   .characterEncoding: String.Encoding.utf8.rawValue])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Images

    private static func imageData(_ input: Input) throws -> Data {
        if let image = input.image { return image }
        if let file = input.imageFile { return try Data(contentsOf: file) }
        throw TransformError.unsupportedInput(String(localized: "An image is needed."))
    }

    private static func cgImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TransformError.failed(String(localized: "The image could not be read."))
        }
        return image
    }

    static func png(from data: Data) throws -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        let image = try cgImage(data)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            throw TransformError.failed(String(localized: "PNG encoding is unavailable."))
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw TransformError.failed(String(localized: "The image could not be converted to PNG."))
        }
        return out as Data
    }

    /// On-device OCR (Vision, accurate, language correction, automatic language).
    static func recognizeText(in data: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: try cgImage(data)).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TransformError.noTextFound }
        return text
    }

    // MARK: Files

    /// Generated files live here (one folder per paste) and are removed after a day.
    public static var outputRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacToys Advanced Paste", isDirectory: true)
    }

    static func newOutputFolder() throws -> URL {
        let folder = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(_ data: Data, extension ext: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = try newOutputFolder().appendingPathComponent("Clipboard \(formatter.string(from: Date())).\(ext)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes generated files older than `age` seconds.
    public static func removeOldFiles(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders {
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if Date().timeIntervalSince(created) > age { try? fm.removeItem(at: folder) }
        }
    }
}
