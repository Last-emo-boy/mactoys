import AppKit
import Carbon.HIToolbox
import MacToysCore
import Observation

/// State of the layout editor: the picker (choose a layout per display, tune its parameters)
/// and the grid/canvas editors for custom layouts. Side effects go through the `on…` closures,
/// so previews can run it with sample data.
@MainActor
@Observable
final class EditorModel {
    enum Mode: Equatable { case picker, creating, editing }

    var displays: [ZoneDisplay]
    var selectedKey: String
    var library: LayoutLibrary
    /// Top-left frame of the screen that shows the picker card.
    let pickerScreen: CGRect
    let defaultHorizontal: String
    let defaultVertical: String

    var mode: Mode = .picker
    var draft: ZoneLayout?
    var draftIsNew = false
    var newName = ""
    var newIsCanvas = false
    var pendingDelete: String?
    var shiftDown = false
    /// Grid editor: zones selected for merging, and where the merge button shows (work-area coordinates).
    var gridSelection: Set<Int> = []
    var mergePoint: CGPoint?
    /// Canvas editor: the selected zone.
    var canvasSelection: Int?

    @ObservationIgnored var onApply: (ZoneLayout, ZoneDisplay) -> Void = { _, _ in }
    @ObservationIgnored var onSave: (LayoutLibrary) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}

    init(displays: [ZoneDisplay], selectedKey: String, library: LayoutLibrary, pickerScreen: CGRect,
         defaultHorizontal: String, defaultVertical: String) {
        self.displays = displays
        self.selectedKey = selectedKey
        self.library = library
        self.pickerScreen = pickerScreen
        self.defaultHorizontal = defaultHorizontal
        self.defaultVertical = defaultVertical
    }

    var selectedDisplay: ZoneDisplay {
        displays.first { $0.key == selectedKey } ?? displays[0]
    }

    func layout(for display: ZoneDisplay) -> ZoneLayout {
        library.layout(forDisplay: display.key, vertical: display.isVertical,
                       defaultHorizontal: defaultHorizontal, defaultVertical: defaultVertical)
    }

    var selectedLayout: ZoneLayout { layout(for: selectedDisplay) }

    /// The screen frame (top-left) a display is edited on.
    func screen(for display: ZoneDisplay, in screens: [CGRect]) -> CGRect {
        if display.key == ZoneDisplay.allDisplaysKey { return pickerScreen }
        return screens.first { $0.contains(display.workArea.center) } ?? pickerScreen
    }

    // MARK: Picker

    func selectDisplay(_ key: String) {
        guard mode == .picker || mode == .creating, displays.contains(where: { $0.key == key }) else { return }
        selectedKey = key
        pendingDelete = nil
    }

    /// Applies a layout to the selected display.
    func choose(_ layout: ZoneLayout) {
        pendingDelete = nil
        library.assignments[selectedKey] = layout.id
        onApply(layout, selectedDisplay)
    }

    /// Edits the selected layout's parameters (zone count, spacing, highlight distance).
    func updateSelected(_ mutate: (inout ZoneLayout) -> Void) {
        var l = selectedLayout
        mutate(&l)
        guard l != selectedLayout else { return }
        library.update(l)
        onSave(library)
        onApply(l, selectedDisplay)
    }

    func setQuickKey(_ key: Int?, for id: String) {
        library.setQuickKey(key, for: id)
        onSave(library)
    }

    func duplicate(_ layout: ZoneLayout) {
        let copy = layout.duplicated(name: library.uniqueName("\(layout.name) copy"),
                                     reference: selectedDisplay.workArea.size)
        library.add(copy)
        onSave(library)
        choose(copy)
    }

    /// First call arms the delete; the second (within the same selection) deletes.
    func delete(_ layout: ZoneLayout) {
        guard !layout.isTemplate else { return }
        guard pendingDelete == layout.id else { pendingDelete = layout.id; return }
        pendingDelete = nil
        library.delete(id: layout.id)
        onSave(library)
        onApply(selectedLayout, selectedDisplay)
    }

    func beginCreate() {
        newName = library.uniqueName("Custom layout")
        mode = .creating
    }

    func create() {
        guard mode == .creating else { return }
        let name = newName.trimmingCharacters(in: .whitespaces).isEmpty ? library.uniqueName("Custom layout") : newName
        let size = selectedDisplay.workArea.size
        draft = newIsCanvas ? .newCanvas(name: name, reference: size) : .newGrid(name: name)
        draftIsNew = true
        startEditing()
    }

    /// Opens the grid or canvas editor for a custom layout.
    func edit(_ layout: ZoneLayout) {
        if layout.isTemplate {
            // Templates keep their parametric shape; edit a custom copy instead.
            duplicate(layout)
            if let copy = library.custom.last { edit(copy) }
            return
        }
        draft = layout
        draftIsNew = false
        // Canvas zones are edited 1:1 in this display's coordinates.
        if var canvas = layout.canvas {
            let size = selectedDisplay.workArea.size
            let rect = CGRect(origin: .zero, size: size)
            canvas.zones = canvas.zones(in: rect).map(CanvasZone.init)
            canvas.referenceWidth = size.width
            canvas.referenceHeight = size.height
            draft?.canvas = canvas
        }
        startEditing()
    }

    private func startEditing() {
        gridSelection = []
        mergePoint = nil
        canvasSelection = nil
        pendingDelete = nil
        mode = .editing
    }

    func saveDraft() {
        guard var d = draft else { return }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = library.uniqueName("Custom layout") }
        d.grid = d.grid?.normalized()
        d.zoneCount = d.count
        if draftIsNew { library.add(d) } else { library.update(d) }
        onSave(library)
        draft = nil
        mode = .picker
        choose(d)
    }

    func cancel() {
        switch mode {
        case .creating: mode = .picker
        case .editing:
            if !gridSelection.isEmpty { gridSelection = []; mergePoint = nil; return }
            draft = nil
            mode = .picker
        case .picker:
            onClose()
        }
    }

    // MARK: Grid editing

    func split(zone: Int, vertical: Bool, at position: Double) {
        guard let g = draft?.grid else { return }
        draft?.grid = g.splitting(zone: zone, vertical: vertical, at: position)
        gridSelection = []
        mergePoint = nil
    }

    func mergeSelection() {
        guard let g = draft?.grid, gridSelection.count > 1 else { return }
        draft?.grid = g.merging(gridSelection)
        gridSelection = []
        mergePoint = nil
    }

    func moveSplitter(_ s: GridLayout.Splitter, to position: Double) {
        guard let g = draft?.grid else { return }
        draft?.grid = g.movingSplitter(vertical: s.vertical, index: s.index, to: position)
    }

    // MARK: Canvas editing

    func addCanvasZone(in area: CGSize) {
        guard draft?.canvas != nil else { return }
        let n = CGFloat(draft?.canvas?.zones.count ?? 0)
        let w = area.width * 0.3, h = area.height * 0.3
        let offset = (n.truncatingRemainder(dividingBy: 8)) * 28
        let zone = CanvasZone(x: area.width * 0.35 - w / 2 + offset, y: area.height * 0.35 - h / 2 + offset, width: w, height: h)
        draft?.canvas?.zones.append(zone)
        canvasSelection = (draft?.canvas?.zones.count ?? 1) - 1
    }

    func deleteCanvasZone(_ i: Int) {
        guard let zones = draft?.canvas?.zones, zones.indices.contains(i) else { return }
        draft?.canvas?.zones.remove(at: i)
        canvasSelection = nil
    }

    func setCanvasZone(_ i: Int, _ rect: CGRect, in area: CGSize) {
        guard let zones = draft?.canvas?.zones, zones.indices.contains(i) else { return }
        draft?.canvas?.zones[i] = CanvasZone(CanvasEditing.clamp(rect, to: area))
    }

    // MARK: Keys

    /// Editor keyboard: esc, return/⌫ (merge, delete zone), arrows (move/resize canvas zones),
    /// tab (next canvas zone), ⌘S (save). Returns true when handled.
    func handleKey(_ e: NSEvent, textEditing: Bool) -> Bool {
        if e.type == .flagsChanged {
            shiftDown = e.modifierFlags.contains(.shift)
            return false
        }
        let code = Int(e.keyCode)
        if code == kVK_Escape { cancel(); return true }
        if mode == .editing, code == kVK_ANSI_S, e.modifierFlags.contains(.command) { saveDraft(); return true }
        guard !textEditing else { return false }
        switch mode {
        case .picker, .creating:
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter, mode == .creating { create(); return true }
            if code == kVK_Return, mode == .picker { onClose(); return true }
            return false
        case .editing:
            if draft?.kind == .customGrid {
                if [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Delete, kVK_ForwardDelete].contains(code), gridSelection.count > 1 {
                    mergeSelection()
                    return true
                }
                return false
            }
            return handleCanvasKey(code, flags: e.modifierFlags)
        }
    }

    private func handleCanvasKey(_ code: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard let zones = draft?.canvas?.zones, let ref = draft?.canvas else { return false }
        if code == kVK_Tab, !zones.isEmpty {
            canvasSelection = ((canvasSelection ?? -1) + (flags.contains(.shift) ? zones.count - 1 : 1)) % zones.count
            return true
        }
        guard let i = canvasSelection, zones.indices.contains(i) else { return false }
        if code == kVK_Delete || code == kVK_ForwardDelete { deleteCanvasZone(i); return true }
        let area = CGSize(width: ref.referenceWidth, height: ref.referenceHeight)
        let step: CGFloat = flags.contains(.option) ? 1 : 10
        var r = zones[i].rect
        let resize = flags.contains(.shift)
        switch code {
        case kVK_LeftArrow: if resize { r.size.width -= step } else { r.origin.x -= step }
        case kVK_RightArrow: if resize { r.size.width += step } else { r.origin.x += step }
        case kVK_UpArrow: if resize { r.size.height -= step } else { r.origin.y -= step }
        case kVK_DownArrow: if resize { r.size.height += step } else { r.origin.y += step }
        default: return false
        }
        setCanvasZone(i, r, in: area)
        return true
    }
}

/// Pure canvas-editor math (moving and resizing zones inside the work area).
enum CanvasEditing {
    static let minimumSize: CGFloat = 40

    /// Keeps a zone inside `area` and at least `minimumSize` big.
    static func clamp(_ r: CGRect, to area: CGSize) -> CGRect {
        let w = min(max(r.width, minimumSize), area.width)
        let h = min(max(r.height, minimumSize), area.height)
        let x = min(max(r.minX, 0), area.width - w)
        let y = min(max(r.minY, 0), area.height - h)
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// Resizes `start` by dragging the handle at `edges` by `delta`.
    static func resize(_ start: CGRect, edges: ResizeEdges, delta: CGSize, in area: CGSize) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        if edges.contains(.left) { minX = min(max(0, start.minX + delta.width), maxX - minimumSize) }
        if edges.contains(.right) { maxX = max(min(area.width, start.maxX + delta.width), minX + minimumSize) }
        if edges.contains(.top) { minY = min(max(0, start.minY + delta.height), maxY - minimumSize) }
        if edges.contains(.bottom) { maxY = max(min(area.height, start.maxY + delta.height), minY + minimumSize) }
        return clamp(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: area)
    }
}

/// Edges grabbed when resizing (a corner is two edges).
struct ResizeEdges: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1)
    static let right = ResizeEdges(rawValue: 2)
    static let top = ResizeEdges(rawValue: 4)
    static let bottom = ResizeEdges(rawValue: 8)

    static let handles: [ResizeEdges] = [[.top, .left], .top, [.top, .right], .right,
                                         [.bottom, .right], .bottom, [.bottom, .left], .left]
}
