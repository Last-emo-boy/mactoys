import AppKit
import MacToysCore
import SwiftUI

/// Colors of the dark glass launchers.
enum LauncherStyle {
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.38)
    static let selection = Color.white.opacity(0.1)
    static let hairline = Color.white.opacity(0.09)
    static let card = Color.white.opacity(0.05)
}

/// One result row (palette and Run).
struct ResultRow: View {
    let item: PaletteItem
    let selected: Bool
    var iconSize: CGFloat = 28
    var showAccessory = true
    /// "⌥3"-style hint for the first nine rows.
    var hint: String?

    var body: some View {
        HStack(spacing: 11) {
            ItemIconView(icon: item.icon, size: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(LauncherStyle.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.subtitle.isEmpty {
                    Text(verbatim: item.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LauncherStyle.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let hint, selected {
                Text(verbatim: hint).font(.system(size: 11)).foregroundStyle(LauncherStyle.tertiary)
            }
            if showAccessory, let accessory = item.accessory {
                Text(verbatim: accessory)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LauncherStyle.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? LauncherStyle.selection : .clear))
        .contentShape(Rectangle())
    }
}

/// Section header in the result list.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(LauncherStyle.secondary)
            .padding(.leading, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The detail pane of the selected item (`design/exports/04-command-palette.png`, right).
struct DetailPane: View {
    let details: ItemDetails?
    let fallbackIcon: ItemIcon?

    var body: some View {
        if let d = details {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if let image = d.image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(.bottom, 14)
                    } else if let file = d.previewFile {
                        FileThumbnail(url: file)
                            .frame(maxWidth: .infinity, maxHeight: 170)
                            .padding(.bottom, 14)
                    } else if let icon = d.icon ?? fallbackIcon {
                        ItemIconView(icon: icon, size: 44)
                            .padding(.bottom, 16)
                    }
                    Text(d.title)
                        .font(.system(size: d.largeTitle ? 30 : 17, weight: .bold).monospacedDigit())
                        .kerning(d.largeTitle ? -0.4 : 0)
                        .foregroundStyle(LauncherStyle.primary)
                        .lineLimit(d.largeTitle ? 2 : 3)
                        .minimumScaleFactor(0.5)
                        .textSelection(.enabled)
                    if let sub = d.subtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 13))
                            .foregroundStyle(LauncherStyle.secondary)
                            .padding(.top, 8)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    if !d.rows.isEmpty {
                        DetailTable(rows: d.rows).padding(.top, 18)
                    }
                    if let body = d.body {
                        Text(body)
                            .font(d.bodyMonospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                            .foregroundStyle(LauncherStyle.primary.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LauncherStyle.card))
                            .padding(.top, 14)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        } else {
            Color.clear
        }
    }
}

/// The rounded key/value table in the detail pane.
struct DetailTable: View {
    let rows: [DetailRow]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { Rectangle().fill(LauncherStyle.hairline).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.label)
                        .font(.system(size: 12))
                        .foregroundStyle(LauncherStyle.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 6)
                    Text(r.value)
                        .font(r.monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(LauncherStyle.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .minimumScaleFactor(0.75)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LauncherStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LauncherStyle.hairline))
    }
}

/// Keycap chip in launcher footers: ⌘ K, ↵.
struct LauncherKey: View {
    let key: String
    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LauncherStyle.secondary)
            .frame(minWidth: 20, minHeight: 20)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
    }
}

/// State of the ⌘K actions menu.
struct ActionsMenuState {
    var title: String
    var actions: [PaletteAction]
    var filter = ""
    var selection = 0

    var visible: [PaletteAction] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return actions }
        return actions.compactMap { a in FuzzyMatcher.score(q, a.title).map { (a, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// The ⌘K menu: a filterable list of the selected item's actions with their shortcuts.
struct ActionsMenuView: View {
    let state: ActionsMenuState
    var onRun: (PaletteAction) -> Void

    var body: some View {
        let visible = state.visible
        VStack(alignment: .leading, spacing: 0) {
            Text(state.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(LauncherStyle.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 1) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { i, a in
                            HStack(spacing: 9) {
                                Image(systemName: a.symbol)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .frame(width: 18)
                                    .foregroundStyle(a.destructive ? Color.red.opacity(0.9) : LauncherStyle.primary.opacity(0.8))
                                Text(a.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(a.destructive ? Color.red.opacity(0.95) : LauncherStyle.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if i == 0 && state.filter.isEmpty {
                                    LauncherKey(key: "↵")
                                } else if let s = a.shortcut {
                                    HStack(spacing: 3) { ForEach(Array(s.keys.enumerated()), id: \.offset) { LauncherKey(key: $0.element) } }
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(i == state.selection ? Color.accentColor.opacity(0.85) : .clear))
                            .contentShape(Rectangle())
                            .onTapGesture { onRun(a) }
                            .id(a.id)
                        }
                    }
                    .padding(.horizontal, 5)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 330)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: state.selection) { _, new in
                    if new < visible.count { proxy.scrollTo(visible[new].id) }
                }
            }
            Rectangle().fill(LauncherStyle.hairline).frame(height: 1).padding(.top, 5)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(LauncherStyle.tertiary)
                Text(verbatim: state.filter.isEmpty ? String(localized: "Search actions…") : state.filter)
                    .font(.system(size: 12.5))
                    .foregroundStyle(state.filter.isEmpty ? LauncherStyle.tertiary : LauncherStyle.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .frame(width: 330)
        .background(Color(red: 0.13, green: 0.13, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

/// An inline confirmation for destructive actions.
struct ConfirmationView: View {
    let confirmation: Confirmation
    /// 0 = Cancel, 1 = confirm, 2 = alternate.
    var choice: Int
    var onAnswer: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: confirmation.destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(confirmation.destructive ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(confirmation.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(LauncherStyle.primary)
                    if !confirmation.message.isEmpty {
                        Text(confirmation.message).font(.system(size: 12)).foregroundStyle(LauncherStyle.secondary).lineLimit(3)
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                button(String(localized: "Cancel"), selected: choice == 0, tint: Color.white.opacity(0.12)) { onAnswer(0) }
                button(confirmation.confirmTitle, selected: choice == 1,
                       tint: confirmation.destructive ? Color.red.opacity(0.85) : Color.accentColor) { onAnswer(1) }
                if let alt = confirmation.alternateTitle {
                    button(alt, selected: choice == 2, tint: Color.white.opacity(0.18)) { onAnswer(2) }
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(Color(red: 0.13, green: 0.13, blue: 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
    }

    private func button(_ title: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Text(verbatim: title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
