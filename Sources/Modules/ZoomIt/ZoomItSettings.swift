import Carbon.HIToolbox
import Foundation
import MacToysCore

/// ZoomIt's pen colors (R G B Y O P keys) plus white, for drawing on the blackboard.
public enum PenColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case red, green, blue, yellow, orange, pink, white

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .red: String(localized: "Red", comment: "Color name")
        case .green: String(localized: "Green", comment: "Color name")
        case .blue: String(localized: "Blue", comment: "Color name")
        case .yellow: String(localized: "Yellow", comment: "Color name")
        case .orange: String(localized: "Orange", comment: "Color name")
        case .pink: String(localized: "Pink", comment: "Color name")
        case .white: String(localized: "White", comment: "Color name")
        }
    }

    public var rgba: RGBA {
        switch self {
        case .red: RGBA(red: 1, green: 0.23, blue: 0.19)
        case .green: RGBA(red: 0.2, green: 0.78, blue: 0.35)
        case .blue: RGBA(red: 0.04, green: 0.52, blue: 1)
        case .yellow: RGBA(red: 0.96, green: 0.76, blue: 0)
        case .orange: RGBA(red: 1, green: 0.58, blue: 0)
        case .pink: RGBA(red: 1, green: 0.18, blue: 0.33)
        case .white: RGBA(red: 1, green: 1, blue: 1)
        }
    }

    /// The draw-mode letter key that selects it.
    public var key: Character? {
        switch self {
        case .red: "r"
        case .green: "g"
        case .blue: "b"
        case .yellow: "y"
        case .orange: "o"
        case .pink: "p"
        case .white: nil
        }
    }

    public static func forKey(_ c: Character) -> PenColor? {
        allCases.first { $0.key == c }
    }
}

/// Where the break timer sits on the screen.
public enum TimerPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .topLeft: String(localized: "Top left", comment: "Break timer position on the screen")
        case .top: String(localized: "Top", comment: "Break timer position on the screen")
        case .topRight: String(localized: "Top right", comment: "Break timer position on the screen")
        case .left: String(localized: "Left", comment: "Break timer position on the screen")
        case .center: String(localized: "Center", comment: "Break timer position on the screen")
        case .right: String(localized: "Right", comment: "Break timer position on the screen")
        case .bottomLeft: String(localized: "Bottom left", comment: "Break timer position on the screen")
        case .bottom: String(localized: "Bottom", comment: "Break timer position on the screen")
        case .bottomRight: String(localized: "Bottom right", comment: "Break timer position on the screen")
        }
    }
}

public enum BreakBackground: String, Codable, CaseIterable, Sendable, Identifiable {
    /// A dark screen.
    case none
    /// The desktop as it was, faded.
    case fadedDesktop
    /// The desktop, blurred.
    case blurredDesktop
    /// An image file.
    case image
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: String(localized: "None", comment: "Break timer background: a plain dark screen")
        case .fadedDesktop: String(localized: "Faded desktop")
        case .blurredDesktop: String(localized: "Blurred desktop")
        case .image: String(localized: "Image file")
        }
    }
}

public enum RecordFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case mp4, mov, gif
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: String(localized: "QuickTime movie")
        case .gif: String(localized: "Animated GIF")
        }
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Sendable, Identifiable {
    case h264, hevc
    public var id: String { rawValue }
    public var title: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
}

public struct ZoomItSettings: Codable, Equatable, Sendable {
    private static let mods: Modifiers = [.control, .option]

    // Zoom
    public var zoomShortcut: Shortcut? = Shortcut(kVK_ANSI_1, mods)
    public var animateZoom = true
    public var smoothImage = true
    /// 1.25…4.
    public var initialZoom: Double = 2

    // Draw
    public var drawShortcut: Shortcut? = Shortcut(kVK_ANSI_2, mods)
    public var penColor: PenColor = .red
    public var penWidth: Double = 5
    public var showToolbar = true
    /// Font family for text annotations; empty means the system font.
    public var textFont = ""
    public var textSize: Double = 32

    // Break
    public var breakShortcut: Shortcut? = Shortcut(kVK_ANSI_3, mods)
    public var breakMinutes: Double = 10
    public var showElapsedAfterExpiry = true
    public var playSoundOnExpiry = false
    /// A system sound name ("Glass") or a file path.
    public var expirySound = "Glass"
    public var timerOpacity: Double = 1
    public var timerPosition: TimerPosition = .center
    public var breakBackground: BreakBackground = .none
    public var backgroundImagePath = ""
    public var scaleBackgroundImage = false

    // Live zoom
    public var liveZoomShortcut: Shortcut? = Shortcut(kVK_ANSI_4, mods)
    public var liveZoomLevel: Double = 2

    // Record
    public var recordShortcut: Shortcut? = Shortcut(kVK_ANSI_5, mods)
    public var recordRegionShortcut: Shortcut? = Shortcut(kVK_ANSI_5, [.control, .option, .shift])
    public var recordWindowShortcut: Shortcut? = Shortcut(kVK_ANSI_5, [.control, .option, .command])
    public var recordFormat: RecordFormat = .mp4
    public var videoCodec: VideoCodec = .h264
    /// 0.1…1 of the native resolution.
    public var recordScaling: Double = 1
    public var gifScaling: Double = 0.5
    public var frameRate = 30
    public var captureSystemAudio = true
    public var captureMicrophone = false
    /// AVCaptureDevice unique id; empty for the system default.
    public var microphoneID = ""
    public var monoMicrophone = false
    public var lockRegionTo16x9 = false
    public var recordPointer = true

    // Snip
    public var snipShortcut: Shortcut? = Shortcut(kVK_ANSI_6, mods)
    public var snipSaveShortcut: Shortcut? = Shortcut(kVK_ANSI_6, [.control, .option, .shift])
    public var copyWhenSaving = false
    /// Space while dragging a snip starts dictation.
    public var snipDictation = true
    /// Listen from the start of every snip.
    public var dictateEverySnip = false
    /// Text put before the transcript ("Note:").
    public var dictationPrefix = ""

    // DemoType
    public var demoTypeShortcut: Shortcut? = Shortcut(kVK_ANSI_7, mods)
    public var demoTypeBackShortcut: Shortcut? = Shortcut(kVK_ANSI_7, [.control, .option, .shift])
    public var demoTypeFile = ""
    /// 10…100, larger is faster.
    public var typingSpeed: Double = 55
    /// Each key you press types the next characters instead of typing on its own.
    public var userDriven = false

    public init() {}
}
