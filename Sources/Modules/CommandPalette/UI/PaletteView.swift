import AppKit
import MacToysCore
import SwiftUI

/// Sizes of the palette window.
enum PaletteLayout {
    static let width: CGFloat = 780
    static let fullHeight: CGFloat = 540
    static let searchHeight: CGFloat = 62
    static let shelfHeight: CGFloat = 50
    static let footerHeight: CGFloat = 40
    static let detailWidth: CGFloat = 300

    /// Window height for the current state.
    @MainActor static func height(_ model: LauncherModel, showShelf: Bool) -> CGFloat {
        if model.expanded || model.actionsMenu != nil || model.confirmation != nil { return fullHeight }
        return searchHeight + (showShelf && !model.shelfItems.isEmpty ? shelfHeight : 0)
    }
}

/// Appearance options read by the palette view.
struct PaletteAppearance {
    var showShelf = true
    var showDetails = true
    var backgroundOpacity = 0.55
    var singleClickActivates = false
    var filters: [(id: String, name: String)] = []
}

/// The Command Palette (`design/exports/04-command-palette.png`).
struct PaletteView: View {
    @Bindable var model: LauncherModel
    let appearance: PaletteAppearance

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchRow
                if showsShelf { shelf }
                if model.expanded {
                    Rectangle().fill(LauncherStyle.hairline).frame(height: 1)
                    HStack(spacing: 0) {
                        resultList
                        if appearance.showDetails, model.details != nil, !model.items.isEmpty || model.shelfSelection != nil {
                            Rectangle().fill(LauncherStyle.hairline).frame(width: 1)
                            DetailPane(details: model.details, fallbackIcon: model.selectedItem?.icon)
                                .frame(width: PaletteLayout.detailWidth)
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Rectangle().fill(LauncherStyle.hairline).frame(height: 1)
                    footer
                }
            }
            if let menu = model.actionsMenu {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ActionsMenuView(state: menu) { model.perform($0, of: model.selectedItem) }
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, model.expanded ? PaletteLayout.footerHeight + 6 : 8)
            }
            if let c = model.confirmation {
                Color.black.opacity(0.35)
                ConfirmationView(confirmation: c, choice: model.confirmChoice) { model.answerConfirmation($0) }
            }
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(appearance.backgroundOpacity))
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var showsShelf: Bool {
        appearance.showShelf && model.currentPage == nil && !model.shelfItems.isEmpty
    }

    // MARK: Search row

    private var searchRow: some View {
        HStack(spacing: 10) {
            if let page = model.currentPage {
                Button { model.pop() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LauncherStyle.secondary)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    ItemIconView(icon: page.icon, size: 18)
                    Text(page.title).font(.system(size: 13, weight: .medium)).foregroundStyle(LauncherStyle.primary).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
                .fixedSize()
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(LauncherStyle.secondary)
            }
            LauncherTextField(text: $model.query, placeholder: model.placeholder, focusRequest: model.focusRequest,
                              selectAll: model.selectOnFocus)
                .frame(maxWidth: .infinity)
            if model.loading {
                ProgressView().controlSize(.small).tint(.white)
            }
            if model.currentPage == nil, !appearance.filters.isEmpty { filterMenu }
        }
        .padding(.horizontal, 18)
        .frame(height: PaletteLayout.searchHeight)
    }

    private var filterMenu: some View {
        let title = model.filter.flatMap { id in appearance.filters.first { $0.id == id }?.name }
            ?? String(localized: "All results", comment: "Result filter: every provider")
        return Menu {
            Button(String(localized: "All results", comment: "Result filter: every provider")) { model.filter = nil }
            Divider()
            ForEach(appearance.filters, id: \.id) { f in
                Button { model.filter = f.id } label: {
                    if model.filter == f.id { Label(f.name, systemImage: "checkmark") } else { Text(verbatim: f.name) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: title).font(.system(size: 12))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(LauncherStyle.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Shelf

    private var shelf: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(model.shelfItems.enumerated()), id: \.element.id) { i, item in
                    shelfChip(item, index: i)
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.never)
        .frame(height: PaletteLayout.shelfHeight)
        .padding(.top, -6)
    }

    private func shelfChip(_ item: PaletteItem, index i: Int) -> some View {
        let selected = model.shelfSelection == i
        return HStack(spacing: 7) {
            ItemIconView(icon: item.icon, size: 20)
            Text(verbatim: item.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(LauncherStyle.primary).lineLimit(1)
            if i < 9 {
                Text(verbatim: "⌥\(i + 1)").font(.system(size: 11)).foregroundStyle(LauncherStyle.tertiary)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(selected ? 0.14 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.white.opacity(i == 0 && model.shelfSelection == nil ? 0.2 : 0.1),
                          lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.run(item) }
        .help(item.subtitle.isEmpty ? item.title : item.subtitle)
    }

    // MARK: Results

    private var resultList: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let offsets = sectionOffsets
                            ForEach(Array(model.sections.enumerated()), id: \.element.id) { si, section in
                                if !section.title.isEmpty { SectionHeader(title: section.title) }
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { i, item in
                                    let index = offsets[si] + i
                                    row(item, index: index)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: model.selection) { _, new in
                        let all = model.items
                        if new < all.count { proxy.scrollTo(all[new].id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionOffsets: [Int] {
        var out: [Int] = []
        var n = 0
        for s in model.sections { out.append(n); n += s.items.count }
        return out
    }

    private func row(_ item: PaletteItem, index: Int) -> some View {
        let selected = model.shelfSelection == nil && index == model.selection
        return ResultRow(item: item, selected: selected)
            .id(item.id)
            .onTapGesture(count: 2) { model.select(index); model.runSelected() }
            .onTapGesture {
                model.select(index)
                if appearance.singleClickActivates { model.runSelected() }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.loading {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .light)).foregroundStyle(LauncherStyle.tertiary)
                Group {
                    if model.query.isEmpty { Text("Nothing here yet") } else { Text("No results for “\(model.query)”", comment: "%@ is the search text") }
                }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(LauncherStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(LauncherStyle.secondary)
            Text(verbatim: footerText).font(.system(size: 12)).foregroundStyle(LauncherStyle.secondary).lineLimit(1)
            Spacer()
            if let item = model.selectedItem {
                Button { model.runSelected() } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: item.primary.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(LauncherStyle.primary)
                            .lineLimit(1)
                        LauncherKey(key: "↵")
                    }
                }
                .buttonStyle(.plain)
                Rectangle().fill(LauncherStyle.hairline).frame(width: 1, height: 16).padding(.horizontal, 4)
                Button { model.toggleActionsMenu() } label: {
                    HStack(spacing: 6) {
                        Text("Actions", comment: "Footer button that opens the ⌘K actions menu").font(.system(size: 12.5)).foregroundStyle(LauncherStyle.secondary)
                        LauncherKey(key: "⌘")
                        LauncherKey(key: "K")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: PaletteLayout.footerHeight)
    }

    private var footerText: String {
        if let page = model.currentPage {
            return "\(page.title) · \(String(localized: "\(model.items.count) items", comment: "How many items: results on a page, or entries in a folder"))"
        }
        let name = String(localized: "Command Palette")
        if model.isHome { return name }
        return "\(name) · \(String(localized: "\(model.providerCount) providers", comment: "How many providers returned results"))"
    }
}
