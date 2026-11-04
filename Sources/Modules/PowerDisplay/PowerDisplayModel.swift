import AppKit
import CoreGraphics
import Foundation
import MacToysCore
import Observation

/// Per-monitor preferences, keyed by the monitor's stable id.
struct MonitorPrefs: Codable, Equatable {
    var hidden = false
    var showContrast = true
    var showVolume = true
    /// Off by default: each asks for confirmation when turned on (as in PowerToys).
    var showInputSource = false
    var showColorTemperature = false
    var showPowerState = false
    var excludeFromLinkedBrightness = false
    /// Last values set through MacToys, re-applied at launch when "restore" is on (raw VCP values).
    var lastBrightness: Int?
    var lastColorPreset: Int?
    /// Cached MCCS capabilities string (reading it takes a second or two).
    var capabilities: String?
    /// The name last seen, for disconnected monitors in profile editors.
    var lastName: String?
    /// Starred resolutions (`ResolutionKey.string`), in the order they were starred.
    var favoriteModes: [String] = []
    /// Software dimming (0…1) last set, restored at launch with "restore" on.
    var lastSoftDim: Double?
    /// Brightness level offset to the sync source (`BrightnessLevel` units).
    var syncOffset: Double?

    func shows(_ feature: DisplayFeature) -> Bool {
        switch feature {
        case .brightness: true
        case .contrast: showContrast
        case .volume: showVolume
        case .inputSource: showInputSource
        case .colorTemperature: showColorTemperature
        case .powerState: showPowerState
        }
    }
}

extension MonitorPrefs {
    /// Missing keys take their defaults: monitor entries live in a dictionary, which the settings
    /// store's default merge doesn't reach, and older files lack the newer fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorPrefs()
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? d.hidden
        showContrast = try c.decodeIfPresent(Bool.self, forKey: .showContrast) ?? d.showContrast
        showVolume = try c.decodeIfPresent(Bool.self, forKey: .showVolume) ?? d.showVolume
        showInputSource = try c.decodeIfPresent(Bool.self, forKey: .showInputSource) ?? d.showInputSource
        showColorTemperature = try c.decodeIfPresent(Bool.self, forKey: .showColorTemperature) ?? d.showColorTemperature
        showPowerState = try c.decodeIfPresent(Bool.self, forKey: .showPowerState) ?? d.showPowerState
        excludeFromLinkedBrightness = try c.decodeIfPresent(Bool.self, forKey: .excludeFromLinkedBrightness) ?? d.excludeFromLinkedBrightness
        lastBrightness = try c.decodeIfPresent(Int.self, forKey: .lastBrightness)
        lastColorPreset = try c.decodeIfPresent(Int.self, forKey: .lastColorPreset)
        capabilities = try c.decodeIfPresent(String.self, forKey: .capabilities)
        lastName = try c.decodeIfPresent(String.self, forKey: .lastName)
        favoriteModes = try c.decodeIfPresent([String].self, forKey: .favoriteModes) ?? d.favoriteModes
        lastSoftDim = try c.decodeIfPresent(Double.self, forKey: .lastSoftDim)
        syncOffset = try c.decodeIfPresent(Double.self, forKey: .syncOffset)
    }
}

/// Saved values for one monitor in a profile; nil fields are left alone when applying.
struct ProfileValues: Codable, Equatable {
    /// Percent 0…100.
    var brightness: Int?
    var contrast: Int?
    var volume: Int?
    /// Raw VCP 0x14 value.
    var colorPreset: Int?

    var isEmpty: Bool { brightness == nil && contrast == nil && volume == nil && colorPreset == nil }
}

/// A named set of monitor values. The numeric id never changes, so the CLI and Light Switch can rely on it.
struct DisplayProfileRecord: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var monitors: [String: ProfileValues] = [:]
}

/// A friendlier name for an input source or color preset value.
struct VCPNameMapping: Codable, Equatable, Identifiable {
    var id = UUID()
    /// 0x60 (input source) or 0x14 (color preset).
    var code: Int
    var value: Int
    var name: String
    /// Nil applies to every monitor.
    var monitorID: String?
}

enum WheelTarget: String, Codable, CaseIterable {
    case off, primary, all

    var title: String {
        switch self {
        case .off: String(localized: "Off", comment: "Menu bar mouse wheel: does nothing")
        case .primary: String(localized: "Primary display", comment: "Menu bar mouse wheel changes the brightness of")
        case .all: String(localized: "All displays", comment: "Menu bar mouse wheel changes the brightness of")
        }
    }
}

struct PowerDisplaySettings: Codable, Equatable {
    var activation: Shortcut? = Shortcut(11, [.control, .option])   // ⌃⌥B
    var showMenuBarIcon = true
    var menuBarWheel: WheelTarget = .off
    var wheelIncrement = 5
    /// Seconds to wait after displays change before rescanning.
    var refreshDelay = 3.0
    var maxCompatibility = false
    var restoreOnLaunch = false
    var showProfileSwitcher = true
    var showIdentifyButton = true
    var linkedBrightness = false
    var profiles: [DisplayProfileRecord] = []
    var nextProfileID = 1
    var lastAppliedProfile: Int?
    var vcpNames: [VCPNameMapping] = []
    var monitors: [String: MonitorPrefs] = [:]

    /// Brightness sliders continue below the hardware minimum by dimming in software.
    var softwareDimming = true
    var dimMethod: DimMethod = .automatic
    /// How dark software dimming goes at the end of the slider: 0.85 leaves 15 % of the light.
    var maxSoftwareDim = 0.85
    /// Brightness sliders of EDR displays continue past 100 % into the extra headroom.
    var extraBrightness = false
    /// The multiplier at the end of the extra brightness range.
    var maxExtraBrightness = 1.6
    /// After a resolution change, ask to keep it and switch back after 15 seconds otherwise.
    var confirmModeChanges = true
    /// Leave out 1× modes whose size also exists as HiDPI.
    var hideLowResolutionModes = false
    /// Displays follow this monitor's brightness, keeping their distance (nil: off). Linked
    /// brightness takes precedence.
    var syncSource: String?
    var showNightShiftButton = true
    var pip = PiPOptions()
    var virtualDisplays: [VirtualDisplayConfig] = []
    /// Set while a color table is dimmed; a launch that finds it set hands the tables back to ColorSync.
    var gammaDimmed = false

    static let wheelIncrements = [1, 2, 5, 10, 15, 20, 25]
    static let maxSoftwareDimRange: ClosedRange<Double> = 0.5...0.95
    static let maxExtraBrightnessRange: ClosedRange<Double> = 1.2...2.0

    func prefs(_ id: String) -> MonitorPrefs { monitors[id] ?? MonitorPrefs() }

    /// The display name for a discrete value: custom mapping (monitor first, then global), then MCCS
    /// in English (command line).
    func valueName(_ feature: DisplayFeature, _ value: UInt16, monitor: String?) -> String {
        customName(feature, value, monitor: monitor) ?? MCCS.name(feature, value) ?? MCCS.hex(Int(value))
    }

    /// `valueName` for the UI, with MCCS names localized.
    func localizedValueName(_ feature: DisplayFeature, _ value: UInt16, monitor: String?) -> String {
        customName(feature, value, monitor: monitor) ?? MCCS.localizedName(feature, value) ?? MCCS.hex(Int(value))
    }

    private func customName(_ feature: DisplayFeature, _ value: UInt16, monitor: String?) -> String? {
        let code = Int(feature.vcp)
        let m = vcpNames.first(where: { $0.code == code && $0.value == Int(value) && $0.monitorID == monitor && monitor != nil })
            ?? vcpNames.first(where: { $0.code == code && $0.value == Int(value) && $0.monitorID == nil })
        return m?.name
    }

    /// Adds a profile with the next free id.
    mutating func addProfile(named name: String, monitors: [String: ProfileValues]) -> Int {
        let id = max(nextProfileID, (profiles.map(\.id).max() ?? 0) + 1)
        profiles.append(DisplayProfileRecord(id: id, name: name, monitors: monitors))
        nextProfileID = id + 1
        return id
    }

    mutating func moveProfile(id: Int, by delta: Int) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard profiles.indices.contains(j) else { return }
        profiles.swapAt(i, j)
    }

    /// A fresh profile name: "Profile 3".
    func suggestedProfileName() -> String {
        var n = profiles.count + 1
        while profiles.contains(where: { $0.name == String(localized: "Profile \(n)") }) { n += 1 }
        return String(localized: "Profile \(n)", comment: "Default name of a new profile; the placeholder is a number")
    }
}

/// What applying a profile writes: (monitor id, feature, raw value) in a stable order.
enum ProfilePlan {
    static func writes(_ profile: DisplayProfileRecord, monitors: [MonitorSnapshot]) -> [(String, DisplayFeature, UInt16)] {
        var out: [(String, DisplayFeature, UInt16)] = []
        for m in monitors {
            guard let v = profile.monitors[m.id] else { continue }
            let continuous: [(DisplayFeature, Int?)] = [(.brightness, v.brightness), (.contrast, v.contrast), (.volume, v.volume)]
            for (feature, percent) in continuous {
                guard let percent, let reading = m.readings[feature] else { continue }
                out.append((m.id, feature, VCPScale.raw(percent: Double(percent), maximum: reading.maximum)))
            }
            if let preset = v.colorPreset, m.readings[.colorTemperature] != nil {
                out.append((m.id, .colorTemperature, UInt16(clamping: preset)))
            }
        }
        return out
    }

    /// The current values of connected monitors as profile values (percent for sliders).
    static func capture(_ monitors: [MonitorSnapshot]) -> [String: ProfileValues] {
        var out: [String: ProfileValues] = [:]
        for m in monitors {
            var v = ProfileValues()
            func pct(_ f: DisplayFeature) -> Int? {
                m.readings[f].map { Int(VCPScale.percent(raw: $0.current, maximum: $0.maximum)) }
            }
            v.brightness = pct(.brightness)
            v.contrast = pct(.contrast)
            v.volume = pct(.volume)
            v.colorPreset = m.readings[.colorTemperature].map { Int($0.current) }
            if !v.isEmpty { out[m.id] = v }
        }
        return out
    }
}

/// Live UI state for one monitor (values in percent for sliders).
@MainActor
@Observable
final class MonitorState: Identifiable {
    let id: String
    var snapshot: MonitorSnapshot
    /// Slider positions, 0…100.
    var percent: [DisplayFeature: Double] = [:]
    /// Selected discrete values.
    var discrete: [DisplayFeature: UInt16] = [:]
    /// Software dimming, 0…1, and extra brightness, 0…1 (see `BrightnessComponents`).
    var softDim: Double = 0
    var boost: Double = 0
    /// Resolutions, read from CoreGraphics on the main thread after each scan.
    var modes: ModeCatalog?
    var facts = DisplayFacts()
    /// The ColorSync profile in use and the display's own.
    var colorProfile: URL?
    var factoryProfile: URL?

    init(_ snapshot: MonitorSnapshot) {
        self.id = snapshot.id
        self.snapshot = snapshot
        load(snapshot)
    }

    func load(_ s: MonitorSnapshot) {
        snapshot = s
        for f in DisplayFeature.allCases {
            guard let r = s.readings[f] else { percent[f] = nil; discrete[f] = nil; continue }
            if f.isContinuous { percent[f] = VCPScale.percent(raw: r.current, maximum: r.maximum) } else { discrete[f] = r.current }
        }
    }

    func supports(_ f: DisplayFeature) -> Bool { snapshot.readings[f] != nil }
    var name: String { snapshot.isUnnamed ? String(localized: "Display \(snapshot.number)") : snapshot.name }

    /// The combined slider's components (hardware percent, software dim, boost).
    var components: BrightnessComponents {
        BrightnessComponents(hardware: percent[.brightness] ?? 100, dim: softDim, boost: boost)
    }
}

/// Facts about a display that change with the arrangement, read on the main thread.
struct DisplayFacts: Equatable, Sendable {
    var isMain = false
    /// The display this one shows a copy of.
    var mirrorOf: CGDirectDisplayID?
    /// Global top-left bounds, in points.
    var bounds = CGRect.zero
    /// `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue` (1 without EDR).
    var edrPotential: Double = 1
    var gammaCapacity = 0

    var supportsExtraBrightness: Bool { edrPotential > 1.5 }

    @MainActor
    static func read(_ id: CGDirectDisplayID) -> DisplayFacts {
        let screen = NSScreen.screens.first { $0.displayID == id }
        return DisplayFacts(isMain: CGDisplayIsMain(id) != 0, mirrorOf: DisplayArranger.mirrorSource(of: id),
                            bounds: CGDisplayBounds(id),
                            edrPotential: Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
                            gammaCapacity: Int(CGDisplayGammaTableCapacity(id)))
    }
}
