import AppKit
import MacToysCore
import SwiftUI

/// Sizes of the Run bar.
enum RunLayout {
    static let width: CGFloat = 640
    static let searchHeight: CGFloat = 58
    static let rowHeight: CGFloat = 50
    static let hintsHeight: CGFloat = 42
    static let previewHeight: CGFloat = 220

    @MainActor static func height(_ model: LauncherModel, maxRows: Int, showHints: Bool) -> CGFloat {
        let rows = min(model.items.count, max(1, maxRows))
        var h = searchHeight
        if rows > 0 { h += CGFloat(rows) * rowHeight + 12 }
        if RunView.preview(of: model) != nil { h += previewHeight }
        if showHints { h += hintsHeight }
        if model.actionsMenu != nil || model.confirmation != nil { h = max(h, 400) }
        return h
    }
}

/// A plugin keyword chip under the bar: `= Calc`.
struct RunHint: Identifiable {
    let keyword: String
    let label: String
    var id: String { keyword }
}

/// The Run bar (`design/exports/05-menubar-flyouts-huds.png`, "RUN — plugin keywords").
struct RunView: View {
    @Bindable var model: LauncherModel
    let hints: [RunHint]
    let maxRows: Int
    var singleClickActivates = false

    /// Text output to show under the list (shell or script output pages).
    @MainActor static func preview(of model: LauncherModel) -> String? {
        guard model.currentPage != nil, let d = model.details, let body = d.body, d.bodyMonospaced else { return nil }
        return body
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchRow
                if !model.items.isEmpty {
                    Rectangle().fill(LauncherStyle.hairline).frame(height: 1)
                    results
                }
                if let text = Self.preview(of: model) {
                    Rectangle().fill(LauncherStyle.hairline).frame(height: 1)
                    ScrollView {
                        Text(text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(LauncherStyle.primary.opacity(0.88))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(height: RunLayout.previewHeight)
                }
                if !hints.isEmpty {
                    hintRow
                }
                Spacer(minLength: 0)
            }
            if let menu = model.actionsMenu {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ActionsMenuView(state: menu) { model.perform($0, of: model.selectedItem) }
                    }
                }
                .padding(12)
            }
            if let c = model.confirmation {
                Color.black.opacity(0.35)
                ConfirmationView(confirmation: c, choice: model.confirmChoice) { model.answerConfirmation($0) }
            }
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.6))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            if let page = model.currentPage {
                Button { model.pop() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LauncherStyle.secondary)
                }
                .buttonStyle(.plain)
                Text(page.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(LauncherStyle.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
                    .fixedSize()
            } else {
                Image(systemName: "paperplane")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(LauncherStyle.secondary)
            }
            LauncherTextField(text: $model.query, placeholder: model.placeholder,
                              font: .monospacedSystemFont(ofSize: 19, weight: .regular),
                              focusRequest: model.focusRequest, selectAll: model.selectOnFocus)
                .frame(maxWidth: .infinity)
            if model.loading { ProgressView().controlSize(.small).tint(.white) }
        }
        .padding(.horizontal, 16)
        .frame(height: RunLayout.searchHeight)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                        ResultRow(item: item, selected: i == model.selection, iconSize: 26, showAccessory: false)
                            .id(item.id)
                            .onTapGesture(count: 2) { model.select(i); model.runSelected() }
                            .onTapGesture {
                                model.select(i)
                                if singleClickActivates { model.runSelected() }
                            }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.automatic)
            .frame(height: CGFloat(min(model.items.count, max(1, maxRows))) * RunLayout.rowHeight + 12)
            .onChange(of: model.selection) { _, new in
                let all = model.items
                if new < all.count { proxy.scrollTo(all[new].id) }
            }
        }
    }

    private var hintRow: some View {
        HStack(spacing: 6) {
            ForEach(hints) { h in
                HStack(spacing: 4) {
                    Text(h.keyword).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Color.accentColor)
                    Text(h.label).font(.system(size: 11.5)).foregroundStyle(LauncherStyle.secondary)
                }
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
                .onTapGesture { model.query = h.keyword + " " ; model.focusRequest += 1; model.selectOnFocus = false }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: RunLayout.hintsHeight)
    }
}
