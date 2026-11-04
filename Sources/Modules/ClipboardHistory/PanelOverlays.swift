import MacToysCore
import SwiftUI

/// ⌘K: every action for the selection, keyboard-navigable.
struct ActionsMenuView: View {
    @Bindable var model: ClipboardPanelModel
    @Environment(\.clipStyle) private var style

    var body: some View {
        let commands = model.commands(for: model.selectedRow)
        VStack(alignment: .leading, spacing: 0) {
            Text("Actions", comment: "Heading of the clipboard panel's ⌘K menu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(style.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(Array(commands.enumerated()), id: \.element.id) { i, command in
                            row(command, selected: i == model.actionSelection)
                                .id(command.id)
                                .onTapGesture { model.perform(command.kind) }
                                .onHover { if $0 { model.actionSelection = i } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .onChange(of: model.actionSelection) { _, new in
                    if commands.indices.contains(new) { proxy.scrollTo(commands[new].id) }
                }
            }
        }
        .frame(width: 290)
        .frame(maxHeight: min(CGFloat(commands.count) * 31 + 40, 340))
        .clipGlass(cornerRadius: 14, backing: 1)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private func row(_ command: ClipboardPanelModel.Command, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(command.destructive ? Tint.red.color : selected ? .white : style.secondary)
            Text(verbatim: command.title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(command.destructive ? Tint.red.color : style.primary)
            Spacer(minLength: 8)
            HStack(spacing: 3) { ForEach(command.keys, id: \.self) { KeyCap(key: $0) } }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? style.selection : .clear))
        .contentShape(Rectangle())
    }
}

/// Edit, rename, new pinboard and clear-history dialogs, drawn inside the panel.
struct PanelSheetView: View {
    @Bindable var model: ClipboardPanelModel
    @Environment(\.clipStyle) private var style
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { model.cancelSheet() }
            card
                .frame(width: width)
                .clipGlass(cornerRadius: 16, backing: 1)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                .padding(12)
        }
        .onAppear { focused = true }
    }

    private var width: CGFloat {
        if case .editing = model.mode { return 460 }
        return 360
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.mode {
            case .editing(let id, let draft):
                title(Text("Edit Text", comment: "Clipboard panel dialog title"))
                TextEditor(text: Binding(get: { draft }, set: { model.mode = .editing(id, $0) }))
                    .font(.system(size: 12.5, design: isCode(draft) ? .monospaced : .default))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(8)
                    .frame(minHeight: 90, maxHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style.hairline))
                buttons(save: Text("Save", comment: "Button: save the edited clipboard text"), keys: ["⌘", "↩"])
            case .renaming(let id, let draft):
                title(Text("Rename", comment: "Clipboard panel dialog title: give an entry a name"))
                field(Text("Name", comment: "Placeholder: name of a clipboard entry"),
                      text: Binding(get: { draft }, set: { model.mode = .renaming(id, $0) }))
                Text("Names show in the list and are searched first. Leave empty to show the content again.")
                    .font(.system(size: 11.5)).foregroundStyle(style.secondary).fixedSize(horizontal: false, vertical: true)
                buttons(save: Text("Rename", comment: "Button: confirm renaming a clipboard entry"), keys: ["↩"])
            case .newPinboard(let draft, let tint):
                title(Text("New Pinboard"))
                field(Text("Name", comment: "Placeholder: name of a new pinboard"),
                      text: Binding(get: { draft }, set: { model.mode = .newPinboard($0, tint) }))
                HStack(spacing: 8) {
                    ForEach(Pinboard.tints, id: \.self) { t in
                        Circle().fill(t.color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.white, lineWidth: t == tint ? 2 : 0).padding(-3))
                            .onTapGesture { model.mode = .newPinboard(draft, t) }
                            .accessibilityLabel(Text(verbatim: t.colorName))
                    }
                }
                .padding(.vertical, 4)
                if !model.targetClips.isEmpty {
                    Text("The selected items are added to it.", comment: "New pinboard dialog")
                        .font(.system(size: 11.5)).foregroundStyle(style.secondary)
                }
                buttons(save: Text("Create", comment: "Button: create the pinboard"), keys: ["↩"],
                        disabled: draft.trimmingCharacters(in: .whitespaces).isEmpty)
            case .confirmClear:
                HStack(spacing: 10) {
                    Image(systemName: "trash.slash.fill").font(.system(size: 18)).foregroundStyle(Tint.red.color)
                    title(Text("Clear clipboard history?"))
                }
                Text("Pinned items, pinboards and snippets are kept. This can’t be undone.")
                    .font(.system(size: 12)).foregroundStyle(style.secondary).fixedSize(horizontal: false, vertical: true)
                buttons(save: Text("Clear History", comment: "Button: delete the clipboard history"), keys: ["↩"], destructive: true)
            case .browse, .actions:
                EmptyView()
            }
        }
        .padding(18)
    }

    private func title(_ text: Text) -> some View {
        text.font(.system(size: 15, weight: .semibold)).foregroundStyle(style.primary)
    }

    private func field(_ placeholder: Text, text: Binding<String>) -> some View {
        TextField(text: text, prompt: placeholder.foregroundStyle(style.tertiary)) { placeholder }
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .focused($focused)
            .onSubmit { model.commitSheet() }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style.hairline))
    }

    private func buttons(save: Text, keys: [String], disabled: Bool = false, destructive: Bool = false) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button { model.cancelSheet() } label: {
                HStack(spacing: 6) {
                    Text("Cancel")
                    KeyCap(key: "esc")
                }
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(style.primary)
            Button { model.commitSheet() } label: {
                HStack(spacing: 6) {
                    save
                    HStack(spacing: 2) { ForEach(keys, id: \.self) { Text(verbatim: $0).font(.system(size: 11, weight: .medium)).opacity(0.8) } }
                }
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(destructive ? Tint.red.color : Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
        }
        .padding(.top, 4)
    }

    private func isCode(_ text: String) -> Bool { ClipText.looksLikeCode(text) }
}
