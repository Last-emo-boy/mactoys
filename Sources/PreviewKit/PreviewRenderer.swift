import CoreGraphics
import Foundation

/// Everything a renderer may need to know, derived from the Finder Add-ons (or Peek) settings.
public struct PreviewOptions: Sendable, Equatable {
    public var code: CodeOptions
    public var markdownTheme: PreviewTheme
    public var markdownFontSize: Double
    public var markdown: MarkdownOptions
    public var showLocalImages: Bool
    public var allowRemoteImages: Bool
    public var formatJSONXML: Bool
    public var maxTextBytes: Int
    public var svgBackground: ImageBackground
    public var stlColor: String
    /// nil renders STL on a transparent background.
    public var stlBackground: String?
    public var toolpath: ToolpathStyle
    /// G-code points kept for drawing (lower in memory-limited extensions).
    public var gcodePointLimit = GCodeParser.defaultPointLimit

    public init(settings s: FinderAddonsSettings = FinderAddonsSettings()) {
        code = s.codeOptions
        markdownTheme = s.markdownTheme
        markdownFontSize = max(11, s.codeFontSize + 2)
        markdown = MarkdownOptions(allowHTML: s.markdownAllowHTML, highlightCode: true)
        showLocalImages = s.markdownShowLocalImages
        allowRemoteImages = s.markdownAllowRemoteImages
        formatJSONXML = s.codeFormat
        maxTextBytes = max(1, s.codeMaxFileSizeKB) * 1024
        svgBackground = s.svgBackground
        stlColor = s.stlColor
        stlBackground = s.stlBackground
        toolpath = ToolpathStyle(view: s.gcodeView, showTravel: s.gcodeShowTravel, darkBackground: true)
    }
}

public enum PreviewError: Error, LocalizedError, Equatable {
    case tooLarge(Int64)
    case binary
    case unreadable(String)
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            "The file is too large to preview (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))."
        case .binary: "The file doesn't contain text."
        case .unreadable(let why): "The file couldn't be read: \(why)"
        case .unsupported: "There is no preview for this kind of file."
        }
    }
}

/// One entry point per output: HTML pages for text formats, bitmaps for graphics, Finder thumbnails.
public enum PreviewRenderer {
    public static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw PreviewError.unreadable(error.localizedDescription) }
    }

    /// Reads and decodes a text file within the size limit.
    public static func readText(_ url: URL, maxBytes: Int) throws -> String {
        let size = fileSize(url)
        guard size <= Int64(maxBytes) else { throw PreviewError.tooLarge(size) }
        guard let text = TextDecoding.decode(try read(url)) else { throw PreviewError.binary }
        return text
    }

    // MARK: HTML

    /// HTML page for Markdown, JSON, XML, CSV/TSV, source code and SQLite.
    /// `prefetchedImages` maps remote image URLs to `data:` URIs (Quick Look fetches them itself).
    public static func html(for url: URL, kind: PreviewKind, options: PreviewOptions,
                            prefetchedImages: [String: String] = [:]) throws -> String {
        let title = url.lastPathComponent
        switch kind {
        case .sqlite:
            do { return SQLitePreview.page(try SQLitePreview.read(url), title: title, theme: options.code.theme) }
            catch { throw PreviewError.unreadable(String(describing: error)) }
        case .markdown:
            let text = try readText(url, maxBytes: options.maxTextBytes)
            let policy = MarkdownImagePolicy(documentURL: url, showLocalImages: options.showLocalImages,
                                             allowRemoteImages: options.allowRemoteImages, prefetched: prefetchedImages)
            return MarkdownRenderer.page(text, title: title, theme: options.markdownTheme, fontSize: options.markdownFontSize,
                                         options: options.markdown, allowRemoteImages: options.allowRemoteImages,
                                         image: { policy.resolve($0) })
        case .delimited:
            let text = try readText(url, maxBytes: options.maxTextBytes)
            let ext = url.pathExtension.lowercased()
            let delimiter: Character? = ext == "tsv" || ext == "tab" ? "\t" : (ext == "psv" ? "|" : nil)
            return DelimitedText.page(text, title: title, theme: options.code.theme, delimiter: delimiter)
        case .json, .xml, .code:
            let text = try readText(url, maxBytes: options.maxTextBytes)
            return codePage(text, fileName: title, kind: kind, options: options)
        default:
            throw PreviewError.unsupported
        }
    }

    /// A source listing; JSON and XML are reformatted when `formatJSONXML` is on.
    public static func codePage(_ text: String, fileName: String, kind: PreviewKind, options: PreviewOptions) -> String {
        var shown = text
        var notice: String?
        var language: Language?
        switch kind {
        case .json:
            language = .json
            if options.formatJSONXML, !fileName.lowercased().hasSuffix(".jsonl"), let pretty = SourceFormatter.prettyJSON(text),
               pretty.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                shown = pretty
                notice = "Formatted for reading — the file itself is unchanged."
            }
        case .xml:
            language = .xml
            if options.formatJSONXML, let pretty = SourceFormatter.prettyXML(text),
               pretty.trimmingCharacters(in: .whitespacesAndNewlines) != text.trimmingCharacters(in: .whitespacesAndNewlines) {
                shown = pretty
                notice = "Formatted for reading — the file itself is unchanged."
            }
        case .code(let id):
            language = Language.all.first { $0.id == id }
            if id == "text" { language = Language.forShebang(text.prefix { $0 != "\n" }) ?? language }
        default:
            language = Language.detect(fileName: fileName, text: text)
        }
        if text.utf8.count > CodeRenderer.highlightLimit {
            notice = (notice.map { $0 + " " } ?? "") + "Large file: shown without colors."
        }
        return CodeRenderer.page(text: shown, language: language, title: fileName, options: options.code, notice: notice)
    }

    // MARK: Images

    /// A bitmap preview of SVG, G-code, binary G-code, STL, QOI or PDF, at most `maxSize` pixels.
    public static func image(for url: URL, kind: PreviewKind, maxSize: CGSize, options: PreviewOptions) async throws -> CGImage {
        let result: CGImage?
        switch kind {
        case .svg:
            result = await SVGRenderer.render(try read(url), maxSize: maxSize, background: options.svgBackground)
        case .gcode:
            result = ToolpathRenderer.render(GCodeParser.parse(try read(url), pointLimit: options.gcodePointLimit),
                                             size: maxSize, style: options.toolpath)
        case .bgcode:
            let data = try read(url)
            if let path = try? BGCode.toolpath(data, pointLimit: options.gcodePointLimit), path.moveCount > 0 {
                result = ToolpathRenderer.render(path, size: maxSize, style: options.toolpath)
            } else {
                result = (try? BGCode.parse(data, decodeGCode: false))?.thumbnails
                    .max { $0.width * $0.height < $1.width * $1.height }?.image()
            }
        case .stl:
            let mesh: STLMesh
            do { mesh = try STLParser.parse(try read(url)) } catch let e as PreviewError { throw e } catch { throw PreviewError.unreadable("not a valid STL file") }
            result = STLRenderer.render(mesh, size: maxSize, color: HexColor.cgColor(options.stlColor),
                                        background: options.stlBackground.map { HexColor.cgColor($0) })
        case .qoi:
            do { result = ImageUtil.scaled(try QOI.image(try read(url)), toFit: maxSize) }
            catch let e as PreviewError { throw e } catch { throw PreviewError.unreadable("not a valid QOI image") }
        case .pdf:
            result = PDFThumbnail.firstPage(of: url, maxSize: maxSize)
        default:
            throw PreviewError.unsupported
        }
        guard let result else { throw PreviewError.unreadable("the renderer produced no image") }
        return result
    }

    // MARK: Thumbnails

    /// A Finder icon image, at most `maxSize` pixels.
    public static func thumbnail(for url: URL, kind: PreviewKind, maxSize: CGSize, settings: FinderAddonsSettings) async throws -> CGImage {
        switch kind {
        case .svg:
            guard let image = await SVGRenderer.render(try read(url), maxSize: maxSize, background: .transparent) else {
                throw PreviewError.unreadable("SVG")
            }
            return image
        case .gcode, .bgcode:
            let data = try read(url)
            var embedded: [GCodeThumbnail] = []
            if settings.gcodeThumbnailUsesEmbedded {
                if kind == .bgcode {
                    embedded = (try? BGCode.parse(data, decodeGCode: false))?.thumbnails ?? []
                } else {
                    // Slicers write thumbnails near the top: look there before parsing everything.
                    embedded = GCodeParser.parse(data.prefix(4 * 1024 * 1024)).thumbnails
                }
            }
            if let best = embedded.max(by: { $0.width * $0.height < $1.width * $1.height }), let image = best.image() {
                return ImageUtil.scaled(image, toFit: maxSize)
            }
            // Thumbnails are small: a coarser toolpath is enough and keeps the extension's memory low.
            let limit = 1_500_000
            let path = kind == .bgcode ? try BGCode.toolpath(data, pointLimit: limit) : GCodeParser.parse(data, pointLimit: limit)
            let style = ToolpathStyle(view: settings.gcodeView, showTravel: false, darkBackground: true)
            guard let image = ToolpathRenderer.render(path, size: maxSize, style: style) else { throw PreviewError.unreadable("G-code") }
            return image
        case .stl:
            var options = PreviewOptions(settings: settings)
            if settings.stlTransparentThumbnails { options.stlBackground = nil }
            return try await image(for: url, kind: .stl, maxSize: maxSize, options: options)
        case .qoi:
            return try await image(for: url, kind: .qoi, maxSize: maxSize, options: PreviewOptions(settings: settings))
        case .pdf:
            guard let image = PDFThumbnail.firstPage(of: url, maxSize: maxSize) else { throw PreviewError.unreadable("PDF") }
            return image
        case .markdown:
            let text = try readText(url, maxBytes: 4 * 1024 * 1024)
            guard let image = MarkdownThumbnail.render(text, size: maxSize) else { throw PreviewError.unreadable("Markdown") }
            return image
        default:
            throw PreviewError.unsupported
        }
    }
}
