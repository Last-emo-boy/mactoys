import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Annotate tools, with their single-letter keys.
enum MarkupTool: String, CaseIterable, Identifiable, Sendable {
    case select, arrow, line, rectangle, ellipse, text, highlighter, pencil, counter, blur, pixelate, spotlight, crop
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "character.textbox"
        case .highlighter: "highlighter"
        case .pencil: "pencil.tip"
        case .counter: "1.circle"
        case .blur: "drop.halffull"
        case .pixelate: "squareshape.split.3x3"
        case .spotlight: "flashlight.on.fill"
        case .crop: "crop"
        }
    }

    /// The letter that picks the tool (shown uppercase).
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        case .highlighter: "h"
        case .pencil: "p"
        case .counter: "n"
        case .blur: "b"
        case .pixelate: "x"
        case .spotlight: "s"
        case .crop: "c"
        }
    }

    var title: String {
        switch self {
        case .select: String(localized: "Select and move", comment: "Annotate tool")
        case .arrow: String(localized: "Arrow", comment: "Annotate tool")
        case .line: String(localized: "Line", comment: "Annotate tool")
        case .rectangle: String(localized: "Rectangle", comment: "Annotate tool")
        case .ellipse: String(localized: "Ellipse", comment: "Annotate tool")
        case .text: String(localized: "Text", comment: "Annotate tool")
        case .highlighter: String(localized: "Highlighter", comment: "Annotate tool")
        case .pencil: String(localized: "Pencil", comment: "Annotate tool")
        case .counter: String(localized: "Counter", comment: "Annotate tool: numbered step badges 1, 2, 3")
        case .blur: String(localized: "Blur", comment: "Annotate tool: blur a region")
        case .pixelate: String(localized: "Pixelate", comment: "Annotate tool: pixelate a region")
        case .spotlight: String(localized: "Spotlight", comment: "Annotate tool: dim everything but a region")
        case .crop: String(localized: "Crop", comment: "Annotate tool")
        }
    }

    /// Tooltip: the name and its key.
    var help: String {
        String(localized: "\(title) (\(String(key).uppercased()))", comment: "Annotate tool tooltip: tool name, then the letter key that picks it")
    }

    static func forKey(_ c: Character) -> MarkupTool? { allCases.first { $0.key == c } }

    /// Tools that draw something new on a drag.
    var draws: Bool { self != .select && self != .crop }
}

/// What the annotate window's buttons do (the module supplies them).
struct AnnotateActions {
    var copy: (AnnotateModel) -> Void = { _ in }
    var save: (AnnotateModel) -> Void = { _ in }
    var saveAs: (AnnotateModel) -> Void = { _ in }
    var share: (AnnotateModel, NSView?) -> Void = { _, _ in }
    var pin: (AnnotateModel) -> Void = { _ in }
    var copyText: (AnnotateModel) -> Void = { _ in }
    var dragFile: (AnnotateModel) -> URL? = { _ in nil }
    var makeDefaultBackground: (BeautifyStyle) -> Void = { _ in }
}

/// The annotate window's state: the document being edited, the current tool and palette, undo.
@MainActor
@Observable
final class AnnotateModel {
    let item: CaptureItem
    var document: MarkupDocument {
        didSet { if document != oldValue { item.document = document } }
    }
    var tool: MarkupTool = .arrow
    var color: RGBA
    var size: MarkupSize
    var curvedArrows: Bool
    var filledShapes = false
    var textStyle: TextStyle = .plain
    var ovalSpotlight = false
    var selection: MarkupItem.ID?
    /// The crop being drawn with the crop tool (image points).
    var cropDraft: CGRect?
    var editingText: MarkupItem.ID?
    var showsBeautify: Bool
    var canUndo = false
    var canRedo = false
    /// Short feedback ("Copied") shown over the canvas.
    var toast: String?
    /// The background used when beautify is turned on here.
    let defaultBeautify: BeautifyStyle

    @ObservationIgnored var actions = AnnotateActions()
    /// Called after every committed change (the module refreshes cards, pins and history).
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var undoStack = UndoStack<MarkupDocument>()
    @ObservationIgnored private var gestureStart: MarkupDocument?
    @ObservationIgnored private var lastBeautifyEdit = Date.distantPast
    @ObservationIgnored private var toolBeforeCrop: MarkupTool = .arrow

    init(item: CaptureItem, settings: ScreenshotSettings) {
        self.item = item
        document = item.document
        color = settings.annotationColor
        size = settings.annotationSize
        curvedArrows = settings.curvedArrows
        defaultBeautify = settings.beautify
        showsBeautify = item.document.beautify != nil
    }

    var selectedItem: MarkupItem? { selection.flatMap { id in document.items.first { $0.id == id } } }

    // MARK: Changes

    /// Starts a drag that changes the document; `endGesture` records one undo step for all of it.
    func beginGesture() { gestureStart = document }

    func endGesture() {
        guard let before = gestureStart else { return }
        gestureStart = nil
        if before != document { record(before) }
    }

    /// Drops an unfinished gesture's changes (a stray click with a drawing tool).
    func cancelGesture() {
        guard let before = gestureStart else { return }
        gestureStart = nil
        document = before
    }

    /// A one-step change.
    func apply(_ change: (inout MarkupDocument) -> Void) {
        let before = document
        change(&document)
        if before != document { record(before) }
    }

    private func record(_ before: MarkupDocument) {
        undoStack.record(before)
        syncUndo()
        onChange?()
    }

    private func syncUndo() {
        canUndo = undoStack.canUndo
        canRedo = undoStack.canRedo
    }

    func undo() {
        guard editingText == nil, let previous = undoStack.undo(from: document) else { return }
        restore(previous)
    }

    func redo() {
        guard editingText == nil, let next = undoStack.redo(from: document) else { return }
        restore(next)
    }

    private func restore(_ doc: MarkupDocument) {
        document = doc
        if let s = selection, doc.index(of: s) == nil { selection = nil }
        if tool == .crop { cropDraft = doc.crop ?? doc.imageBounds }
        showsBeautify = doc.beautify != nil
        syncUndo()
        onChange?()
    }

    // MARK: Items

    func update(_ id: MarkupItem.ID, _ change: (inout MarkupItem) -> Void) {
        guard let i = document.index(of: id) else { return }
        change(&document.items[i])
    }

    func deleteSelection() {
        guard let id = selection else { return }
        apply { $0.items.removeAll { $0.id == id } }
        selection = nil
    }

    func duplicateSelection() {
        guard var copy = selectedItem else { return }
        copy = copy.moved(by: CGVector(dx: 12, dy: 12))
        copy.id = UUID()
        if case .counter(let c, _) = copy.shape { copy.shape = .counter(center: c, number: document.nextCounter) }
        apply { $0.items.append(copy) }
        selection = copy.id
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let id = selection else { return }
        apply { doc in
            guard let i = doc.index(of: id) else { return }
            doc.items[i] = doc.items[i].moved(by: CGVector(dx: dx, dy: dy))
        }
    }

    // MARK: Palette

    func setColor(_ c: RGBA) {
        color = c
        guard let id = selection else { return }
        apply { doc in if let i = doc.index(of: id) { doc.items[i].color = c } }
    }

    func setSize(_ s: MarkupSize) {
        size = s
        guard let id = selection else { return }
        apply { doc in if let i = doc.index(of: id) { doc.items[i].size = s } }
    }

    func setFilled(_ filled: Bool) {
        filledShapes = filled
        restyleSelection { shape in
            switch shape {
            case .rectangle(let r, _): .rectangle(r, filled: filled)
            case .ellipse(let r, _): .ellipse(r, filled: filled)
            default: nil
            }
        }
    }

    func setCurved(_ curved: Bool) {
        curvedArrows = curved
        restyleSelection { shape in
            guard case .arrow(let a, let b, _) = shape else { return nil }
            return .arrow(from: a, to: b, bend: curved ? MarkupGeometry.defaultBend(from: a, to: b) : 0)
        }
    }

    func setTextStyle(_ style: TextStyle) {
        textStyle = style
        restyleSelection { shape in
            guard case .text(var t) = shape else { return nil }
            t.style = style
            return .text(t)
        }
    }

    func setOvalSpotlight(_ oval: Bool) {
        ovalSpotlight = oval
        restyleSelection { shape in
            guard case .spotlight(let r, _) = shape else { return nil }
            return .spotlight(r, oval: oval)
        }
    }

    private func restyleSelection(_ transform: (MarkupItem.Shape) -> MarkupItem.Shape?) {
        guard let item = selectedItem, let shape = transform(item.shape) else { return }
        apply { doc in if let i = doc.index(of: item.id) { doc.items[i].shape = shape } }
    }

    /// Picks up the palette of a newly selected item, so the controls show what it uses.
    func adoptStyle(of item: MarkupItem) {
        color = item.color
        size = item.size
        switch item.shape {
        case .rectangle(_, let f), .ellipse(_, let f): filledShapes = f
        case .arrow(_, _, let bend): curvedArrows = abs(bend) > 0.5
        case .text(let t): textStyle = t.style
        case .spotlight(_, let o): ovalSpotlight = o
        default: break
        }
    }

    // MARK: Tools

    func selectTool(_ t: MarkupTool) {
        guard t != tool else { return }
        if tool == .crop { applyCrop(switchingTool: false) }
        if t == .crop {
            toolBeforeCrop = tool == .crop ? .arrow : tool
            cropDraft = document.crop ?? document.imageBounds
            selection = nil
        }
        if t.draws && t != .text { selection = nil }
        tool = t
    }

    func applyCrop(switchingTool: Bool = true) {
        guard let draft = cropDraft else { return }
        let r = draft.intersection(document.imageBounds).integral
        let full = r.width >= document.imageSize.width - 0.5 && r.height >= document.imageSize.height - 0.5
        apply { $0.crop = full || r.isNull ? nil : r }
        cropDraft = nil
        if switchingTool { tool = toolBeforeCrop }
    }

    func resetCrop() {
        cropDraft = document.imageBounds
        apply { $0.crop = nil }
    }

    // MARK: Beautify

    func toggleBeautify() {
        apply { $0.beautify = $0.beautify == nil ? defaultBeautify : nil }
        showsBeautify = document.beautify != nil
    }

    /// Changes the background; quick successive edits (a slider drag) undo as one step.
    func editBeautify(_ change: (inout BeautifyStyle) -> Void) {
        var style = document.beautify ?? defaultBeautify
        change(&style)
        guard style != document.beautify else { return }
        let now = Date()
        if now.timeIntervalSince(lastBeautifyEdit) > 0.8 {
            undoStack.record(document)
            syncUndo()
        }
        lastBeautifyEdit = now
        document.beautify = style
        onChange?()
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}

/// Maps between the annotate canvas view and the capture's image points. Pure, for tests.
struct CanvasGeometry {
    let viewSize: CGSize
    let document: MarkupDocument
    /// The crop tool shows the whole capture, without the background frame.
    let showsWholeImage: Bool
    var margin: CGFloat = 36

    /// The visible part of the image, in image points.
    var visibleImageRect: CGRect { showsWholeImage ? document.imageBounds : document.contentRect }

    /// The frame layout, when the background is shown.
    var layout: BeautifyLayout? {
        guard !showsWholeImage, let style = document.beautify else { return nil }
        return BeautifyLayout.make(content: visibleImageRect.size, style: style, scale: document.scale)
    }

    /// What is drawn, in canvas points: the frame or the visible image.
    var canvasSize: CGSize { layout?.canvas ?? visibleImageRect.size }

    /// View points per canvas point: fit inside the margins, never enlarged past 100 %.
    var zoom: CGFloat {
        let c = canvasSize
        guard c.width > 0, c.height > 0 else { return 1 }
        return max(0.05, min(1, (viewSize.width - margin * 2) / c.width, (viewSize.height - margin * 2) / c.height))
    }

    /// The canvas in view coordinates (y down), centered.
    var canvasRect: CGRect {
        let z = zoom, c = canvasSize
        let w = c.width * z, h = c.height * z
        return CGRect(x: ((viewSize.width - w) / 2).rounded(), y: ((viewSize.height - h) / 2).rounded(), width: w, height: h)
    }

    /// Where the image's visible part sits in canvas points.
    var contentOrigin: CGPoint { layout?.content.origin ?? .zero }

    /// Image point → view point.
    func view(_ p: CGPoint) -> CGPoint {
        let r = canvasRect, z = zoom, v = visibleImageRect, o = contentOrigin
        return CGPoint(x: r.minX + (o.x + p.x - v.minX) * z, y: r.minY + (o.y + p.y - v.minY) * z)
    }

    /// View point → image point.
    func image(_ p: CGPoint) -> CGPoint {
        let r = canvasRect, z = zoom, v = visibleImageRect, o = contentOrigin
        return CGPoint(x: (p.x - r.minX) / z - o.x + v.minX, y: (p.y - r.minY) / z - o.y + v.minY)
    }

    func view(_ r: CGRect) -> CGRect {
        let a = view(r.origin)
        return CGRect(x: a.x, y: a.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// The visible image area in view coordinates.
    var contentRect: CGRect { view(visibleImageRect) }
}
