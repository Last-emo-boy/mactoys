import AVFoundation
import AppKit
import PreviewKit
import UniformTypeIdentifiers

/// What the Peek window shows for one item.
enum PeekContent {
    case loading
    /// A PreviewKit page (Markdown, code, JSON/XML, CSV, SQLite) in a web view.
    case html(String)
    /// A PreviewKit bitmap (SVG, G-code, STL, QOI).
    case image(CGImage, CanvasStyle)
    /// macOS's own previewer (photos, video, audio, PDF, documents…).
    case quickLook(URL)
    case folder(URL)
    /// No preview: icon, name and a reason.
    case details(String)
    /// Everything was deleted.
    case empty

    enum CanvasStyle { case dark, checkerboard, light }
}

/// One "Label value" pair in the footer.
struct PeekField: Hashable {
    var label: String
    var value: String
}

/// Picks a renderer for a file and produces its content and extra footer fields.
enum PeekLoader {
    /// Types macOS's previewer handles better than a text listing.
    private static let quickLookTypes: [UTType] = [.image, .audiovisualContent, .pdf, .html, .rtf, .rtfd, .presentation,
                                                   .spreadsheet, .propertyList, .font, .vCard, .calendarEvent, .archive,
                                                   .usdz, .threeDContent, .webArchive, .epub]

    static func load(_ url: URL, options: PreviewOptions, imageSize: CGSize) async -> (PeekContent, [PeekField]) {
        let kind = PreviewKind.of(url)
        switch kind {
        case .folder:
            return (.folder(url), [])
        case .pdf:
            return (.quickLook(url), PDFThumbnailFields.fields(url))
        case .sqlite:
            do {
                let tables = try SQLitePreview.read(url)
                return (.html(SQLitePreview.page(tables, title: url.lastPathComponent, theme: options.code.theme)),
                        [PeekField(label: "Tables", value: "\(tables.count)")])
            } catch {
                return (.quickLook(url), [])         // not an SQLite file after all
            }
        case .markdown, .json, .xml, .delimited, .code:
            return textContent(url, kind: kind, options: options)
        case .gcode, .bgcode:
            return await Task.detached { toolpath(url, kind: kind, options: options, size: imageSize) }.value
        case .stl:
            return await Task.detached { stl(url, options: options, size: imageSize) }.value
        case .svg, .qoi:
            do {
                var o = options
                o.svgBackground = .transparent
                let image = try await PreviewRenderer.image(for: url, kind: kind, maxSize: imageSize, options: o)
                var fields: [PeekField] = []
                if kind == .qoi { fields.append(PeekField(label: "Dimensions", value: "\(image.width) × \(image.height)")) }
                if kind == .svg, let data = try? Data(contentsOf: url), let s = SVGRenderer.intrinsicSize(data) {
                    fields.append(PeekField(label: "Dimensions", value: "\(Int(s.width)) × \(Int(s.height))"))
                }
                return (.image(image, .checkerboard), fields)
            } catch {
                return (.details(error.localizedDescription), [])
            }
        case .other:
            return await other(url, options: options)
        }
    }

    private static func textContent(_ url: URL, kind: PreviewKind, options: PreviewOptions) -> (PeekContent, [PeekField]) {
        do {
            let html = try PreviewRenderer.html(for: url, kind: kind, options: options)
            var fields: [PeekField] = []
            if case .code(let id) = kind, let text = try? PreviewRenderer.readText(url, maxBytes: options.maxTextBytes) {
                let lines = text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } } - (text.hasSuffix("\n") ? 1 : 0)
                fields.append(PeekField(label: "Lines", value: NumberFormatter.localizedString(from: NSNumber(value: lines), number: .decimal)))
                if let l = Language.all.first(where: { $0.id == id }), id != "text" { fields.append(PeekField(label: "Language", value: l.name)) }
            }
            return (.html(html), fields)
        } catch PreviewError.binary {
            return (.quickLook(url), [])
        } catch {
            return (.details(error.localizedDescription), [])
        }
    }

    private static func toolpath(_ url: URL, kind: PreviewKind, options: PreviewOptions, size: CGSize) -> (PeekContent, [PeekField]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (.details("The file couldn't be read."), []) }
        let path: GCodeToolpath
        if kind == .bgcode {
            guard let p = try? BGCode.toolpath(data) else { return (.details("This binary G-code file couldn't be decoded."), []) }
            path = p
        } else {
            path = GCodeParser.parse(data)
        }
        let fields = path.summary.filter { $0.0 != "Moves" }.map { PeekField(label: $0.0, value: $0.1) }
        if path.moveCount == 0, let thumb = path.bestThumbnail?.image() {
            return (.image(thumb, .dark), fields)
        }
        guard let image = ToolpathRenderer.render(path, size: size, style: options.toolpath) else {
            return (.details("Nothing to draw in this G-code file."), fields)
        }
        return (.image(image, .dark), fields)
    }

    private static func stl(_ url: URL, options: PreviewOptions, size: CGSize) -> (PeekContent, [PeekField]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let mesh = try? STLParser.parse(data) else {
            return (.details("This isn't a valid STL file."), [])
        }
        let fields = mesh.summary.filter { $0.0 != "Name" }.map { PeekField(label: $0.0, value: $0.1) }
        guard let image = STLRenderer.render(mesh, size: size, color: HexColor.cgColor(options.stlColor),
                                             background: HexColor.cgColor(options.stlBackground ?? "#1B1D22")) else {
            return (.details("The model couldn't be rendered."), fields)
        }
        return (.image(image, .dark), fields)
    }

    /// Images, media and documents go to Quick Look; unknown files that turn out to be text get a listing.
    private static func other(_ url: URL, options: PreviewOptions) async -> (PeekContent, [PeekField]) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        var fields: [PeekField] = []
        if let type, type.conforms(to: .image), let size = ImageUtil.pixelSize(of: url) {
            fields.append(PeekField(label: "Dimensions", value: "\(Int(size.width)) × \(Int(size.height))"))
        }
        if let type, type.conforms(to: .audiovisualContent), let duration = try? await AVURLAsset(url: url).load(.duration),
           duration.isNumeric, duration.seconds > 0 {
            fields.append(PeekField(label: "Duration", value: formatDuration(duration.seconds)))
        }
        if let type, quickLookTypes.contains(where: { type.conforms(to: $0) }) { return (.quickLook(url), fields) }
        let size = PreviewRenderer.fileSize(url)
        if size <= Int64(options.maxTextBytes), let handle = try? FileHandle(forReadingFrom: url) {
            let head = (try? handle.read(upToCount: 8192)) ?? Data()
            try? handle.close()
            if TextDecoding.isText(head), let text = try? PreviewRenderer.readText(url, maxBytes: options.maxTextBytes) {
                return (.html(PreviewRenderer.codePage(text, fileName: url.lastPathComponent, kind: .code("text"), options: options)), fields)
            }
        }
        return (.quickLook(url), fields)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private enum PDFThumbnailFields {
    static func fields(_ url: URL) -> [PeekField] {
        guard let pages = PDFThumbnail.pageCount(of: url) else { return [] }
        return [PeekField(label: "Pages", value: "\(pages)")]
    }
}

/// Footer fields every item has: size, modification date, kind.
enum PeekMetadata {
    static func baseFields(_ url: URL) -> (size: PeekField?, modified: PeekField?, type: PeekField?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .isDirectoryKey])
        var size: PeekField?
        if values?.isDirectory != true, let bytes = values?.fileSize {
            size = PeekField(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        let modified = values?.contentModificationDate.map { PeekField(label: "Modified", value: relativeDate($0)) }
        let kind = PreviewKind.of(url)
        let typeName = values?.localizedTypeDescription.flatMap { $0.isEmpty ? nil : $0 } ?? kind.displayName
        return (size, modified, PeekField(label: "Type", value: typeName))
    }

    /// "Today 21:10", "Yesterday 09:12", or a short date.
    static func relativeDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
