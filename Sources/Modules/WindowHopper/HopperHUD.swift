import AppKit
import MacToysCore
import Observation
import SwiftUI

/// What the switcher shows: the app, its window cards, the selection and loaded thumbnails.
@MainActor
@Observable
final class HopperModel {
    struct Card: Identifiable, Equatable {
        let id: CGWindowID
        let title: String
        let isMinimized: Bool
    }

    var appName = ""
    var appIcon: NSImage?
    var cards: [Card] = []
    var selection = 0
    var thumbnails: [CGWindowID: NSImage] = [:]
    var showThumbnails = true
    var columns = 3
    @ObservationIgnored var onChoose: ((Int) -> Void)?
    @ObservationIgnored var onHover: ((Int) -> Void)?
}

/// The glass switcher panel (`design/exports/05-menubar-flyouts-huds.png`, Window Hopper).
struct HopperHUD: View {
    let model: HopperModel

    var body: some View {
        GlassPanel(cornerRadius: 20) {
            VStack(alignment: .leading, spacing: HopperLogic.spacing) {
                HStack(spacing: 8) {
                    if let icon = model.appIcon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text("\(model.appName) · \(model.cards.count) windows",
                         comment: "Window Hopper header; %@ is the app name, %lld the number of its windows")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(height: HopperLogic.headerHeight)
                VStack(alignment: .leading, spacing: HopperLogic.spacing) {
                    ForEach(HopperLogic.rows(count: model.cards.count, columns: model.columns), id: \.self) { row in
                        HStack(spacing: HopperLogic.spacing) {
                            ForEach(row, id: \.self) { i in
                                HopperCard(card: model.cards[i], selected: i == model.selection,
                                           thumbnail: model.showThumbnails ? model.thumbnails[model.cards[i].id] : nil,
                                           icon: model.appIcon)
                                    .onHover { inside in if inside { model.onHover?(i) } }
                                    .onTapGesture { model.onChoose?(i) }
                            }
                        }
                    }
                }
            }
            .padding(HopperLogic.padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One window: its picture (or the app icon), a selection ring and its title.
private struct HopperCard: View {
    let card: HopperModel.Card
    let selected: Bool
    let thumbnail: NSImage?
    let icon: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.1 : 0.06))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .padding(4)
                } else {
                    VStack(spacing: 8) {
                        if let icon {
                            Image(nsImage: icon).resizable().frame(width: 52, height: 52)
                        } else {
                            Image(systemName: "macwindow").font(.system(size: 34)).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
                if card.isMinimized {
                    Label {
                        Text("Minimized", comment: "Window state: minimized (a badge on a window, or how it is launched)")
                    } icon: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(7)
                }
            }
            .frame(width: HopperLogic.cardSize.width, height: HopperLogic.cardSize.height)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(-4)
                    .opacity(selected ? 1 : 0)
            }
            (card.title.isEmpty ? Text("Untitled", comment: "A window without a title") : Text(verbatim: card.title))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.62))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: HopperLogic.cardSize.width, height: HopperLogic.titleHeight - 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
