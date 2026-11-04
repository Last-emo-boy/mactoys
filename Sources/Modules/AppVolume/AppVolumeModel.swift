import AppKit
import CoreAudio
import MacToysCore
import Observation
import SwiftUI

/// One app in the flyout.
struct AppRow: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case playing
        /// Stopped playing a moment ago (still listed for `lingerSeconds`), or pinned and silent.
        case quiet
        /// Pinned but not running.
        case notRunning
    }

    var identity: AppIdentity
    var state: State
    var id: String { identity.key }
}

enum FlyoutList {
    /// Pinned apps first, in pin order; then apps playing now or within `lingerSeconds`, in the order
    /// they first played (so rows don't jump around while you reach for a slider).
    static func rows(apps: [AudioApp], settings: AppVolumeSettings, firstPlayed: [String: Date],
                     lastPlayed: [String: Date], now: Date) -> [AppRow] {
        let byKey = Dictionary(apps.map { ($0.identity.key, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [AppRow] = []
        for key in settings.pinnedApps {
            if let app = byKey[key] {
                guard !settings.isExcluded(app.identity) else { continue }
                rows.append(AppRow(identity: app.identity, state: app.isPlaying ? .playing : .quiet))
            } else {
                let name = settings.apps[key]?.name ?? key
                rows.append(AppRow(identity: AppIdentity(key: key, name: name.isEmpty ? key : name), state: .notRunning))
            }
        }
        let pinned = Set(settings.pinnedApps)
        let others = apps.filter { app in
            let key = app.identity.key
            guard !pinned.contains(key), !settings.isExcluded(app.identity) else { return false }
            if app.isPlaying { return true }
            guard let t = lastPlayed[key] else { return false }
            return now.timeIntervalSince(t) < Double(settings.lingerSeconds)
        }
        .sorted { (firstPlayed[$0.identity.key] ?? now, $0.name) < (firstPlayed[$1.identity.key] ?? now, $1.name) }
        rows += others.map { AppRow(identity: $0.identity, state: $0.isPlaying ? .playing : .quiet) }
        return rows
    }
}

/// Volume, mute and balance of a system device as the flyout shows them.
struct DeviceControls: Equatable, Sendable {
    var volume: Float?
    var canSetVolume = false
    var muted = false
    var canMute = false
    var balance: Float?
    var sampleRates: [Double] = []
}

/// Live state behind the flyout and the settings page.
@MainActor
@Observable
final class AppVolumeStore {
    var world = AudioWorld()
    var rows: [AppRow] = []
    var output = DeviceControls()
    var input = DeviceControls()
    var capture: TapController.Capture = .unknown
    /// Apps whose sound couldn't be taken over, with the reason.
    var failures: [String: String] = [:]
    /// Apps whose sound goes through MacToys right now.
    var processing: Set<String> = []
    var hasScanned = false

    var playingCount: Int { rows.filter { $0.state == .playing }.count }
}

/// Meter values (0…1 on a −60…0 dBFS scale), kept apart so only meters redraw 30 times a second.
@MainActor
@Observable
final class LevelStore {
    var levels: [String: StereoLevel] = [:]

    /// Folds in fresh peaks with a fast rise and a ~0.6 s fall.
    func update(_ peaks: [String: StereoLevel], elapsed: Double) {
        let fall = Float(1.6 * elapsed)
        var next: [String: StereoLevel] = [:]
        for key in Set(peaks.keys).union(levels.keys) {
            let raw = peaks[key] ?? .silent
            let old = levels[key] ?? .silent
            let l = max(Self.scale(raw.left), old.left - fall)
            let r = max(Self.scale(raw.right), old.right - fall)
            if l > 0.001 || r > 0.001 || peaks[key] != nil { next[key] = StereoLevel(left: max(0, l), right: max(0, r)) }
        }
        if next != levels { levels = next }
    }

    func clear() { if !levels.isEmpty { levels = [:] } }

    nonisolated static func scale(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(peak) + 60) / 60))
    }
}

/// App icons, cached per app.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for identity: AppIdentity) -> NSImage? {
        if let cached = cache[identity.key] { return cached }
        let path = identity.bundlePath
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identity.key)?.path
        guard let path, identity.kind == .app else { return nil }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[identity.key] = image
        return image
    }
}

/// An app's icon, or a tinted symbol tile for system sounds, web content and apps without one.
struct AppIconView: View {
    let identity: AppIdentity
    var size: CGFloat = 30

    var body: some View {
        if let image = AppIcons.icon(for: identity) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            let (symbol, tint) = Self.fallback(identity)
            ModuleIcon(symbol: symbol, tint: tint, size: size * 0.86)
                .frame(width: size, height: size)
        }
    }

    static func fallback(_ identity: AppIdentity) -> (String, Tint) {
        switch identity.kind {
        case .systemSounds: ("bell.fill", .graphite)
        case .webContent: ("globe", .blue)
        case .process: ("waveform", .graphite)
        case .app:
            // Sample apps in previews that may not be installed.
            identity.key == "us.zoom.xos" ? ("video.fill", .blue) : ("app.fill", .graphite)
        }
    }
}
