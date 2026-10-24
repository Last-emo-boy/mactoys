import CoreGraphics
import Foundation

/// Finder Add-ons settings, stored by the app as `Settings/finderaddons.json` and read by the
/// Quick Look extensions. Lives here (not in the module) because the extensions can't link MacToysCore.
public struct FinderAddonsSettings: Codable, Equatable, Sendable {
    // Quick Look previews (Space in Finder)
    public var previewMarkdown = true
    public var previewSourceCode = true
    public var previewJSONXML = true
    public var previewDelimited = true
    public var previewSVG = true
    public var previewGCode = true
    public var previewSTL = true
    public var previewQOI = true

    // Finder thumbnails (icons)
    public var thumbnailSVG = true
    public var thumbnailGCode = true
    public var thumbnailSTL = true
    public var thumbnailQOI = true
    public var thumbnailMarkdown = true
    public var thumbnailPDF = true

    // Source code
    public var codeTheme: PreviewTheme = .auto
    public var codeWrap = false
    public var codeLineNumbers = true
    public var codeFontSize = 12.0
    /// Reformat JSON and XML for reading (the file is unchanged).
    public var codeFormat = true
    public var codeMaxFileSizeKB = 10_240

    // Markdown
    public var markdownTheme: PreviewTheme = .auto
    public var markdownShowLocalImages = true
    public var markdownAllowRemoteImages = false
    public var markdownAllowHTML = true

    // SVG
    public var svgBackground: ImageBackground = .checkerboard

    // G-code
    public var gcodeView: ToolpathStyle.View = .isometric
    public var gcodeShowTravel = false
    /// Finder icons use the slicer's embedded thumbnail when there is one.
    public var gcodeThumbnailUsesEmbedded = true

    // STL
    public var stlColor = "#3D8EF0"
    public var stlBackground = "#1B1D22"
    public var stlTransparentThumbnails = true

    public init() {}

    public var codeOptions: CodeOptions {
        CodeOptions(theme: codeTheme, lineNumbers: codeLineNumbers, wrap: codeWrap, fontSize: codeFontSize)
    }

    /// Whether the preview extension should render this kind (false: fall back to the system).
    public func previewEnabled(_ kind: PreviewKind) -> Bool {
        switch kind {
        case .markdown: previewMarkdown
        case .json, .xml: previewJSONXML
        case .delimited: previewDelimited
        case .code: previewSourceCode
        case .svg: previewSVG
        case .gcode, .bgcode: previewGCode
        case .stl: previewSTL
        case .qoi: previewQOI
        case .folder, .pdf, .sqlite, .other: false
        }
    }

    public func thumbnailEnabled(_ kind: PreviewKind) -> Bool {
        switch kind {
        case .svg: thumbnailSVG
        case .gcode, .bgcode: thumbnailGCode
        case .stl: thumbnailSTL
        case .qoi: thumbnailQOI
        case .markdown: thumbnailMarkdown
        case .pdf: thumbnailPDF
        default: false
        }
    }

    /// Loads the app's saved settings, tolerating missing keys (stored values overlay the defaults).
    /// Works inside the sandboxed extensions: the path is built from the real home folder, which
    /// the extensions may read thanks to a temporary-exception entitlement.
    public static func load(from url: URL = defaultURL) -> FinderAddonsSettings {
        guard let stored = try? Data(contentsOf: url) else { return FinderAddonsSettings() }
        do {
            let defaults = try JSONEncoder().encode(FinderAddonsSettings())
            guard var base = try JSONSerialization.jsonObject(with: defaults) as? [String: Any],
                  let overlay = try JSONSerialization.jsonObject(with: stored) as? [String: Any] else {
                return FinderAddonsSettings()
            }
            for (k, v) in overlay { base[k] = v }
            return try JSONDecoder().decode(FinderAddonsSettings.self, from: JSONSerialization.data(withJSONObject: base))
        } catch {
            return FinderAddonsSettings()
        }
    }

    /// `~/Library/Application Support/MacToys/Settings/finderaddons.json` in the user's real home
    /// (not a sandbox container).
    public static var defaultURL: URL {
        RealHome.url.appendingPathComponent("Library/Application Support/MacToys/Settings/finderaddons.json")
    }
}

/// The user's home folder even inside an app sandbox (where `NSHomeDirectory()` is the container).
public enum RealHome {
    public static var url: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

/// `#RRGGBB` / `#RRGGBBAA` parsing for colors kept as strings in shared settings.
public enum HexColor {
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            return (Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255, 1)
        }
        return (Double(v >> 24 & 0xFF) / 255, Double(v >> 16 & 0xFF) / 255, Double(v >> 8 & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func cgColor(_ hex: String, fallback: CGColor = CGColor(srgbRed: 0.24, green: 0.56, blue: 0.94, alpha: 1)) -> CGColor {
        guard let c = components(hex) else { return fallback }
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
