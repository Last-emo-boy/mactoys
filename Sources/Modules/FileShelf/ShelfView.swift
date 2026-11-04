import AppKit
import MacToysCore
import SwiftUI

/// The shelf panel's content: a pile of thumbnails, or (expanded) a grid or list of the items.
struct ShelfView: View {
    @Bindable var model: ShelfModel
    /// Draw a soft shadow (preview scenes); the real panel gets the window shadow instead.
    var floating = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 22

    var body: some View {
        ZStack {
            if model.shelf.expanded {
                ExpandedShelf(model: model)
                    .transition(.opacity)
            } else {
                CollapsedShelf(model: model)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ShelfWindowDragArea(handler: model.handler))
        .background(ShelfSurface(cornerRadius: Self.cornerRadius))
        .overlay { DropHighlight(model: model, cornerRadius: Self.cornerRadius) }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(floating ? 0.28 : 0), radius: 22, y: 12)
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: model.shelf.expanded)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.isDropTarget)
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: model.shelf.items.map(\.id))
    }
}

/// Liquid Glass with a tinted fill under it (so it reads on any wallpaper and in offscreen
/// renders); solid when Reduce Transparency is on, with a stronger edge for Increase Contrast.
struct ShelfSurface: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(scheme == .dark ? Color(white: 0.12).opacity(0.66) : Color.white.opacity(0.68))
                    .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        }
        .overlay(shape.strokeBorder(edge, lineWidth: contrast == .increased ? 1.5 : 1))
    }

    private var edge: Color {
        if contrast == .increased { return .primary.opacity(0.5) }
        return scheme == .dark ? .white.opacity(0.14) : .black.opacity(0.08)
    }
}

// MARK: - Collapsed

private struct CollapsedShelf: View {
    let model: ShelfModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ZStack {
                if model.shelf.isEmpty {
                    EmptyDropWell(active: model.isDropTarget)
                } else {
                    ShelfPile(model: model, side: 84)
                        .scaleEffect(model.isDropTarget ? 1.06 : 1)
                }
                if model.busy != nil {
                    ProgressView().controlSize(.small)
                        .padding(8)
                        .background(Circle().fill(.regularMaterial))
                }
            }
            .frame(width: 124, height: 100)
            .overlay {
                if !model.shelf.isEmpty {
                    ShelfInteraction(target: .pile, handler: model.handler)
                        .help(Text("Click to show the items, drag to take them all"))
                }
            }
            .padding(.top, 18)
            Spacer(minLength: 6)
            VStack(spacing: 2) {
                Text(verbatim: model.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: model.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .overlay(alignment: .topLeading) {
            if model.isHovering {
                CornerButton(symbol: "xmark", help: Text("Close Shelf")) { model.handler?.closeShelf() }
                    .padding(9)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if model.isHovering {
                    MenuCornerButton(model: model).transition(.opacity)
                } else if model.shelf.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Tint.teal.color)
                        .rotationEffect(.degrees(35))
                        .frame(width: 22, height: 22)
                        .accessibilityLabel(Text("Pinned"))
                }
            }
            .padding(9)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: model.isHovering)
    }
}

/// Up to three cards fanned out, the newest on top, with the item count.
struct ShelfPile: View {
    let model: ShelfModel
    let side: CGFloat
    var showsCount = true

    private static let fan: [(angle: Double, x: CGFloat, y: CGFloat)] = [(0, 0, 0), (-9, -0.17, 0.04), (8, 0.17, 0.06)]

    var body: some View {
        let pile = model.shelf.pileItems
        ZStack {
            ForEach(Array(pile.enumerated().reversed()), id: \.element.id) { index, item in
                let f = Self.fan[index]
                ShelfItemThumb(item: item, thumbnail: model.thumbnail(for: item), side: side)
                    .rotationEffect(.degrees(f.angle))
                    .offset(x: f.x * side, y: f.y * side)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .bottomTrailing) {
            if showsCount, model.items.count > 1 {
                CountBadge(count: model.items.count)
                    .offset(x: side * 0.24, y: side * 0.1)
            }
        }
    }
}

/// The number of items, as a white-rimmed tinted capsule.
private struct CountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count.formatted())
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Tint.teal.color))
            .padding(1.5)
            .background(Capsule().fill(.white))
            .compositingGroup()
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .accessibilityLabel(Text("\(count) items", comment: "Shelf title: number of items on it"))
    }
}

/// The empty shelf's dashed drop well.
private struct EmptyDropWell: View {
    let active: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Tint.teal.color)
                .symbolEffect(.bounce, value: active)
        }
        .frame(width: 96, height: 80)
        .background(shape.fill(active ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.035)))
        .overlay(shape.strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.45),
                                    style: StrokeStyle(lineWidth: 1.5, dash: active ? [] : [5, 4])))
    }
}

private struct CornerButton: View {
    let symbol: String
    let help: Text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct MenuCornerButton: View {
    let model: ShelfModel
    @State private var frame = CGRect.zero

    var body: some View {
        CornerButton(symbol: "ellipsis", help: Text("Shelf Actions")) { model.handler?.showShelfMenu(below: frame) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

// MARK: - Expanded

private struct ExpandedShelf: View {
    let model: ShelfModel

    var body: some View {
        VStack(spacing: 0) {
            ExpandedHeader(model: model)
                .frame(height: ShelfGeometry.headerHeight)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if model.items.isEmpty {
                ExpandedEmpty(active: model.isDropTarget)
            } else {
                ScrollView {
                    switch model.layout {
                    case .grid: ShelfGrid(model: model)
                    case .list: ShelfList(model: model)
                    }
                }
                .scrollIndicators(.automatic)
            }
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: busy).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.primary.opacity(0.04))
            }
        }
    }
}

private struct ExpandedHeader: View {
    @Bindable var model: ShelfModel
    @State private var menuFrame = CGRect.zero
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ShelfPile(model: model, side: 26, showsCount: false)
                .frame(width: 34, height: 34)
                .overlay { ShelfInteraction(target: .all, handler: model.handler) }
                .help(Text("Drag to take every item"))
                .opacity(model.items.isEmpty ? 0.35 : 1)
            VStack(alignment: .leading, spacing: 1) {
                if model.renaming == .shelf {
                    TextField(text: $model.renameDraft, prompt: Text("Shelf name")) { EmptyView() }
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($titleFocused)
                        .onSubmit { model.handler?.commitRename() }
                        .onExitCommand { model.handler?.cancelRename() }
                        .onAppear { titleFocused = true }
                } else {
                    Text(verbatim: model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(verbatim: model.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                buttons
                    .opacity(model.isDropTarget ? 0 : 1)
                    .allowsHitTesting(!model.isDropTarget)
                if model.isDropTarget {
                    DropLabel(count: model.dropCount)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .trailing)))
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }

    /// Layout, pin, actions, collapse and close; a drop label takes their place while something
    /// is dragged over the shelf.
    private var buttons: some View {
        HStack(spacing: 2) {
            let next: ShelfLayout = model.layout == .grid ? .list : .grid
            HeaderButton(symbol: next.symbol, help: next == .grid ? Text("Show as Grid") : Text("Show as List")) {
                model.handler?.setLayout(next)
            }
            HeaderButton(symbol: model.shelf.pinned ? "pin.fill" : "pin", active: model.shelf.pinned,
                         help: model.shelf.pinned ? Text("Unpin Shelf") : Text("Pin Shelf")) {
                model.handler?.togglePin()
            }
            HeaderButton(symbol: "ellipsis.circle", help: Text("Shelf Actions")) {
                model.handler?.showShelfMenu(below: menuFrame)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { menuFrame = $0 }
            HeaderButton(symbol: "arrow.down.right.and.arrow.up.left", help: Text("Collapse to a Pile")) {
                model.handler?.toggleExpanded()
            }
            HeaderButton(symbol: "xmark", help: Text("Close Shelf")) { model.handler?.closeShelf() }
        }
    }
}

private struct HeaderButton: View {
    let symbol: String
    var active = false
    let help: Text
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(Tint.teal.color) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct ExpandedEmpty: View {
    let active: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Tint.teal.color)
            Text("Drop files, text or links here")
                .font(.system(size: 13, weight: .semibold))
            Text("Or paste them with ⌘V. Drag items out to any app.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfGrid: View {
    @Bindable var model: ShelfModel

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: ShelfGeometry.gridSpacing), count: ShelfGeometry.gridColumns)
        LazyVGrid(columns: columns, spacing: ShelfGeometry.gridSpacing) {
            ForEach(model.items) { item in
                ShelfTile(model: model, item: item)
                    .frame(height: ShelfGeometry.tileHeight)
            }
        }
        .padding(ShelfGeometry.contentPadding)
    }
}

private struct ShelfTile: View {
    @Bindable var model: ShelfModel
    let item: ShelfItem
    @FocusState private var focused: Bool

    var body: some View {
        let selected = model.selection.contains(item.id)
        let renaming = model.renaming == .item(item.id)
        VStack(spacing: 5) {
            ShelfItemThumb(item: item, thumbnail: model.thumbnail(for: item), side: 72)
                .frame(width: 88, height: 84)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(model.hoveredItem == item.id ? 0.06 : 0)))
            if renaming {
                TextField(text: $model.renameDraft, prompt: Text("Name")) { EmptyView() }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { model.handler?.commitRename() }
                    .onExitCommand { model.handler?.cancelRename() }
                    .onAppear { focused = true }
            } else {
                Text(verbatim: item.name)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(selected ? Color.accentColor : .clear))
            }
            Text(verbatim: ShelfItemText.short(item))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if !renaming { ShelfInteraction(target: .item(item.id), handler: model.handler) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ShelfList: View {
    @Bindable var model: ShelfModel

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(model.items) { item in
                ShelfRow(model: model, item: item)
                    .frame(height: ShelfGeometry.rowHeight)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, ShelfGeometry.contentPadding / 2)
    }
}

private struct ShelfRow: View {
    @Bindable var model: ShelfModel
    let item: ShelfItem
    @FocusState private var focused: Bool

    var body: some View {
        let selected = model.selection.contains(item.id)
        let renaming = model.renaming == .item(item.id)
        HStack(spacing: 10) {
            ShelfItemThumb(item: item, thumbnail: model.thumbnail(for: item), side: 32)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField(text: $model.renameDraft, prompt: Text("Name")) { EmptyView() }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .focused($focused)
                        .onSubmit { model.handler?.commitRename() }
                        .onExitCommand { model.handler?.cancelRename() }
                        .onAppear { focused = true }
                } else {
                    Text(verbatim: item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(verbatim: ShelfItemText.detail(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(selected ? Color.accentColor : Color.primary.opacity(model.hoveredItem == item.id ? 0.06 : 0))
            .padding(.vertical, 2))
        .contentShape(Rectangle())
        .overlay {
            if !renaming { ShelfInteraction(target: .item(item.id), handler: model.handler) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Drop highlight

private struct DropHighlight: View {
    let model: ShelfModel
    let cornerRadius: CGFloat

    var body: some View {
        if model.isDropTarget {
            let shape = RoundedRectangle(cornerRadius: cornerRadius - 3, style: .continuous)
            ZStack {
                shape.fill(Color.accentColor.opacity(0.08))
                shape.strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
            .padding(3)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// "Add 3 items" in the expanded header while something is dragged over the shelf.
private struct DropLabel: View {
    let count: Int

    var body: some View {
        Label {
            if count > 0 {
                Text("Add \(count) items", comment: "Drop label on a shelf: number of items being dropped")
            } else {
                Text("Drop to Add", comment: "Drop label on a shelf")
            }
        } icon: {
            Image(systemName: "plus.circle.fill")
        }
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.accentColor))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .padding(.trailing, 4)
    }
}

// MARK: - Item pictures

/// An item's picture at `side` points: a framed thumbnail, an icon, or a drawn card for text and links.
struct ShelfItemThumb: View {
    let item: ShelfItem
    let thumbnail: ShelfThumbnail
    let side: CGFloat

    var body: some View {
        Group {
            switch item.kind {
            case .text: TextClippingCard(text: item.preview ?? "", side: side)
            case .link: LinkCard(host: item.link?.host() ?? "", side: side)
            case .file, .image:
                if thumbnail.isIcon {
                    Image(nsImage: thumbnail.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                } else {
                    PrintFrame(image: thumbnail.image, side: side)
                }
            }
        }
        .frame(width: side, height: side)
    }
}

/// A photo or page thumbnail with a thin white border and a soft shadow.
private struct PrintFrame: View {
    let image: NSImage
    let side: CGFloat

    var body: some View {
        let border = max(1.5, side * 0.035)
        let size = Self.fit(image.size, in: side * 0.94 - border * 2)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: max(1.5, side * 0.03), style: .continuous))
            .padding(border)
            .background(RoundedRectangle(cornerRadius: max(2.5, side * 0.06), style: .continuous).fill(.white))
            .shadow(color: .black.opacity(0.22), radius: max(1, side * 0.045), y: max(0.5, side * 0.02))
    }

    static func fit(_ size: CGSize, in side: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: side, height: side) }
        let s = min(side / size.width, side / size.height)
        return CGSize(width: (size.width * s).rounded(), height: (size.height * s).rounded())
    }
}

/// Dropped text: a paper card showing its first lines.
private struct TextClippingCard: View {
    let text: String
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(2.5, side * 0.07), style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Color(white: 0.985))
            if side >= 48 {
                Text(verbatim: text)
                    .font(.system(size: max(5.5, side * 0.088)))
                    .foregroundStyle(Color(white: 0.25))
                    .lineSpacing(side * 0.01)
                    .padding(side * 0.09)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(LinearGradient(colors: [.black, .black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: side * 0.42, weight: .medium))
                    .foregroundStyle(Color(white: 0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: side * 0.8, height: side * 0.96)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: max(1, side * 0.04), y: max(0.5, side * 0.02))
    }

}

/// A web link: a tinted card with a globe and the site's name.
private struct LinkCard: View {
    let host: String
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(3, side * 0.16), style: .continuous)
        VStack(spacing: side * 0.04) {
            Image(systemName: "globe")
                .font(.system(size: side * (side >= 48 ? 0.34 : 0.48), weight: .medium))
            if side >= 48 {
                Text(verbatim: Self.siteName(host))
                    .font(.system(size: max(6, side * 0.1), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, side * 0.08)
            }
        }
        .foregroundStyle(.white)
        .frame(width: side * 0.86, height: side * 0.86)
        .background(shape.fill(LinearGradient(colors: [Tint.cyan.color, Tint.blue.color], startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: max(1, side * 0.04), y: max(0.5, side * 0.02))
    }

    /// "developer.apple.com" → "apple.com": the part people recognize, short enough for a card.
    static func siteName(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        // Keep three labels for country domains like "bbc.co.uk".
        return parts[parts.count - 2].count <= 3 && parts.last?.count == 2 ? parts.suffix(3).joined(separator: ".") : lastTwo
    }
}
