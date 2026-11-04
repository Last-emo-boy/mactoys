import Carbon.HIToolbox
import CoreGraphics
import Foundation
import MacToysCore

/// AppKit also brings in QuickDraw's `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// Persisted options of Screenshot (`screenshot.json`).
public struct ScreenshotSettings: Codable, Equatable, Sendable {
    // MARK: Shortcuts

    public var areaShortcut: Shortcut? = Shortcut(kVK_ANSI_A, [.control, .option])
    public var windowShortcut: Shortcut?
    public var screenShortcut: Shortcut?
    public var previousAreaShortcut: Shortcut?
    public var historyShortcut: Shortcut?

    // MARK: Capture

    /// A loupe with the pixels under the crosshair while selecting.
    public var showMagnifier = true
    /// Thin guide lines across the whole screen through the pointer.
    public var showCrosshair = true
    /// Select over a still image of the screen (catches menus, tooltips and video frames).
    public var freezeScreen = false
    /// Start an area capture with the previous area already selected.
    public var rememberLastArea = true
    /// Leave Finder's desktop icons out of captures.
    public var hideDesktopIcons = false
    /// Draw the pointer into window and screen captures.
    public var includePointer = false
    /// Seconds to wait before capturing (0 = right away).
    public var selfTimer = 0
    public var screenTarget: ScreenTarget = .underPointer

    // MARK: Window captures

    public var windowShadow = true
    /// Transparent margin around a captured window, in points.
    public var windowPadding: Double = 0

    // MARK: After capture

    public var showQuickAccess = true
    public var copyToClipboard = false
    public var saveToFile = true
    public var openAnnotate = false
    public var pinToScreen = false
    public var autoBeautify: AutoBeautify = .off
    public var playSound = true

    // MARK: Quick Access overlay

    public var overlayCorner: OverlayCorner = .bottomLeft
    public var overlaySize: OverlaySize = .medium
    /// Seconds before a card closes by itself (0 = never). The timer pauses while the pointer is over it.
    public var autoCloseSeconds = 30

    // MARK: Output

    /// Folder for saved captures; empty means the Desktop.
    public var saveFolder = ""
    /// File name with the `$YYYY $MM $DD $hh $mm $ss …` date tokens.
    public var fileNameTemplate = FileNamer.defaultTemplate
    public var format: ImageFormat = .png
    public var jpegQuality: Double = 0.9
    /// Keep the display's native resolution; off writes 1× images.
    public var retina = true

    // MARK: Annotate and beautify

    public var annotationColor: RGBA = MarkupPalette.colors[0]
    public var annotationSize: MarkupSize = .medium
    public var curvedArrows = false
    public var beautify = BeautifyStyle()

    // MARK: History

    public var keepHistory = true
    public var historyLimitMB = 500
    /// Days to keep captures (0 = until the size limit removes them).
    public var historyMaxAgeDays = 30

    public init() {}

    /// The folder captures are saved to.
    var saveFolderURL: URL {
        if !saveFolder.isEmpty {
            return URL(fileURLWithPath: (saveFolder as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}

/// Small state remembered between captures (`screenshot-state.json`), kept apart from settings
/// so taking a screenshot doesn't re-register hotkeys.
struct ScreenshotState: Codable, Equatable, Sendable {
    /// The last selected area: the display it was on and the rect in that display's points (top-left origin).
    struct Area: Codable, Equatable, Sendable {
        var display: String
        var rect: CGRect
    }

    var lastArea: Area?
}

/// Which display "Capture Screen" takes.
public enum ScreenTarget: String, Codable, CaseIterable, Sendable, Identifiable {
    case underPointer, choose
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .underPointer: String(localized: "The display under the pointer", comment: "Screen capture target")
        case .choose: String(localized: "Ask which display", comment: "Screen capture target: click a display to capture it")
        }
    }
}

/// Which captures get the beautify background right away.
public enum AutoBeautify: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, windows, all
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off", comment: "Beautify automatically: never")
        case .windows: String(localized: "Window captures", comment: "Beautify automatically: only window captures")
        case .all: String(localized: "All captures", comment: "Beautify automatically: every capture")
        }
    }

    func applies(to kind: CaptureKind) -> Bool {
        switch self {
        case .off: false
        case .windows: kind == .window
        case .all: true
        }
    }
}

/// Screen corner of the Quick Access overlay.
public enum OverlayCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomLeft: String(localized: "Bottom left", comment: "Quick Access overlay position")
        case .bottomRight: String(localized: "Bottom right", comment: "Quick Access overlay position")
        case .topLeft: String(localized: "Top left", comment: "Quick Access overlay position")
        case .topRight: String(localized: "Top right", comment: "Quick Access overlay position")
        }
    }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

public enum OverlaySize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium, large
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .small: String(localized: "Small", comment: "Quick Access card size")
        case .medium: String(localized: "Medium", comment: "Quick Access card size")
        case .large: String(localized: "Large", comment: "Quick Access card size")
        }
    }
    /// Card width in points.
    var width: CGFloat {
        switch self {
        case .small: 168
        case .medium: 216
        case .large: 272
        }
    }
}

/// File format of saved captures.
public enum ImageFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case png, jpeg, heic
    public var id: String { rawValue }
    /// Shown as is (format names aren't translated).
    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }
    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }
    /// Uniform type identifier for ImageIO.
    var typeIdentifier: String {
        switch self {
        case .png: "public.png"
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        }
    }
    var isLossy: Bool { self != .png }
}

/// How a capture was taken.
enum CaptureKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case area, window, screen, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .area: String(localized: "Area", comment: "Kind of screenshot: a selected area")
        case .window: String(localized: "Window", comment: "Kind of screenshot: one window")
        case .screen: String(localized: "Screen", comment: "Kind of screenshot: a whole display")
        case .file: String(localized: "Image file", comment: "Kind of screenshot: an image opened from a file")
        }
    }
    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .file: "photo"
        }
    }
}
