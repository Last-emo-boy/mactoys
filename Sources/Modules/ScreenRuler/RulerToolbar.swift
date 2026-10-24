import AppKit
import MacToysCore
import Observation
import SwiftUI

@MainActor
@Observable
final class RulerToolbarModel {
    var tool: RulerTool?
    var busy = false
}

/// Design 06 toolbar: Bounds, Spacing, Horizontal, Vertical, then close.
struct RulerToolbar: View {
    let model: RulerToolbarModel
    let select: (RulerTool) -> Void
    let close: () -> Void

    var body: some View {
        GlassPanel(cornerRadius: 14) { buttons }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            ForEach(Array(RulerTool.allCases.enumerated()), id: \.element) { i, tool in
                Button { select(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 30)
                        .foregroundStyle(.white.opacity(model.tool == tool ? 1 : 0.85))
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.tool == tool ? Color.accentColor : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(tool.title) (⌘\(i + 1))")
            }
            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 4)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(5)
    }

    /// Size of the toolbar for its panel.
    static let size = CGSize(width: 4 * 34 + 3 * 4 + 9 + 4 + 30 + 10, height: 40)
}

/// A hosting view that takes the first click even though its panel isn't key.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
