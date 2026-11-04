import Carbon.HIToolbox
import Foundation
import MacToysCore

/// Persisted options of Privacy Screen (`privacyscreen.json`).
public struct PrivacyScreenSettings: Codable, Equatable, Sendable {
    // MARK: Shortcuts

    @NullCodable public var lockShortcut: Shortcut? = Shortcut(kVK_ANSI_L, [.control, .option])
    @NullCodable public var blurShortcut: Shortcut? = Shortcut(kVK_ANSI_B, [.control, .option, .shift])
    @NullCodable public var focusShortcut: Shortcut? = Shortcut(kVK_ANSI_F, [.control, .option, .shift])
    @NullCodable public var privateAppsShortcut: Shortcut? = Shortcut(kVK_ANSI_P, [.control, .option, .shift])
    @NullCodable public var appLockShortcut: Shortcut? = Shortcut(kVK_ANSI_L, [.control, .option, .command])

    // MARK: Lock

    public var lockStyle: LockStyle = .frosted
    public var showClock = true
    public var showAwayMessage = false
    /// "Back at 3:30" — shown under the clock while locked.
    public var awayMessage = ""
    /// Minutes locked before the real macOS lock engages too; 0 = never.
    public var handOffMinutes = 5
    /// Offer Touch ID (or an Apple Watch) when the Mac has it.
    public var allowTouchID = true

    // MARK: Blur

    /// 0…1, Blur Screen.
    public var screenBlurStrength = 0.6
    /// 0…1, Focus Blur and Private Apps.
    public var focusBlurStrength = 0.45

    // MARK: Private Apps

    public var privateAppsOn = false
    /// App names or bundle identifiers, matched like other exclusion lists.
    public var privateApps: [String] = ["Messages", "Mail", "Slack"]
    /// Holding ⌥ over a blurred private app shows it without switching to it.
    public var peekWithOption = true

    // MARK: Away

    /// Minutes without input before Blur Screen engages; 0 = off.
    public var blurAfterIdleMinutes = 0
    /// Minutes without input before Lock engages; 0 = off.
    public var lockAfterIdleMinutes = 0
    /// Idle timers wait while another app keeps the display awake (video, calls, presentations).
    public var pauseWhileDisplayKeptAwake = true

    // MARK: Hot corner

    public var hotCorner: ScreenCorner = .none
    public var hotCornerAction: HotCornerAction = .lock
    /// Seconds the pointer must rest in the corner.
    public var hotCornerDelay = 0.5

    public init() {}

    /// Choices offered for the hand-off delay (minutes, 0 = never).
    public static let handOffChoices = [0, 1, 5, 15, 30, 60]
    /// Choices offered for idle timers (minutes, 0 = off).
    public static let idleChoices = [0, 1, 2, 5, 10, 15, 30, 60]
}

/// How the lock screen looks.
public enum LockStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The desktop, frosted by the window server.
    case frosted
    /// Frosted with a slow color glow.
    case ambient
    /// An opaque dark screen.
    case solid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .frosted: String(localized: "Frosted", comment: "Privacy Screen lock style: the desktop seen through frosted glass")
        case .ambient: String(localized: "Ambient", comment: "Privacy Screen lock style: frosted glass with a slow color glow")
        case .solid: String(localized: "Solid", comment: "Privacy Screen lock style: an opaque dark screen")
        }
    }

    public var subtitle: String {
        switch self {
        case .frosted: String(localized: "Your desktop, frosted beyond recognition.")
        case .ambient: String(localized: "Frosted glass with a slow, soft color glow.")
        case .solid: String(localized: "An opaque dark screen that shows nothing behind it.")
        }
    }
}

/// What a hot corner does.
public enum HotCornerAction: String, Codable, CaseIterable, Sendable, Identifiable {
    case lock, blur
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .lock: String(localized: "Lock Screen", comment: "Privacy Screen hot corner action")
        case .blur: String(localized: "Blur Screen", comment: "Privacy Screen hot corner action")
        }
    }
}

/// A corner of a display.
public enum ScreenCorner: String, Codable, CaseIterable, Sendable, Identifiable {
    case none, topLeft, topRight, bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: String(localized: "Off", comment: "Privacy Screen hot corner: no corner")
        case .topLeft: String(localized: "Top left", comment: "Screen corner")
        case .topRight: String(localized: "Top right", comment: "Screen corner")
        case .bottomLeft: String(localized: "Bottom left", comment: "Screen corner")
        case .bottomRight: String(localized: "Bottom right", comment: "Screen corner")
        }
    }
}

extension PrivacyScreenSettings {
    /// "5 minutes", "1 hour"; "Never" for 0.
    static func minutesTitle(_ minutes: Int, zero: String) -> String {
        guard minutes > 0 else { return zero }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}
