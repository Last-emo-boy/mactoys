import MacToysCore
import SwiftUI

/// The editor's display canvas (`design/exports/07-tool-windows.png`, Workspaces): the saved
/// displays with every window as a colored rectangle you can drag, and resize by its corner.
struct WorkspaceCanvas: View {
    @Binding var workspace: Workspace
    @Binding var selectedApp: UUID?
    @State private var drag: Drag?

    private struct Drag: Equatable {
        let id: UUID
        var translation: CGSize
        let resize: Bool
    }

    /// Smallest window an edit can make, in global points.
    private static let minimumSize = CGSize(width: 160, height: 100)

    var body: some View {
        GeometryReader { geo in
            let map = CanvasMapping(displays: workspace.displays.map(\.frame), canvas: geo.size, padding: 16)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11))
                ForEach(workspace.displays) { display in
                    let r = map.toCanvas(display.frame)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
                        .overlay(alignment: .bottomTrailing) {
                            Text("Display \(workspace.displayNumber(of: display.id))",
                                 comment: "A display of the workspace; %lld is its number")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(6)
                        }
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                }
                // Back to front, so the frontmost saved window is drawn on top.
                ForEach(Array(workspace.apps.enumerated()).reversed(), id: \.element.id) { _, app in
                    tile(app, map: map)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window layout")
    }

    private func tile(_ app: WorkspaceApp, map: CanvasMapping) -> some View {
        var r = map.toCanvas(app.frame)
        if let d = drag, d.id == app.id {
            if d.resize {
                r.size.width = max(24, r.width + d.translation.width)
                r.size.height = max(18, r.height + d.translation.height)
            } else {
                r.origin.x += d.translation.width
                r.origin.y += d.translation.height
            }
        }
        let selected = selectedApp == app.id
        let label = app.state == .minimized
            ? String(localized: "\(app.name) (minimized)", comment: "Window tile in the workspace layout; %@ is the app name")
            : app.name
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: AppIcons.color(path: app.appPath)))
            .overlay(alignment: .topLeading) {
                Text(verbatim: label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.white : Color.white.opacity(0.18), lineWidth: selected ? 2 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.7))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(.white))
                        .padding(4)
                        .highPriorityGesture(dragGesture(app.id, map: map, resize: true))
                        .help("Drag to resize")
                }
            }
            .opacity(app.state == .hidden ? 0.55 : 1)
            .frame(width: r.width, height: r.height)
            .contentShape(Rectangle())
            .offset(x: r.minX, y: r.minY)
            .gesture(dragGesture(app.id, map: map, resize: false))
            .onTapGesture { selectedApp = app.id }
            .accessibilityElement()
            .accessibilityLabel(Text("\(label), \(WorkspaceText.placement(of: app, in: workspace))",
                                     comment: "Accessibility: a window tile; the app name, then where the window goes"))
    }

    private func dragGesture(_ id: UUID, map: CanvasMapping, resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if drag == nil { selectedApp = id }
                drag = Drag(id: id, translation: value.translation, resize: resize)
            }
            .onEnded { value in
                drag = nil
                apply(id, delta: map.toGlobal(value.translation), resize: resize)
            }
    }

    private func apply(_ id: UUID, delta: CGSize, resize: Bool) {
        guard let i = workspace.apps.firstIndex(where: { $0.id == id }) else { return }
        var f = workspace.apps[i].frame
        if resize {
            f.size.width = max(Self.minimumSize.width, f.width + delta.width)
            f.size.height = max(Self.minimumSize.height, f.height + delta.height)
        } else {
            f.origin.x += delta.width
            f.origin.y += delta.height
        }
        let bounds = workspace.displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if !bounds.isNull { f = DisplayMapper.clamp(f, into: bounds) }
        workspace.apps[i].frame = f
        if let display = DisplayMapper.display(for: f, among: workspace.displays) {
            workspace.apps[i].displayID = display.id
        }
        if workspace.apps[i].state == .fill || workspace.apps[i].state == .fullScreen {
            // Dragging a window means the user wants it at that spot.
            workspace.apps[i].state = .saved
        }
    }
}
