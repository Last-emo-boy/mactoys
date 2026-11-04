import AppKit
import MacToysCore
import Observation

/// What the settings page and the menu bar show about tiling right now.
@MainActor
@Observable
final class TilingStatus {
    struct Tile: Equatable {
        /// Front window first.
        var apps: [App]
    }

    struct App: Equatable {
        var bundleID: String?
        var name: String
    }

    struct Display: Identifiable, Equatable {
        var id: String
        var name: String
        var number: Int
        var shape: DisplayShape
        /// Width ÷ height of the full display.
        var aspect: CGFloat
        var isMain: Bool
        var isBuiltIn: Bool
        var kind: TileLayoutKind
        var main: MainSize
        var capacity: Int
        var tiles: [Tile]
    }

    var running = false
    var paused = false
    var stageManager = false
    var displays: [Display] = []
    var floating = 0
    var noPeek = false
    var cleanSpace = false
    var focusMode = false

    /// Tiling arranges windows right now.
    var isTiling: Bool { running && !paused && !stageManager }

    /// The display with the menu bar.
    var mainDisplay: Display? { displays.first { $0.isMain } ?? displays.first }
}

/// Follows Stage Manager (`GloballyEnabled` in `com.apple.WindowManager`). There is no
/// notification for it, so the preference is read every couple of seconds while tiling runs.
@MainActor
final class StageManagerMonitor {
    private(set) var isOn = false
    private var timer: Timer?
    private var onChange: ((Bool) -> Void)?
    private static let domain = "com.apple.WindowManager" as CFString

    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        isOn = Self.read()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onChange = nil
    }

    func refresh() {
        let now = Self.read()
        guard now != isOn else { return }
        isOn = now
        onChange?(now)
    }

    static func read() -> Bool {
        CFPreferencesAppSynchronize(domain)
        return StageManagerState.isEnabled(CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain))
    }
}
