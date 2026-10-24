import AppKit
import MacToysCore
import SwiftUI

/// Shows the layout editor: an interactive panel on every screen with that display's zones,
/// the layout picker on the chosen display, and the grid/canvas editors.
@MainActor
final class EditorController {
    private unowned let engine: ZoneEngine
    private var panels: [OverlayPanel] = []
    private var model: EditorModel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    init(engine: ZoneEngine) {
        self.engine = engine
    }

    var isOpen: Bool { model != nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen else { return }
        let displays = engine.displays
        guard let first = displays.first else { return }
        let s = engine.settings.value
        let home = (s.editorDisplay == .mouse ? engine.displayUnderPointer() : engine.activeDisplay()) ?? first
        let screens = NSScreen.screens
        let pickerScreen = screens.map(\.axFrame).first { $0.contains(home.workArea.center) }
            ?? screens.first?.axFrame ?? home.frame
        let model = EditorModel(displays: displays, selectedKey: home.key, library: engine.library.value,
                                pickerScreen: pickerScreen, defaultHorizontal: s.defaultHorizontalLayout,
                                defaultVertical: s.defaultVerticalLayout)
        model.onApply = { [weak self] layout, display in
            guard let self else { return }
            self.engine.apply(layout, to: display, announce: false)
        }
        model.onSave = { [weak self] library in
            self.map { $0.engine.library.value = library.normalized() }
        }
        model.onClose = { [weak self] in self?.close() }
        self.model = model

        previousApp = NSWorkspace.shared.frontmostApplication
        let screenFrames = screens.map(\.axFrame)
        for screen in screens {
            let panel = OverlayPanel(frame: screen.frame, interactive: true, acceptsKey: true, level: .statusBar)
            panel.appearance = NSAppearance(named: .darkAqua)   // controls on dark glass
            panel.setContent(EditorScreenView(model: model, screen: screen.axFrame, screens: screenFrames))
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        if let i = screenFrames.firstIndex(of: pickerScreen) { panels[i].present() } else { panels.first?.present() }
        installKeyMonitor()
    }

    /// Keeps the open editor in step with changes made elsewhere (quick keys, settings, CLI).
    func libraryChanged(_ library: LayoutLibrary) {
        guard let model, model.library != library else { return }
        model.library = library
    }

    func close() {
        guard isOpen else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for p in panels { p.orderOut(nil); p.close() }
        panels.removeAll()
        model = nil
        if let previousApp, !previousApp.isTerminated, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let model = self?.model else { return false }
                let editingText = NSApp.keyWindow?.firstResponder is NSTextView
                return model.handleKey(event, textEditing: editingText)
            }
            return handled ? nil : event
        }
    }
}

// MARK: - Screen content

/// One screen of the editor: dimmed backdrop, the zones of its display (selectable), the
/// picker card on the home screen, or the grid/canvas editor while editing.
struct EditorScreenView: View {
    let model: EditorModel
    /// This screen's frame, top-left coordinates.
    let screen: CGRect
    let screens: [CGRect]

    var body: some View {
        let editingHere = model.mode == .editing && model.screen(for: model.selectedDisplay, in: screens) == screen
        ZStack(alignment: .topLeading) {
            Color.black.opacity(editingHere ? 0.42 : 0.2)
                .contentShape(Rectangle())
                .onTapGesture { if let d = displaysHere.first { model.selectDisplay(d.key) } }
            if editingHere, let draft = model.draft {
                let area = local(model.selectedDisplay.workArea)
                if draft.kind == .canvas {
                    CanvasEditorView(model: model, area: area)
                } else {
                    GridEditorView(model: model, area: area)
                }
            } else {
                ForEach(displaysHere) { d in
                    displayPreview(d)
                }
            }
            if model.mode != .editing && screen == model.pickerScreen {
                let work = model.displays.first { $0.frame.intersects(screen) }?.workArea.intersection(screen)
                let home = local(work.flatMap { $0.isNull ? nil : $0 } ?? screen)
                LayoutPickerCard(model: model)
                    .position(x: home.midX, y: home.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var displaysHere: [ZoneDisplay] {
        model.displays.filter { $0.frame.intersects(screen) }
    }

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }

    private func displayPreview(_ d: ZoneDisplay) -> some View {
        let selected = d.key == model.selectedKey
        let zones = model.layout(for: d).zones(in: d.workArea).map(local)
        let area = local(d.workArea)
        return ZStack(alignment: .topLeading) {
            ZoneFieldView(zones: zones, highlighted: [], style: .editorPreview(selected: selected), cornerRadius: 12)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selected && model.displays.count > 1 ? 0.9 : 0), lineWidth: 3)
                .frame(width: area.width - 4, height: area.height - 4)
                .position(x: area.midX, y: area.midY)
                .allowsHitTesting(false)
            if model.displays.count > 1 {
                Label("\(d.number)  \(d.name)", systemImage: "display")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(selected ? Color.accentColor : Color.black.opacity(0.45)))
                    .position(x: area.minX + 110, y: area.minY + 28)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension ZoneStyle {
    init(highlight: Color, inactive: Color, border: Color, number: Color, opacity: Double, showNumbers: Bool) {
        self.init(FancyZonesSettings())
        self.highlight = highlight
        self.inactive = inactive
        self.border = border
        self.number = number
        self.opacity = opacity
        self.showNumbers = showNumbers
    }

    /// Zones as the editor shows them (design 08): translucent blue with light borders.
    static func editorPreview(selected: Bool) -> ZoneStyle {
        ZoneStyle(highlight: .accentColor, inactive: Color(red: 0.2, green: 0.32, blue: 0.86),
                  border: Color(red: 0.5, green: 0.66, blue: 1).opacity(selected ? 1 : 0.6),
                  number: Color(red: 0.86, green: 0.86, blue: 1).opacity(1.2), opacity: selected ? 0.32 : 0.2,
                  showNumbers: true)
    }
}
