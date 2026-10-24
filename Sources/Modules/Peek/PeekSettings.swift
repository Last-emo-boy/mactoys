import Carbon.HIToolbox
import CoreGraphics
import MacToysCore
import PreviewKit

/// Peek's settings (`peek.json`).
struct PeekSettings: Codable, Equatable {
    var activation: Shortcut? = Shortcut(kVK_ANSI_P, [.control, .option])
    /// With a single file selected in Finder, ←/→ step through the other items of its folder.
    var browseFolder = true
    var alwaysOnTop = false
    var closeOnFocusLoss = false
    var confirmDelete = true
    /// Metadata footer under the preview.
    var showDetails = true
    /// Keep the window where (and as large as) the user left it instead of fitting each file.
    var pinned = false
    var pinnedFrame: CGRect?

    // Source code and text
    var codeTheme: PreviewTheme = .auto
    var codeWrap = false
    var codeLineNumbers = true
    var codeFontSize = 12.0
    var codeFormat = true
    var codeMaxFileSizeKB = 10_240

    // Markdown
    var markdownAllowRemoteImages = false

    /// Rendering options for PreviewKit (Finder Add-ons settings for the rest).
    func previewOptions(base: FinderAddonsSettings) -> PreviewOptions {
        var s = base
        s.codeTheme = codeTheme
        s.codeWrap = codeWrap
        s.codeLineNumbers = codeLineNumbers
        s.codeFontSize = codeFontSize
        s.codeFormat = codeFormat
        s.codeMaxFileSizeKB = codeMaxFileSizeKB
        s.markdownAllowRemoteImages = markdownAllowRemoteImages
        s.markdownShowLocalImages = true
        var options = PreviewOptions(settings: s)
        options.markdownTheme = codeTheme
        return options
    }
}
