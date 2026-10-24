import MacToysCore
import SwiftUI

// MARK: - Toolbar

/// Glass bar at the top of the grid and canvas editors: name, hints, actions.
struct EditorToolbar: View {
    @Bindable var model: EditorModel
    let hint: String
    var addZone: (() -> Void)?

    var body: some View {
        GlassPanel(cornerRadius: 16) {
            HStack(spacing: 12) {
                Image(systemName: model.draft?.kind == .canvas ? "rectangle.on.rectangle" : "rectangle.split.3x3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                TextField("Layout name", text: Binding(get: { model.draft?.name ?? "" },
                                                        set: { model.draft?.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Text(hint)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(1)
                    .fixedSize()
                if let addZone {
                    Button(action: addZone) { Label("Add zone", systemImage: "plus") }
                }
                Divider().frame(height: 18)
                Button("Cancel") { model.draft = nil; model.mode = .picker }
                Button("Save") { model.saveDraft() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.3))
        }
        .fixedSize()
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
    }
}

/// A zone tile in the editors.
private struct EditorZoneTile: View {
    let number: Int
    let size: CGSize
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        shape
            .fill(selected ? Color.accentColor.opacity(0.42) : Color(red: 0.2, green: 0.32, blue: 0.86).opacity(0.26))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color(red: 0.55, green: 0.7, blue: 1).opacity(0.75),
                                        lineWidth: selected ? 2.5 : 1.5))
            .overlay {
                VStack(spacing: 4) {
                    Text("\(number)")
                        .font(.system(size: max(16, min(96, min(size.width, size.height) * 0.28)), weight: .bold, design: .rounded))
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .opacity(size.height > 90 ? 0.7 : 0)
                }
                .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 1))
            }
    }
}

// MARK: - Grid editor

/// Custom grid editing: click a zone to split it (⇧ rotates the line), drag a divider to
/// resize, drag across zones and choose Merge to join them.
struct GridEditorView: View {
    @Bindable var model: EditorModel
    /// The display's work area, in this screen's local coordinates.
    let area: CGRect
    @State private var hover: CGPoint?
    @State private var selecting = false

    private static let space = "grid-editor"

    var body: some View {
        let grid = model.draft?.grid ?? .columns(1)
        let size = area.size
        let zones = grid.zones(in: CGRect(origin: .zero, size: size), spacing: CGFloat(model.draft?.effectiveSpacing ?? 0))
        let units = grid.unitRects
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                    if case .active(let p) = phase { hover = p } else { hover = nil }
                }
                .gesture(clickOrSelect(grid: grid, size: size))
            ForEach(zones.indices, id: \.self) { i in
                EditorZoneTile(number: i + 1, size: zones[i].size, selected: model.gridSelection.contains(i))
                    .frame(width: zones[i].width, height: zones[i].height)
                    .position(x: zones[i].midX, y: zones[i].midY)
                    .allowsHitTesting(false)
            }
            if let p = hover, !selecting, model.mergePoint == nil, let z = zone(at: p, units: units, size: size) {
                splitPreview(zone: zones[z], unit: units[z], at: p, size: size)
            }
            ForEach(Array(grid.splitters.enumerated()), id: \.offset) { _, s in
                splitterHandle(s, size: size)
            }
            if let p = model.mergePoint, model.gridSelection.count > 1 {
                mergeBar.position(x: min(max(p.x, 120), size.width - 120), y: min(max(p.y + 34, 40), size.height - 30))
            }
            EditorToolbar(model: model, hint: "Click to split · ⇧ rotates · drag dividers · drag across zones to merge")
                .position(x: size.width / 2, y: 46)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named(Self.space))
        .position(x: area.midX, y: area.midY)
    }

    private func zone(at p: CGPoint, units: [CGRect], size: CGSize) -> Int? {
        guard size.width > 0, size.height > 0 else { return nil }
        let u = CGPoint(x: p.x / size.width, y: p.y / size.height)
        return units.firstIndex { $0.containsInclusive(u) }
    }

    /// Splits along the zone's longer side unless ⇧ is held.
    private func splitsVertically(_ unit: CGRect, size: CGSize) -> Bool {
        (unit.width * size.width >= unit.height * size.height) != model.shiftDown
    }

    private func clickOrSelect(grid: GridLayout, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if !selecting && hypot(v.translation.width, v.translation.height) > 6 {
                    selecting = true
                    model.mergePoint = nil
                }
                guard selecting else { return }
                let units = grid.unitRects
                let picked = [zone(at: v.startLocation, units: units, size: size), zone(at: v.location, units: units, size: size)]
                model.gridSelection = grid.mergeClosure(Set(picked.compactMap { $0 }))
            }
            .onEnded { v in
                defer { selecting = false }
                let units = grid.unitRects
                if selecting {
                    if model.gridSelection.count > 1 { model.mergePoint = v.location } else { model.gridSelection = [] }
                    return
                }
                if model.mergePoint != nil || !model.gridSelection.isEmpty {
                    model.gridSelection = []
                    model.mergePoint = nil
                    return
                }
                guard let z = zone(at: v.location, units: units, size: size) else { return }
                let vertical = splitsVertically(units[z], size: size)
                model.split(zone: z, vertical: vertical, at: vertical ? v.location.x / size.width : v.location.y / size.height)
            }
    }

    private func splitPreview(zone: CGRect, unit: CGRect, at p: CGPoint, size: CGSize) -> some View {
        let vertical = splitsVertically(unit, size: size)
        return Path { path in
            if vertical {
                path.move(to: CGPoint(x: p.x, y: zone.minY + 8))
                path.addLine(to: CGPoint(x: p.x, y: zone.maxY - 8))
            } else {
                path.move(to: CGPoint(x: zone.minX + 8, y: p.y))
                path.addLine(to: CGPoint(x: zone.maxX - 8, y: p.y))
            }
        }
        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        .allowsHitTesting(false)
    }

    private func splitterHandle(_ s: GridLayout.Splitter, size: CGSize) -> some View {
        let start = CGFloat(s.range.lowerBound), end = CGFloat(s.range.upperBound)
        let length = (end - start) * (s.vertical ? size.height : size.width)
        let center = s.vertical
            ? CGPoint(x: CGFloat(s.position) * size.width, y: (start + end) / 2 * size.height)
            : CGPoint(x: (start + end) / 2 * size.width, y: CGFloat(s.position) * size.height)
        return ZStack {
            Capsule().fill(Color.white.opacity(0.55))
                .frame(width: s.vertical ? 4 : max(0, length - 24), height: s.vertical ? max(0, length - 24) : 4)
            Capsule().fill(Color.white)
                .frame(width: s.vertical ? 8 : 34, height: s.vertical ? 34 : 8)
                .shadow(color: .black.opacity(0.35), radius: 3)
        }
        .frame(width: s.vertical ? 18 : length, height: s.vertical ? length : 18)
        .contentShape(Rectangle())
        .pointerStyle(s.vertical ? .columnResize : .rowResize)
        .position(center)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space)).onChanged { v in
            let p = s.vertical ? v.location.x / size.width : v.location.y / size.height
            model.moveSplitter(s, to: Double(p))
        })
        .accessibilityLabel(s.vertical ? "Vertical divider" : "Horizontal divider")
    }

    private var mergeBar: some View {
        GlassPanel(cornerRadius: 12) {
            HStack(spacing: 10) {
                Button { model.mergeSelection() } label: { Label("Merge zones", systemImage: "rectangle.compress.vertical") }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { model.gridSelection = []; model.mergePoint = nil }
            }
            .padding(8)
        }
        .fixedSize()
    }
}

// MARK: - Canvas editor

/// Custom canvas editing: drag zones to move them, drag the handles to resize, × to delete.
/// Arrow keys move the selected zone (⌥ by 1 pt), ⇧ arrows resize it, ⇥ selects the next one.
struct CanvasEditorView: View {
    @Bindable var model: EditorModel
    let area: CGRect
    @State private var dragStart: CGRect?

    private static let space = "canvas-editor"

    var body: some View {
        let size = area.size
        let zones = model.draft?.canvas?.zones ?? []
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { model.canvasSelection = nil }
            ForEach(zones.indices, id: \.self) { i in
                zoneView(i, zones[i].rect, size: size)
            }
            EditorToolbar(model: model, hint: "Drag to move · handles resize · arrows nudge",
                          addZone: { model.addCanvasZone(in: size) })
                .position(x: size.width / 2, y: 46)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named(Self.space))
        .position(x: area.midX, y: area.midY)
    }

    private func zoneView(_ i: Int, _ r: CGRect, size: CGSize) -> some View {
        let selected = model.canvasSelection == i
        return EditorZoneTile(number: i + 1, size: r.size, selected: selected)
            .frame(width: r.width, height: r.height)
            .overlay(alignment: .topTrailing) {
                Button { model.deleteCanvasZone(i) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Delete zone")
            }
            .overlay {
                if selected {
                    ForEach(ResizeEdges.handles, id: \.rawValue) { edges in
                        handle(i, edges, r, size: size)
                    }
                }
            }
            .pointerStyle(.grabIdle)
            .position(x: r.midX, y: r.midY)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { v in
                    if dragStart == nil { dragStart = r; model.canvasSelection = i }
                    guard let start = dragStart else { return }
                    model.setCanvasZone(i, start.offsetBy(dx: v.translation.width, dy: v.translation.height), in: size)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture { model.canvasSelection = i }
    }

    private func handle(_ i: Int, _ edges: ResizeEdges, _ r: CGRect, size: CGSize) -> some View {
        let x: CGFloat = edges.contains(.left) ? 0 : edges.contains(.right) ? r.width : r.width / 2
        let y: CGFloat = edges.contains(.top) ? 0 : edges.contains(.bottom) ? r.height : r.height / 2
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .padding(6)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: Self.position(edges)))
            .position(x: x, y: y)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { v in
                    if dragStart == nil { dragStart = r }
                    guard let start = dragStart else { return }
                    model.setCanvasZone(i, CanvasEditing.resize(start, edges: edges, delta: v.translation, in: size), in: size)
                }
                .onEnded { _ in dragStart = nil })
    }

    private static func position(_ e: ResizeEdges) -> FrameResizePosition {
        switch e {
        case [.top, .left]: .topLeading
        case [.top, .right]: .topTrailing
        case [.bottom, .left]: .bottomLeading
        case [.bottom, .right]: .bottomTrailing
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        default: .trailing
        }
    }
}
