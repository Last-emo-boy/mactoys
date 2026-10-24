import CoreGraphics
import Foundation
import MacToysCore

/// A recognized piece of text and where it is (top-left origin, any unit).
public struct TextBox: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public var text: String
        public var rect: CGRect
        public init(_ text: String, _ rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    public var text: String
    public var rect: CGRect
    /// Word boxes, when known (used to split table cells and to pick a word).
    public var words: [Word]

    public init(_ text: String, _ rect: CGRect, words: [Word] = []) {
        self.text = text
        self.rect = rect
        self.words = words
    }
}

/// Turns OCR boxes into text: lines, a single line, or a tab-separated table.
public enum TextLayout {
    /// Groups boxes into visual rows, top to bottom; each row left to right. A box joins a row
    /// when its vertical center falls inside the row's band.
    public static func rows(_ boxes: [TextBox]) -> [[TextBox]] {
        var rows: [(band: ClosedRange<CGFloat>, boxes: [TextBox])] = []
        for box in boxes.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            let mid = box.rect.midY
            if let i = rows.firstIndex(where: { $0.band.contains(mid) }) {
                rows[i].boxes.append(box)
                let r = rows[i].band
                rows[i].band = min(r.lowerBound, box.rect.minY + box.rect.height * 0.25)...max(r.upperBound, box.rect.maxY - box.rect.height * 0.25)
            } else {
                let inset = box.rect.height * 0.25
                rows.append((box.rect.minY + inset...max(box.rect.minY + inset, box.rect.maxY - inset), [box]))
            }
        }
        return rows
            .sorted { $0.band.lowerBound < $1.band.lowerBound }
            .map { $0.boxes.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// One line of text per visual line.
    public static func lines(_ boxes: [TextBox]) -> String {
        rows(boxes).map { row in row.map(\.text).reduce("") { join($0, $1) } }.joined(separator: "\n")
    }

    /// Everything on one line: hyphenated line breaks are rejoined, CJK lines join without spaces.
    public static func singleLine(_ boxes: [TextBox]) -> String {
        rows(boxes).flatMap { $0 }.map(\.text).reduce("") { join($0, $1, rejoinHyphen: true) }
    }

    /// Joins two fragments with a space, or none between CJK characters; with `rejoinHyphen`,
    /// `"infor-" + "mation"` becomes `"information"`.
    public static func join(_ a: String, _ b: String, rejoinHyphen: Bool = false) -> String {
        let a = a.trimmingCharacters(in: .whitespaces)
        let b = b.trimmingCharacters(in: .whitespaces)
        guard let last = a.last else { return b }
        guard let first = b.first else { return a }
        if rejoinHyphen, last == "-", a.count > 1, a.dropLast().last?.isLetter == true, first.isLowercase {
            return String(a.dropLast()) + b
        }
        if isCJK(last) && isCJK(first) { return a + b }
        return a + " " + b
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3040...0x30FF).contains(v)   // Hiragana, Katakana
            || (0x3400...0x4DBF).contains(v)   // CJK Extension A
            || (0x4E00...0x9FFF).contains(v)   // CJK Unified Ideographs
            || (0xF900...0xFAFF).contains(v)   // Compatibility Ideographs
            || (0x3000...0x303F).contains(v)   // CJK punctuation
            || (0xFF00...0xFFEF).contains(v)   // Full-width forms
            || (0x20000...0x2FA1F).contains(v)
    }

    /// Splits a box into cells where the gap between consecutive words is wider than about
    /// one line height (Vision often returns a whole table row as one line).
    public static func cells(of box: TextBox) -> [TextBox] {
        guard box.words.count > 1 else { return [box] }
        let threshold = max(box.rect.height * 1.1, 4)
        var cells: [TextBox] = []
        var current: [TextBox.Word] = []
        func flush() {
            guard let first = current.first else { return }
            let rect = current.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            cells.append(TextBox(current.map(\.text).joined(separator: " "), rect, words: current))
            current = []
        }
        for word in box.words.sorted(by: { $0.rect.minX < $1.rect.minX }) {
            if let prev = current.last, word.rect.minX - prev.rect.maxX > threshold { flush() }
            current.append(word)
        }
        flush()
        return cells
    }

    /// Tab-separated rows and columns. Column bands come from rows with at least two cells, so a
    /// title spanning the table doesn't merge every column.
    public static func table(_ boxes: [TextBox]) -> String {
        let grid = rows(boxes.flatMap(cells(of:)))
        guard !grid.isEmpty else { return "" }
        let multi = grid.filter { $0.count >= 2 }.flatMap { $0 }
        let source = multi.isEmpty ? grid.flatMap { $0 } : multi
        let heights = source.map(\.rect.height).sorted()
        let slack = heights.isEmpty ? 0 : heights[heights.count / 2] * 0.3
        var bands: [ClosedRange<CGFloat>] = []
        for r in source.map({ $0.rect.minX...$0.rect.maxX }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = bands.last, r.lowerBound <= last.upperBound + slack {
                bands[bands.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                bands.append(r)
            }
        }
        guard bands.count > 1 else { return lines(boxes) }

        func column(for rect: CGRect) -> Int {
            var best = 0
            var bestScore = -CGFloat.infinity
            for (i, band) in bands.enumerated() {
                let overlap = min(band.upperBound, rect.maxX) - max(band.lowerBound, rect.minX)
                let score = overlap > 0 ? overlap : -min(abs(band.lowerBound - rect.midX), abs(band.upperBound - rect.midX))
                if score > bestScore { bestScore = score; best = i }
            }
            return best
        }

        return grid.map { row in
            var cells = [String](repeating: "", count: bands.count)
            for box in row {
                let c = column(for: box.rect)
                cells[c] = cells[c].isEmpty ? box.text : join(cells[c], box.text)
            }
            return cells.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// The word under `point`, or the nearest one within `tolerance`.
    public static func word(at point: CGPoint, in boxes: [TextBox], tolerance: CGFloat = 12) -> String? {
        let words = boxes.flatMap { $0.words.isEmpty ? [TextBox.Word($0.text, $0.rect)] : $0.words }
        if let hit = words.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) { return hit.text }
        let nearest = words.min { $0.rect.distance(to: point) < $1.rect.distance(to: point) }
        guard let nearest, nearest.rect.distance(to: point) <= tolerance else { return nil }
        return nearest.text
    }
}
