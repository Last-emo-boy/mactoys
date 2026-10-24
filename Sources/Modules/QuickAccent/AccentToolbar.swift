import AppKit
import MacToysCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AccentToolbarModel {
    var characters: [String] = []
    var selection: Int?
    var showInfo = true

    static let capacity = 13
    static let cellWidth: CGFloat = 40

    var visible: Range<Int> { AccentLogic.visibleRange(count: characters.count, selected: selection, capacity: Self.capacity) }

    /// Panel size for the current content.
    var size: CGSize {
        let cells = CGFloat(visible.count) * (Self.cellWidth + 2)
        let arrows: CGFloat = characters.count > Self.capacity ? 28 : 0
        return CGSize(width: cells + arrows + 16 + (showInfo ? 250 : 0), height: 56)
    }
}

/// The accent picker (design 05, Quick Accent).
struct AccentToolbarView: View {
    let model: AccentToolbarModel

    var body: some View {
        GlassPanel(cornerRadius: 14) {
            HStack(spacing: 2) {
                let range = model.visible
                if model.characters.count > AccentToolbarModel.capacity {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(range.lowerBound > 0 ? 0.6 : 0.15)).frame(width: 14)
                }
                ForEach(Array(range), id: \.self) { i in
                    let selected = i == model.selection
                    Text(AccentLogic.display(model.characters[i]))
                        .font(.system(size: 21))
                        .foregroundStyle(.white)
                        .frame(width: AccentToolbarModel.cellWidth, height: 40)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.accentColor : .clear))
                }
                if model.characters.count > AccentToolbarModel.capacity {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(range.upperBound < model.characters.count ? 0.6 : 0.15)).frame(width: 14)
                }
                if model.showInfo { info.padding(.leading, 10) }
            }
            .padding(.horizontal, 8)
            .frame(height: 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var info: some View {
        if let i = model.selection, model.characters.indices.contains(i) {
            let c = model.characters[i]
            let unicode = AccentLogic.unicodeInfo(c)
            VStack(alignment: .leading, spacing: 2) {
                Text(AccentLogic.display(c)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text("\(unicode.code) · \(unicode.name)")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            .frame(width: 236, alignment: .leading)
        } else {
            Text("Space or ←/→ to choose")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                .frame(width: 236, alignment: .leading)
        }
    }
}

/// Places the toolbar near the caret or at the chosen screen position.
@MainActor
final class AccentToolbarPresenter {
    let model = AccentToolbarModel()
    private var panel: OverlayPanel?

    func show(_ characters: [String], selection: Int?, position: QuickAccentSettings.Position, showInfo: Bool) {
        model.characters = characters
        model.selection = selection
        model.showInfo = showInfo
        let size = model.size
        let caret = position == .caret ? CaretLocator.caretRect() : nil
        let screen = caret.flatMap { ScreenGeometry.screen(forAX: $0) }
            ?? WindowRef.focused()?.frame.flatMap { ScreenGeometry.screen(forAX: $0) }
            ?? NSScreen.underMouse ?? NSScreen.main
        guard let screen else { return }
        let frame = Self.frame(size: size, caret: caret, position: position, visible: screen.visibleFrame)
        let p = panel ?? OverlayPanel(frame: frame, interactive: false, acceptsKey: false, level: .popUpMenu)
        p.setFrame(frame, display: false)
        if panel == nil { p.setContent(AccentToolbarView(model: model)) }
        panel = p
        p.orderFrontRegardless()
    }

    func select(_ index: Int?) {
        model.selection = index
        guard let panel, panel.isVisible else { return }
        let size = model.size
        if abs(size.width - panel.frame.width) > 0.5 {
            var f = panel.frame
            f.origin.x += (f.width - size.width) / 2
            f.size = size
            panel.setFrame(f, display: true)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func dispose() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Cocoa frame: centered above the caret (below it at the top edge), or at a fixed position.
    static func frame(size: CGSize, caret: CGRect?, position: QuickAccentSettings.Position, visible vf: CGRect) -> CGRect {
        let margin: CGFloat = 24
        var origin: CGPoint
        if let caret {
            let c = ScreenGeometry.toCocoa(caret)
            origin = CGPoint(x: c.midX - size.width / 2, y: c.maxY + 8)
            if origin.y + size.height > vf.maxY { origin.y = c.minY - 8 - size.height }
        } else {
            switch position {
            case .caret, .topCenter: origin = CGPoint(x: vf.midX - size.width / 2, y: vf.maxY - margin - size.height)
            case .bottomCenter: origin = CGPoint(x: vf.midX - size.width / 2, y: vf.minY + margin)
            case .left: origin = CGPoint(x: vf.minX + margin, y: vf.midY - size.height / 2)
            case .right: origin = CGPoint(x: vf.maxX - margin - size.width, y: vf.midY - size.height / 2)
            case .topLeft: origin = CGPoint(x: vf.minX + margin, y: vf.maxY - margin - size.height)
            case .topRight: origin = CGPoint(x: vf.maxX - margin - size.width, y: vf.maxY - margin - size.height)
            case .bottomLeft: origin = CGPoint(x: vf.minX + margin, y: vf.minY + margin)
            case .bottomRight: origin = CGPoint(x: vf.maxX - margin - size.width, y: vf.minY + margin)
            case .center: origin = CGPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
            }
        }
        origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
        origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        return CGRect(origin: origin, size: size)
    }
}
