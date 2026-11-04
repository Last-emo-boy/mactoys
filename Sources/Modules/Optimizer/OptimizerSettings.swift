import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Everything the Optimizer page configures. Stored as `optimizer.json`.
public struct OptimizerSettings: Codable, Equatable, Sendable {
    public var image = ImageSettings()
    public var video = VideoSettings()
    public var pdf = PDFSettings()

    /// Optimize every image copied to the clipboard.
    public var optimizeClipboard = false
    public var clipboardShortcut: Shortcut? = Shortcut(kVK_ANSI_O, [.control, .option])

    /// Show the drop zone when files are dragged toward `dropZoneCorner`.
    public var dropZoneEnabled = true
    public var dropZoneCorner: ScreenCorner = .bottomRight
    /// The format of the drop zone's "Convert" target.
    public var dropZoneConvertFormat: ImageFormat = .jpeg

    public var watchFolders: [WatchFolder] = WatchFolder.defaults

    public var showResults = true
    public var resultsCorner: ScreenCorner = .bottomRight
    public var hideResultsAfter: AutoHide = .tenSeconds
    public var output: OutputMode = .replace
    /// Keep the original modification date on files optimized in place.
    public var keepModificationDate = true
    public var backupRetention: BackupRetention = .week

    public init() {}
}

/// Image pipeline settings.
public struct ImageSettings: Codable, Equatable, Sendable {
    /// JPEG, HEIC and AVIF quality, 10…100.
    public var quality = 80
    /// Reduce PNGs to a palette (lossy, usually 60–80 % smaller).
    public var reduceColors = true
    public var maxColors = 256
    public var dither = true
    /// Convert PNGs without transparency to this format (nil: keep PNG).
    public var convertOpaquePNG: ImageFormat?
    /// Remove camera, location and editing metadata. Orientation and the color profile are kept.
    public var stripMetadata = true
    public var downscale: DownscaleMode = .off
    /// Longest side in pixels for `.maxSide`.
    public var maxSide = 2560
    /// Scale for `.factor`, 0.1…0.9.
    public var factor = 0.5

    public init() {}
}

public enum DownscaleMode: String, Codable, CaseIterable, Sendable {
    case off, maxSide, factor

    var title: String {
        switch self {
        case .off: String(localized: "Don’t downscale", comment: "Optimizer: downscale mode")
        case .maxSide: String(localized: "Fit within a size", comment: "Optimizer: downscale mode, limit the longest side")
        case .factor: String(localized: "Scale by a factor", comment: "Optimizer: downscale mode, e.g. to 50 %")
        }
    }
}

/// Video pipeline settings.
public struct VideoSettings: Codable, Equatable, Sendable {
    public var codec: VideoCodec = .hevc
    public var quality: VideoQuality = .balanced
    public var maxResolution: VideoResolution = .original
    public var maxFrameRate: FrameRateCap = .original
    public var removeAudio = false
    /// Playback speed of the result, 1…4.
    public var speed = 1.0
    /// Turn animated GIFs into much smaller MP4 videos (saved next to the GIF).
    public var convertGIFs = true

    public init() {}
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case hevc, h264

    /// Codec names are not translated.
    var title: String {
        switch self {
        case .hevc: "HEVC (H.265)"
        case .h264: "H.264"
        }
    }

    var subtitle: String {
        switch self {
        case .hevc: String(localized: "Smaller files; plays on every Apple device from 2017 on.", comment: "Optimizer: HEVC codec description")
        case .h264: String(localized: "Larger files; plays everywhere, including old PCs and browsers.", comment: "Optimizer: H.264 codec description")
        }
    }
}

public enum VideoQuality: String, Codable, CaseIterable, Sendable {
    case smaller, balanced, higher

    var title: String {
        switch self {
        case .smaller: String(localized: "Smallest file", comment: "Optimizer: video quality level")
        case .balanced: String(localized: "Balanced", comment: "Optimizer: video quality level")
        case .higher: String(localized: "Higher quality", comment: "Optimizer: video quality level")
        }
    }
}

public enum VideoResolution: String, Codable, CaseIterable, Sendable {
    case original, p2160, p1440, p1080, p720, p480

    /// The largest short side, nil for no limit.
    var shortSide: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    var title: String {
        switch self {
        case .original: String(localized: "Keep resolution", comment: "Optimizer: video resolution option")
        case .p2160: "4K (2160p)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }
}

public enum FrameRateCap: String, Codable, CaseIterable, Sendable {
    case original, fps60, fps30, fps24

    var fps: Double? {
        switch self {
        case .original: nil
        case .fps60: 60
        case .fps30: 30
        case .fps24: 24
        }
    }

    var title: String {
        switch self {
        case .original: String(localized: "Keep frame rate", comment: "Optimizer: video frame rate option")
        case .fps60: String(localized: "Up to \(60) fps", comment: "Optimizer: frame rate limit; the value is frames per second")
        case .fps30: String(localized: "Up to \(30) fps", comment: "Optimizer: frame rate limit; the value is frames per second")
        case .fps24: String(localized: "Up to \(24) fps", comment: "Optimizer: frame rate limit; the value is frames per second")
        }
    }
}

/// PDF pipeline settings.
public struct PDFSettings: Codable, Equatable, Sendable {
    /// Embedded images are resampled to at most this resolution.
    public var imageResolution = 150
    /// JPEG quality for re-encoded images, 10…100.
    public var imageQuality = 70

    public static let resolutions = [72, 100, 150, 200, 300]

    public init() {}
}

public enum ScreenCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: String(localized: "Top left", comment: "Screen corner")
        case .topRight: String(localized: "Top right", comment: "Screen corner")
        case .bottomLeft: String(localized: "Bottom left", comment: "Screen corner")
        case .bottomRight: String(localized: "Bottom right", comment: "Screen corner")
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

public enum AutoHide: String, Codable, CaseIterable, Sendable {
    case fiveSeconds, tenSeconds, thirtySeconds, never

    var seconds: TimeInterval? {
        switch self {
        case .fiveSeconds: 5
        case .tenSeconds: 10
        case .thirtySeconds: 30
        case .never: nil
        }
    }

    var title: String {
        switch self {
        case .never: String(localized: "Never", comment: "Optimizer: hide result cards never")
        default: Duration.seconds(seconds ?? 0).formatted(.units(allowed: [.seconds], width: .wide))
        }
    }
}

public enum OutputMode: String, Codable, CaseIterable, Sendable {
    /// Replace the file; the original goes to the backups folder.
    case replace
    /// Save `name-optimized.ext` next to the original.
    case alongside

    var title: String {
        switch self {
        case .replace: String(localized: "Replace the original", comment: "Optimizer: where optimized files go")
        case .alongside: String(localized: "Save a copy next to it", comment: "Optimizer: where optimized files go")
        }
    }
}

public enum BackupRetention: String, Codable, CaseIterable, Sendable {
    case day, week, month, forever

    var interval: TimeInterval? {
        switch self {
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .forever: nil
        }
    }

    var title: String {
        switch self {
        case .day: String(localized: "For a day", comment: "Optimizer: how long originals are kept")
        case .week: String(localized: "For a week", comment: "Optimizer: how long originals are kept")
        case .month: String(localized: "For a month", comment: "Optimizer: how long originals are kept")
        case .forever: String(localized: "Until I delete them", comment: "Optimizer: how long originals are kept")
        }
    }
}

/// A folder whose new files are optimized as they appear.
public struct WatchFolder: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var path: String
    public var enabled = true
    public var kinds: Set<MediaKind> = [.image, .video]
    public var action: WatchAction = .optimize

    public init(path: String, enabled: Bool = true, kinds: Set<MediaKind> = [.image, .video], action: WatchAction = .optimize) {
        self.path = path
        self.enabled = enabled
        self.kinds = kinds
        self.action = action
    }

    public var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true) }

    /// Where macOS saves screenshots (Screenshot app › Options › Save to), the Desktop by default.
    static var screenshotsFolder: String {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let custom, !custom.isEmpty { return (custom as NSString).abbreviatingWithTildeInPath }
        return "~/Desktop"
    }

    /// Suggested folders, off until the user turns them on.
    static var defaults: [WatchFolder] {
        [WatchFolder(path: screenshotsFolder, enabled: false, kinds: [.image, .video], action: .optimize),
         WatchFolder(path: "~/Downloads", enabled: false, kinds: [.image, .pdf], action: .optimize)]
    }
}

/// What a watch folder does with a new file.
public enum WatchAction: Codable, Equatable, Hashable, Sendable {
    case optimize
    case downscale
    case convert(ImageFormat)

    var title: String {
        switch self {
        case .optimize: String(localized: "Optimize", comment: "Optimizer: watch folder action")
        case .downscale: String(localized: "Optimize and downscale to 50 %", comment: "Optimizer: watch folder action")
        case .convert(let f): String(localized: "Convert images to \(f.title)", comment: "Optimizer: watch folder action; the value is a format such as JPEG")
        }
    }

    static var all: [WatchAction] {
        [.optimize, .downscale] + ImageFormat.writable.map { .convert($0) }
    }
}
