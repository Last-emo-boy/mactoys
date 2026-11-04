import Foundation
import MacToysCore

/// The queue behind paste stack mode: copy several things, then paste them one after another.
public struct PasteStack: Equatable {
    public enum Order: String, Codable, CaseIterable, Sendable, Identifiable {
        /// Paste in the order the items were copied.
        case copyOrder
        /// Paste the most recent copy first.
        case reverse

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .copyOrder: String(localized: "In the order you copied", comment: "Paste stack order")
            case .reverse: String(localized: "Most recent first", comment: "Paste stack order")
            }
        }
    }

    var order: Order
    /// In the order they were added.
    private(set) var items: [ClipItem] = []

    init(order: Order = .copyOrder, items: [ClipItem] = []) {
        self.order = order
        self.items = items
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    /// Upcoming items in paste order; the first is pasted next.
    var queue: [ClipItem] { order == .copyOrder ? items : items.reversed() }

    var next: ClipItem? { queue.first }

    /// Adds a copy. Copying the same content twice in a row adds it once.
    mutating func push(_ item: ClipItem) {
        if let last = items.last, last.hasSameContent(as: item) { return }
        items.append(item)
    }

    mutating func push(contentsOf list: [ClipItem]) {
        for item in list { push(item) }
    }

    /// Removes and returns the item that was just pasted.
    @discardableResult
    mutating func advance() -> ClipItem? {
        guard let next else { return nil }
        remove(next.id)
        return next
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func clear() { items.removeAll() }
}
