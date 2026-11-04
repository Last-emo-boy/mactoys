import AppKit
import MacToysCore
import Observation
import SwiftUI

/// Another display a window can be sent to from the palette.
struct DisplayChoice: Identifiable, Equatable {
    /// Index into the controller's display list.
    let index: Int
    let name: String
    var id: Int { index }
}

/// What the palette shows and what the pointer is doing in it.
@MainActor
@Observable
final class PaletteModel {
    var appName = ""
    var appIcon: NSImage?
    var windowTitle = ""
    var grid = GridSpec(columns: 6, rows: 4)
    var gridSize = CGSize(width: 272, height: 170)
    /// Where the window is now, as a share of the work area.
    var current: UnitRect?
    var dragStart: GridCell?
    var dragEnd: GridCell?
    var hoverCell: GridCell?
    var controls: [WindowControl] = []
    var hoveredControl: UUID?
    var displays: [DisplayChoice] = []
    var hoveredDisplay: Int?
    /// Size of the frame being previewed, for the caption.
    var targetSize: CGSize?

    @ObservationIgnored var onGridChange: ((UnitRect?) -> Void)?
    @ObservationIgnored var onGridCommit: ((UnitRect) -> Void)?
    @ObservationIgnored var onHoverControl: ((WindowControl?) -> Void)?
    @ObservationIgnored var onRun: ((WindowControl) -> Void)?
    @ObservationIgnored var onHoverDisplay: ((Int?) -> Void)?
    @ObservationIgnored var onDisplay: ((Int) -> Void)?

    var isDragging: Bool { dragStart != nil }

    var selection: UnitRect? {
        guard let a = dragStart, let b = dragEnd else { return nil }
        return grid.unitRect(from: a, to: b)
    }

    func resetPointer() {
        dragStart = nil
        dragEnd = nil
        hoverCell = nil
        hoveredControl = nil
        hoveredDisplay = nil
        targetSize = nil
    }
}

/// Sizes of the palette's parts.
enum PaletteLayout {
    static let width: CGFloat = 300
    static let padding: CGFloat = 14
    static var gridWidth: CGFloat { width - padding * 2 }
    static let tile = CGSize(width: 40, height: 30)
    static let tileSpacing: CGFloat = 6.4
    /// Room around the glass inside the panel for its shadow.
    static let shadowInset: CGFloat = 24

    /// The grid drawn with the display's proportions: full width on landscape displays, narrower
    /// and taller on portrait ones.
    static func gridSize(for visible: CGRect) -> CGSize {
        guard visible.width > 0, visible.height > 0 else { return CGSize(width: gridWidth, height: gridWidth * 0.625) }
        let aspect = visible.height / visible.width
        let maxHeight: CGFloat = 300
        let h = min(gridWidth * aspect, maxHeight)
        return CGSize(width: (h / aspect).rounded(), height: h.rounded())
    }
}

/// The glass palette under a window's green button: the resize grid, the controls and the other displays.
struct PaletteView: View {
    let model: PaletteModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        PaletteSurface(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 11) {
                header
                PaletteGrid(model: model)
                    .frame(maxWidth: .infinity)
                caption
                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                controls
                if !model.displays.isEmpty { displays }
            }
            .padding(PaletteLayout.padding)
            .frame(width: PaletteLayout.width)
            .foregroundStyle(.white)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.96, anchor: .topLeading)
        .opacity(appeared || reduceMotion ? 1 : 0)
        .onAppear { withAnimation(.snappy(duration: 0.18)) { appeared = true } }
        .padding(PaletteLayout.shadowInset)
    }

    private var header: some View {
        HStack(spacing: 7) {
            if let icon = model.appIcon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            }
            Text(verbatim: model.appName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            if !model.windowTitle.isEmpty {
                Text(verbatim: model.windowTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var caption: some View {
        captionText
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: captionKey)
    }

    /// Changes whenever the caption's content does (drives its cross-fade).
    private var captionKey: String {
        "\(model.dragStart.map { "\($0)" } ?? "")\(model.dragEnd.map { "\($0)" } ?? "")\(model.hoveredControl?.uuidString ?? "")\(model.hoveredDisplay ?? -1)"
    }

    private var captionText: Text {
        if let a = model.dragStart, let b = model.dragEnd {
            let span = model.grid.span(from: a, to: b)
            if let size = model.targetSize {
                return Text("\(span.columns) × \(span.rows) cells · \(Int(size.width)) × \(Int(size.height))",
                            comment: "Window Controls grid: cells selected (columns × rows), then the window size in points")
            }
            return Text("\(span.columns) × \(span.rows) cells", comment: "Window Controls grid: cells selected (columns × rows)")
        }
        if let id = model.hoveredControl, let c = model.controls.first(where: { $0.id == id }) {
            if let size = model.targetSize {
                return Text("\(c.displayName) · \(Int(size.width)) × \(Int(size.height))",
                            comment: "Window Controls palette: a control's name, then the window size it gives in points")
            }
            return Text(verbatim: c.displayName)
        }
        if let i = model.hoveredDisplay, let d = model.displays.first(where: { $0.index == i }) {
            return Text("Move to \(d.name)", comment: "Window Controls palette: move the window to the display with this name")
        }
        return Text("Drag across the grid, or pick a size", comment: "Window Controls palette hint")
    }

    private var controls: some View {
        let columns = Array(repeating: GridItem(.fixed(PaletteLayout.tile.width), spacing: PaletteLayout.tileSpacing),
                            count: 6)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(model.controls) { control in
                let on = model.hoveredControl == control.id
                ControlGlyph(control, style: .dark, highlighted: on)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(width: PaletteLayout.tile.width, height: PaletteLayout.tile.height)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(on ? 0.16 : 0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(on ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.06), lineWidth: 1))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            model.hoveredControl = control.id
                            model.onHoverControl?(control)
                        } else if model.hoveredControl == control.id {
                            model.hoveredControl = nil
                            model.onHoverControl?(nil)
                        }
                    }
                    .onTapGesture { model.onRun?(control) }
                    .help(Text(verbatim: control.displayName))
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: control.displayName))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.onRun?(control) }
            }
        }
    }

    private var displays: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(model.displays) { d in
                let on = model.hoveredDisplay == d.index
                HStack(spacing: 7) {
                    Image(systemName: "arrow.right.to.line.compact")
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "display")
                        .font(.system(size: 11, weight: .medium))
                    Text("Move to \(d.name)", comment: "Window Controls palette: move the window to the display with this name")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(on ? 1 : 0.82))
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06)))
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        model.hoveredDisplay = d.index
                        model.onHoverDisplay?(d.index)
                    } else if model.hoveredDisplay == d.index {
                        model.hoveredDisplay = nil
                        model.onHoverDisplay?(nil)
                    }
                }
                .onTapGesture { model.onDisplay?(d.index) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { model.onDisplay?(d.index) }
            }
        }
    }
}

/// The resize grid: a miniature of the display split into cells. Drag across cells to choose
/// where the window goes; the window's current place shows as a dashed outline.
struct PaletteGrid: View {
    let model: PaletteModel
    var interactive = true

    var body: some View {
        let size = model.gridSize
        let grid = model.grid
        let selection = model.selection
        Canvas { ctx, canvasSize in
            let screen = Path(roundedRect: CGRect(origin: .zero, size: canvasSize), cornerRadius: 9, style: .continuous)
            ctx.fill(screen, with: .color(.white.opacity(0.05)))
            let spacing: CGFloat = 3
            let cw = (canvasSize.width - spacing) / CGFloat(grid.columns)
            let ch = (canvasSize.height - spacing) / CGFloat(grid.rows)
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    let rect = CGRect(x: spacing + CGFloat(column) * cw, y: spacing + CGFloat(row) * ch,
                                      width: cw - spacing, height: ch - spacing)
                    let cell = GridCell(column: column, row: row)
                    let selected = selection.map { Self.contains($0, cell, grid) } ?? false
                    let hovered = selection == nil && model.hoverCell == cell
                    let color: Color = selected ? .accentColor.opacity(0.88) : .white.opacity(hovered ? 0.24 : 0.09)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 3.5, style: .continuous), with: .color(color))
                }
            }
            if let current = model.current, selection == nil {
                let r = CGRect(x: current.x * canvasSize.width, y: current.y * canvasSize.height,
                               width: current.width * canvasSize.width, height: current.height * canvasSize.height)
                    .intersection(CGRect(origin: .zero, size: canvasSize)).insetBy(dx: 1, dy: 1)
                if !r.isNull, r.width > 4, r.height > 4 {
                    ctx.stroke(Path(roundedRect: r, cornerRadius: 5, style: .continuous),
                               with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size), including: interactive ? .all : .none)
        .onContinuousHover { phase in
            guard interactive else { return }
            switch phase {
            case .active(let p): model.hoverCell = model.grid.cell(at: p, in: size)
            case .ended: model.hoverCell = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Resize grid", comment: "Accessibility: the grid in the Window Controls palette"))
        .accessibilityHint(Text("Drag across cells to place the window over them",
                                comment: "Accessibility: how to use the Window Controls grid"))
    }

    private static func contains(_ u: UnitRect, _ cell: GridCell, _ grid: GridSpec) -> Bool {
        let x = (Double(cell.column) + 0.5) / Double(grid.columns), y = (Double(cell.row) + 0.5) / Double(grid.rows)
        return x > u.x && x < u.maxX && y > u.y && y < u.maxY
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = model.grid.cell(at: value.startLocation, in: size)
                let end = model.grid.cell(at: value.location, in: size)
                guard model.dragStart != start || model.dragEnd != end else { return }
                model.dragStart = start
                model.dragEnd = end
                model.onGridChange?(model.selection)
            }
            .onEnded { _ in
                let selection = model.selection
                model.dragStart = nil
                model.dragEnd = nil
                if let selection { model.onGridCommit?(selection) } else { model.onGridChange?(nil) }
            }
    }
}

/// The dark glass every Window Controls overlay sits on; a solid surface with Reduce Transparency,
/// a brighter edge with Increase Contrast.
struct PaletteSurface<Content: View>: View {
    var cornerRadius: CGFloat = 18
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if reduceTransparency {
                content
                    .background(Color(red: 0.12, green: 0.12, blue: 0.14))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.16), lineWidth: 1))
                    .environment(\.colorScheme, .dark)
            } else {
                GlassPanel(cornerRadius: cornerRadius) { content }
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(contrast == .increased ? 0.45 : 0), lineWidth: 1))
            }
        }
    }
}
