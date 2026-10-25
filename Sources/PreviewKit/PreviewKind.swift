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
        case .folder: String(localized: "Folder", comment: "File type")
        case .markdown: String(localized: "Markdown document", comment: "File type")
        case .json: String(localized: "JSON document", comment: "File type")
        case .xml: String(localized: "XML document", comment: "File type")
        case .delimited: String(localized: "Delimited text", comment: "File type: CSV, TSV and similar")
        case .svg: String(localized: "SVG image", comment: "File type")
        case .gcode: String(localized: "G-code toolpath", comment: "File type: 3D printer / CNC instructions")
        case .bgcode: String(localized: "Binary G-code", comment: "File type")
        case .stl: String(localized: "STL model", comment: "File type: 3D model")
        case .qoi: String(localized: "QOI image", comment: "File type")
        case .pdf: String(localized: "PDF document", comment: "File type")
        case .sqlite: String(localized: "SQLite database", comment: "File type")
        case .code(let id):
            if id != "text", let name = Language.all.first(where: { $0.id == id })?.name {
                String(localized: "\(name) source", comment: "File type, e.g. “Swift source”: %@ is a programming language name")
            } else {
                String(localized: "Plain Text", comment: "File type")
            }
        case .other: String(localized: "Document", comment: "File type: anything else")
        }
    }
}
