import Foundation

/// The renderer a file goes to.
public enum PreviewKind: Equatable, Sendable {
    case folder
    case markdown
    case json
    case xml
    case delimited
    case svg
    case gcode
    case bgcode
    case stl
    case qoi
    case pdf
    case sqlite
    /// Source code or plain text in a known language (`Language.id`).
    case code(String)
    /// Anything else: images, media, documents… (Quick Look's own previewers).
    case other

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdx", "rmd", "mdtext", "mdtxt"]
    static let jsonExtensions: Set<String> = ["json", "jsonc", "json5", "geojson", "topojson", "webmanifest", "har", "ipynb", "babelrc", "eslintrc"]
    static let xmlExtensions: Set<String> = ["xml", "xsd", "xsl", "xslt", "rss", "atom", "xaml", "xib", "storyboard", "csproj", "vcxproj",
                                             "props", "targets", "nuspec", "resx", "kml", "gpx", "wsdl", "xliff", "xlf", "pom", "opml", "dae"]
    static let delimitedExtensions: Set<String> = ["csv", "tsv", "tab", "psv"]
    static let gcodeExtensions: Set<String> = ["gcode", "gco", "g", "nc", "ngc"]
    static let sqliteExtensions: Set<String> = ["db", "sqlite", "sqlite3", "db3", "s3db", "sl3", "sqlitedb"]

    /// Classifies by name (and, for folders, by checking the file system).
    public static func of(_ url: URL) -> PreviewKind {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true { return values?.isPackage == true ? .other : .folder }
        return of(fileName: url.lastPathComponent)
    }

    /// Classifies a file name.
    public static func of(fileName: String) -> PreviewKind {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if jsonExtensions.contains(ext) { return .json }
        if xmlExtensions.contains(ext) { return .xml }
        if delimitedExtensions.contains(ext) { return .delimited }
        if gcodeExtensions.contains(ext) { return .gcode }
        if sqliteExtensions.contains(ext) { return .sqlite }
        switch ext {
        case "svg": return .svg
        case "bgcode": return .bgcode
        case "stl": return .stl
        case "qoi": return .qoi
        case "pdf": return .pdf
        case "plist", "html", "htm", "xhtml", "webarchive", "rtf", "rtfd": return .other
        default: break
        }
        if let language = Language.forFileName(fileName) { return .code(language.id) }
        return .other
    }

    /// Text formats rendered as HTML.
    public var isText: Bool {
        switch self {
        case .markdown, .json, .xml, .delimited, .code: true
        default: false
        }
    }

    /// Formats rendered as a bitmap.
    public var isImage: Bool {
        switch self {
        case .svg, .gcode, .bgcode, .stl, .qoi: true
        default: false
        }
    }

    /// Short type name for footers ("Markdown document").
    public var displayName: String {
        switch self {
        case .folder: "Folder"
        case .markdown: "Markdown document"
        case .json: "JSON document"
        case .xml: "XML document"
        case .delimited: "Delimited text"
        case .svg: "SVG image"
        case .gcode: "G-code toolpath"
        case .bgcode: "Binary G-code"
        case .stl: "STL model"
        case .qoi: "QOI image"
        case .pdf: "PDF document"
        case .sqlite: "SQLite database"
        case .code(let id): (Language.all.first { $0.id == id }?.name ?? "Text") + (id == "text" ? "" : " source")
        case .other: "Document"
        }
    }
}
