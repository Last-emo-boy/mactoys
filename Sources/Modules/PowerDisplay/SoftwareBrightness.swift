import CoreGraphics
import Foundation

/// What one brightness slider controls, as plain numbers.
struct BrightnessComponents: Equatable, Sendable {
    /// Hardware brightness, 0…100 (100 for displays without a hardware control).
    var hardware: Double = 100
    /// Software dimming below the hardware minimum, 0 (none) … 1 (as dark as allowed).
    var dim: Double = 0
    /// Extra brightness from EDR headroom, 0 (none) … 1 (the configured maximum).
    var boost: Double = 0
}

/// The combined brightness slider: software dimming on the left, the hardware range in the
/// middle, extra brightness on the right. Dragging past the hardware minimum keeps dimming in
/// software; past the hardware maximum it boosts into the EDR headroom.
struct BrightnessTrack: Equatable, Sendable {
    var hasHardware: Bool
    var dimming: Bool
    var boost: Bool

    static let dimWeight = 0.25
    static let hardwareWeight = 1.0
    static let boostWeight = 0.25

    private var total: Double {
        (dimming ? Self.dimWeight : 0) + (hasHardware ? Self.hardwareWeight : 0) + (boost ? Self.boostWeight : 0)
    }

    /// Fractions of the track; they add up to 1 (all 0 when there is nothing to control).
    var dimShare: Double { total > 0 && dimming ? Self.dimWeight / total : 0 }
    var hardwareShare: Double { total > 0 && hasHardware ? Self.hardwareWeight / total : 0 }
    var boostShare: Double { total > 0 && boost ? Self.boostWeight / total : 0 }

    /// Where the hardware range starts and ends (the zero and 100 % marks).
    var hardwareStart: Double { dimShare }
    var hardwareEnd: Double { dimShare + hardwareShare }

    /// Whether the slider does anything.
    var isEmpty: Bool { total == 0 }

    func components(at position: Double) -> BrightnessComponents {
        let p = max(0, min(1, position))
        var c = BrightnessComponents(hardware: hasHardware ? 0 : 100)
        if dimShare > 0 && p < hardwareStart {
            c.dim = (hardwareStart - p) / dimShare
        } else if hardwareShare > 0 && p <= hardwareEnd {
            c.hardware = (p - hardwareStart) / hardwareShare * 100
        } else if boostShare > 0 {
            c.hardware = 100
            c.boost = (p - hardwareEnd) / boostShare
        } else if !hasHardware && dimShare > 0 {
            c.dim = 0
        }
        c.hardware = (c.hardware * 10).rounded() / 10
        c.dim = max(0, min(1, c.dim))
        c.boost = max(0, min(1, c.boost))
        return c
    }

    func position(_ c: BrightnessComponents) -> Double {
        if dimShare > 0 && c.dim > 0 { return hardwareStart - min(1, c.dim) * dimShare }
        if boostShare > 0 && c.boost > 0 { return hardwareEnd + min(1, c.boost) * boostShare }
        if hasHardware { return hardwareStart + max(0, min(100, c.hardware)) / 100 * hardwareShare }
        return hardwareEnd
    }
}

/// One number for linked and synced brightness: −100…0 software dimming, 0…100 hardware,
/// 100…200 extra brightness. Displays follow each other on this scale, so a linked group keeps
/// going darker in software once every hardware control is at its minimum.
enum BrightnessLevel {
    static let range: ClosedRange<Double> = -100...200

    static func level(_ c: BrightnessComponents) -> Double {
        if c.dim > 0 { return -c.dim * 100 }
        if c.boost > 0 { return 100 + c.boost * 100 }
        return c.hardware
    }

    static func components(_ level: Double, dimming: Bool, boost: Bool) -> BrightnessComponents {
        let l = max(dimming ? -100 : 0, min(boost ? 200 : 100, level))
        if l < 0 { return BrightnessComponents(hardware: 0, dim: -l / 100) }
        if l > 100 { return BrightnessComponents(hardware: 100, boost: (l - 100) / 100) }
        return BrightnessComponents(hardware: l)
    }
}

/// Factors applied to what a display shows.
enum SoftwareFactor {
    /// The gamma (or overlay) multiplier for a dim amount: 1 … 1 − `maxDim`.
    static func dim(_ dim: Double, maxDim: Double) -> Double {
        let limit = max(0, min(0.98, maxDim))
        return 1 - max(0, min(1, dim)) * limit
    }

    /// The EDR multiplier for a boost amount: 1 … `maxBoost`.
    static func boost(_ boost: Double, maxBoost: Double) -> Double {
        1 + max(0, min(1, boost)) * max(0, maxBoost - 1)
    }

    /// The multiplier the overlay renders. macOS only grants headroom while EDR content is on
    /// screen, so the first frames ask for the full target (capped by what the panel can ever
    /// do); once headroom is granted, the factor stays within it so highlights don't clip.
    static func boostToRender(target: Double, potential: Double, current: Double) -> Double {
        var k = min(max(1, target), max(1, potential))
        if current > 1.01 { k = min(k, current) }
        return k
    }
}

/// How software dimming darkens a display.
enum DimMethod: String, Codable, CaseIterable, Sendable {
    /// The display's color table where it has one, else an overlay.
    case automatic
    /// Color table (gamma): dims everything including the cursor; not on every display.
    case gamma
    /// A dark, click-through window over the screen: works everywhere, the cursor stays bright.
    case overlay

    func usesGamma(gammaSupported: Bool) -> Bool {
        switch self {
        case .automatic, .gamma: gammaSupported
        case .overlay: false
        }
    }

    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "Software dimming method: color table where possible, else overlay")
        case .gamma: String(localized: "Color table", comment: "Software dimming method: the display's gamma table")
        case .overlay: String(localized: "Overlay", comment: "Software dimming method: a dark window over the screen")
        }
    }
}

/// A display's transfer table (`CGGetDisplayTransferByTable`).
struct GammaTable: Equatable, Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]

    var count: Int { min(red.count, green.count, blue.count) }

    static func identity(count: Int) -> GammaTable {
        let n = max(2, count)
        let ramp = (0..<n).map { Float($0) / Float(n - 1) }
        return GammaTable(red: ramp, green: ramp, blue: ramp)
    }

    /// Every output value multiplied by `factor` (0…1), so the curve keeps its shape.
    func scaled(by factor: Double) -> GammaTable {
        let f = Float(max(0, min(1, factor)))
        func scale(_ a: [Float]) -> [Float] { a.map { max(0, min(1, $0 * f)) } }
        return GammaTable(red: scale(red), green: scale(green), blue: scale(blue))
    }
}

/// Which displays have a dimmed color table, and the tables to put back. Pure: the module
/// performs the actions it returns.
struct GammaBookkeeping: Equatable {
    enum Action: Equatable {
        case apply(CGDirectDisplayID, GammaTable)
        /// No table could be read: dim with a linear formula instead.
        case formula(CGDirectDisplayID, Double)
        case restore(CGDirectDisplayID, GammaTable)
        /// Hand every display back to ColorSync (`CGDisplayRestoreColorSyncSettings`).
        case restoreSystem
    }

    /// The table each dimmed display had before; nil when it couldn't be read.
    private(set) var originals: [CGDirectDisplayID: GammaTable?] = [:]
    private(set) var factors: [CGDirectDisplayID: Double] = [:]

    var isActive: Bool { !factors.isEmpty }
    var dimmedDisplays: Set<CGDirectDisplayID> { Set(factors.keys) }

    /// Sets a display's dim factor (1 = undimmed). `read` is asked for the original table only when
    /// dimming starts, so it never captures an already-dimmed table.
    mutating func set(_ factor: Double, for id: CGDirectDisplayID, read: () -> GammaTable?) -> [Action] {
        let f = max(0, min(1, factor))
        if f >= 0.999 {
            guard factors.removeValue(forKey: id) != nil else { return [] }
            let original = originals.removeValue(forKey: id) ?? nil
            if let original { return [.restore(id, original)] }
            // Only a formula was applied: ColorSync restores all displays, so re-apply the others.
            return [.restoreSystem] + reapplyAll()
        }
        if originals[id] == nil { originals[id] = .some(read()) }
        factors[id] = f
        return [action(for: id, factor: f)]
    }

    /// Restores every display (module stop, quit).
    mutating func restoreAll() -> [Action] {
        guard isActive else { return [] }
        factors.removeAll()
        originals.removeAll()
        return [.restoreSystem]
    }

    /// ColorSync changed the tables (profile switched, display reconfigured, wake): put the
    /// system tables back, re-read the originals and dim again.
    mutating func tablesChanged(read: (CGDirectDisplayID) -> GammaTable?) -> [Action] {
        guard isActive else { return [] }
        var actions: [Action] = [.restoreSystem]
        for id in factors.keys.sorted() {
            originals[id] = .some(read(id))
        }
        actions += reapplyAll()
        return actions
    }

    /// Displays that went offline are forgotten (their tables are gone with them).
    mutating func retain(online: Set<CGDirectDisplayID>) {
        for id in factors.keys where !online.contains(id) {
            factors.removeValue(forKey: id)
            originals.removeValue(forKey: id)
        }
    }

    private func reapplyAll() -> [Action] {
        factors.keys.sorted().compactMap { id in factors[id].map { action(for: id, factor: $0) } }
    }

    private func action(for id: CGDirectDisplayID, factor: Double) -> Action {
        if let original = originals[id] ?? nil, original.count > 1 { return .apply(id, original.scaled(by: factor)) }
        return .formula(id, factor)
    }
}
