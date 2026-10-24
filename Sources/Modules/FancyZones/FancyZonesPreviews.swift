import MacToysCore
import SwiftUI

/// Offscreen previews: the editor with its picker, the grid and canvas editors, and zones while dragging.
@MainActor
enum FancyZonesPreviews {
    static var scenes: [PreviewScene] {
        [
            PreviewScene("editor", size: CGSize(width: 1600, height: 1000)) { AnyView(editor(mode: .picker)) },
            PreviewScene("dragging", size: CGSize(width: 1440, height: 900)) { AnyView(dragging) },
            PreviewScene("grid-editor", size: CGSize(width: 1600, height: 1000)) { AnyView(editor(mode: .editing)) },
            PreviewScene("canvas-editor", size: CGSize(width: 1600, height: 1000)) { AnyView(editor(mode: .editing, canvas: true)) },
        ]
    }

    static let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    static var sampleDisplays: [ZoneDisplay] {
        [ZoneDisplay(key: "1552-41009-0", name: "Built-in Retina", number: 1, frame: screen,
                     workArea: CGRect(x: 0, y: 0, width: 1600, height: 1000), isBuiltIn: true),
         ZoneDisplay(key: "7789-23308-1234", name: "LG UltraFine", number: 2,
                     frame: CGRect(x: 1600, y: -200, width: 2560, height: 1440),
                     workArea: CGRect(x: 1600, y: -175, width: 2560, height: 1415), isBuiltIn: false)]
    }

    static var sampleLibrary: LayoutLibrary {
        var lib = LayoutLibrary()
        var coding = ZoneLayout.newGrid(name: "Coding")
        coding.grid = GridLayout(rows: [0.5, 0.5], columns: [0.55, 0.45], cells: [[0, 1], [0, 2]])
        var ultrawide = ZoneLayout.newGrid(name: "Ultrawide 3+1")
        ultrawide.grid = GridLayout(rows: [1], columns: [0.22, 0.22, 0.22, 0.34], cells: [[0, 1, 2, 3]])
        var writing = ZoneLayout.newCanvas(name: "Writing", reference: CGSize(width: 1600, height: 1000))
        writing.canvas?.zones = [CanvasZone(x: 360, y: 60, width: 880, height: 880),
                                 CanvasZone(x: 1260, y: 60, width: 320, height: 420)]
        lib.add(coding)
        lib.add(ultrawide)
        lib.add(writing)
        lib.setQuickKey(5, for: coding.id)
        lib.assignments["1552-41009-0"] = ZoneLayout.Kind.priorityGrid.rawValue
        lib.assignments["7789-23308-1234"] = ultrawide.id
        return lib
    }

    static func editor(mode: EditorModel.Mode, canvas: Bool = false) -> some View {
        let model = EditorModel(displays: sampleDisplays, selectedKey: "1552-41009-0", library: sampleLibrary,
                                pickerScreen: screen, defaultHorizontal: "priorityGrid", defaultVertical: "rows")
        if mode == .editing {
            if canvas, let writing = model.library.custom.first(where: { $0.kind == .canvas }) {
                model.edit(writing)
                model.canvasSelection = 0
            } else if let coding = model.library.custom.first {
                model.edit(coding)
                model.split(zone: 0, vertical: false, at: 0.62)
                model.gridSelection = [2, 3]
                model.mergePoint = CGPoint(x: 1240, y: 500)
            }
        }
        return EditorScreenView(model: model, screen: screen, screens: [screen])
    }

    static var dragging: some View {
        var s = FancyZonesSettings()
        s.opacity = 45
        let area = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let zones = ZoneGeometry.zones(for: .template(.priorityGrid), in: area, spacing: 12)
        return ZStack(alignment: .topLeading) {
            fakeWindow.frame(width: 520, height: 340).position(x: 760, y: 430)
            ZoneFieldView(zones: zones, highlighted: [2], style: ZoneStyle(s))
            LayoutNameBadge(name: "Priority Grid", textColor: .white, background: s.layoutNameBackground.color,
                            textSize: 36, padding: 12)
                .position(x: 720, y: 80)
        }
    }

    private static var fakeWindow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 12, height: 12) }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(white: 0.93))
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.86)).frame(width: CGFloat(380 - i * 37), height: 8)
                }
                Spacer()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }
}
