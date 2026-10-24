import AppKit
import MacToysCore
import Observation
import SwiftUI

/// The surface annotations are drawn on.
enum Board: String, Sendable {
    case screen, whiteboard, blackboard
}

/// Draw-mode state shared by the overlay and its toolbar.
@MainActor
@Observable
final class DrawState {
    var tool: DrawTool = .pen
    var color: PenColor = .red
    var width: CGFloat = 5
    var board: Board = .screen
    /// Draw mode is on (zoom mode pans instead).
    var drawing = false
    var canUndo = false
    var isRecording = false
    /// Blur needs a frozen screen image.
    var blurAvailable = true
}

/// Toolbar actions the overlay performs.
struct DrawToolbarActions {
    var undo: () -> Void = {}
    var clear: () -> Void = {}
    var toggleBoard: (Board) -> Void = { _ in }
    var record: () -> Void = {}
    var close: () -> Void = {}
}

/// Design 06 ZoomIt toolbar: colors, tools, undo/clear, boards and record.
struct DrawToolbar: View {
    @Bindable var state: DrawState
    let actions: DrawToolbarActions

    private static let tools: [DrawTool] = [.pen, .highlighter, .line, .rectangle, .ellipse, .arrow, .text, .blur, .eraser]

    var body: some View {
        GlassPanel(cornerRadius: 16) {
            HStack(spacing: 6) {
                ForEach(PenColor.allCases) { color in
                    Button { state.color = color } label: {
                        Circle()
                            .fill(color.rgba.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white, lineWidth: state.color == color ? 2.5 : 0))
                            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                            .frame(width: 24, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(color.key.map { "\(color.title) (\(String($0).uppercased()))" } ?? color.title)
                }
                separator
                ForEach(Self.tools) { tool in
                    iconButton(tool.symbol, selected: state.tool == tool, help: tool.title) { state.tool = tool }
                        .disabled(tool == .blur && !state.blurAvailable)
                }
                separator
                iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", action: actions.undo).disabled(!state.canUndo)
                iconButton("trash", help: "Erase all (E)", action: actions.clear)
                iconButton("rectangle.fill", selected: state.board == .whiteboard, help: "Whiteboard (W)") {
                    actions.toggleBoard(.whiteboard)
                }
                iconButton("rectangle.inset.filled", selected: state.board == .blackboard, help: "Blackboard (K)") {
                    actions.toggleBoard(.blackboard)
                }
                separator
                iconButton(state.isRecording ? "stop.circle.fill" : "video", selected: state.isRecording,
                           tint: state.isRecording ? .red : nil, help: "Record the screen (⌃⌥5)", action: actions.record)
                iconButton("xmark", help: "Exit (Esc)", action: actions.close)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 20).padding(.horizontal, 2)
    }

    private func iconButton(_ symbol: String, selected: Bool = false, tint: Color? = nil, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(selected ? 1 : 0.85))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Takes the first click although its panel never becomes key (toolbars over a key overlay).
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Circle cursors sized to the pen.
enum PenCursor {
    static func make(color: RGBA, diameter: CGFloat, highlighter: Bool) -> NSCursor {
        let d = min(max(diameter, 4), 120)
        let side = d + 6
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            color.withAlpha(highlighter ? 0.35 : 0.25).nsColor.setFill()
            circle.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            circle.lineWidth = 2.5
            circle.stroke()
            color.nsColor.setStroke()
            circle.lineWidth = 1.2
            circle.stroke()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.midX - 1, y: rect.midY - 1, width: 2, height: 2)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}
