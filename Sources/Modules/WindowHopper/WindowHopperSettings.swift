import CoreGraphics
import MacToysCore

/// AppKit also brings in QuickDraw's `WindowRef`; inside this module the name means MacToys' AX window.
typealias WindowRef = MacToysCore.WindowRef

/// Persisted options of Window Hopper (`windowhopper.json`).
public struct WindowHopperSettings: Codable, Equatable, Sendable {
    /// Cycles forward; its modifiers (without ⇧) are the ones held while hopping.
    public var next: Shortcut? = Shortcut(0x32, [.option])            // kVK_ANSI_Grave
    public var previous: Shortcut? = Shortcut(0x32, [.option, .shift])
    public var includeMinimized = true
    /// Live window pictures (needs Screen Recording); otherwise app icon cards.
    public var showPreviews = true

    public init() {}
}

/// Pure rules of the switcher: selection stepping, which modifiers must stay held, ordering, layout.
enum HopperLogic {
    static let cardSize = CGSize(width: 200, height: 126)
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 16
    static let headerHeight: CGFloat = 22
    static let titleHeight: CGFloat = 24

    /// Moves `index` by `delta`, wrapping around `count`.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// The first selection: the window after the current one, or the last one when going back.
    static func initialSelection(forward: Bool, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return forward ? 1 : count - 1
    }

    /// Modifiers that keep the switcher open: the opening shortcut's, without ⇧ (which only reverses).
    static func holdModifiers(for shortcut: Shortcut) -> Modifiers {
        shortcut.modifiers.subtracting(.shift)
    }

    /// Whether the held modifiers were released.
    static func isReleased(hold: Modifiers, now: Modifiers) -> Bool {
        !hold.isEmpty && !now.isSuperset(of: hold)
    }

    /// Orders windows front to back by the window server's stacking (`zOrder`, front first);
    /// windows not in it (minimized) go last, in their original order.
    static func ordered<T>(_ items: [T], id: (T) -> CGWindowID, zOrder: [CGWindowID]) -> [T] {
        var rank: [CGWindowID: Int] = [:]
        for (i, wid) in zOrder.enumerated() where rank[wid] == nil { rank[wid] = i }
        return items.enumerated().sorted { a, b in
            let ra = rank[id(a.element)] ?? Int.max, rb = rank[id(b.element)] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// Cards per row for `count` windows on a screen `maxWidth` wide.
    static func columns(count: Int, maxWidth: CGFloat) -> Int {
        let usable = maxWidth * 0.9 - padding * 2 + spacing
        let fit = max(1, Int(usable / (cardSize.width + spacing)))
        return max(1, min(count, fit))
    }

    /// Indexes of the cards in each row.
    static func rows(count: Int, columns: Int) -> [[Int]] {
        guard count > 0, columns > 0 else { return [] }
        return stride(from: 0, to: count, by: columns).map { Array($0..<min($0 + columns, count)) }
    }

    /// Size of the switcher panel for `count` cards.
    static func panelSize(count: Int, maxWidth: CGFloat) -> CGSize {
        let cols = columns(count: count, maxWidth: maxWidth)
        let rowCount = max(1, rows(count: count, columns: cols).count)
        let width = CGFloat(cols) * cardSize.width + CGFloat(cols - 1) * spacing + padding * 2
        let rowHeight = cardSize.height + titleHeight
        let height = padding * 2 + headerHeight + spacing + CGFloat(rowCount) * rowHeight + CGFloat(rowCount - 1) * spacing
        return CGSize(width: width, height: height)
    }
}
