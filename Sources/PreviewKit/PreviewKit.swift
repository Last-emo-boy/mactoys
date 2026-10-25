import Foundation

/// Renderers shared by Peek, the Quick Look extensions and Advanced Paste.
///
/// Everything here is free of MacToysCore so the sandboxed Quick Look extensions can link it.
/// Text formats render to self-contained HTML (no scripts, images inlined as `data:` URIs);
/// graphics formats render to `CGImage`.
public enum PreviewKit {
    public static let version = 2
}

/// Light, dark, or follow the system appearance.
public enum PreviewTheme: String, Codable, CaseIterable, Sendable {
    case auto, light, dark

    public var title: String {
        switch self {
        case .auto: String(localized: "Match system", comment: "Color theme: follow the system's light or dark appearance")
        case .light: String(localized: "Light", comment: "Color theme")
        case .dark: String(localized: "Dark", comment: "Color theme")
        }
    }
}
