import AppKit
import MacToysCore
import SwiftUI

/// The Keyboard Manager editor window.
@MainActor
final class RemapEditorWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: RemapEditorModel

    init(module: KeyboardManagerModule) {
        model = RemapEditorModel(module: module)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 780, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = String(localized: "Keyboard Manager")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "keyboardmanager.editor")
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 620, height: 380)
        window.delegate = self
        let host = NSHostingView(rootView: RemapEditorView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.setFrameAutosaveName("MacToys.KeyboardManager.Editor")
        if !window.setFrameUsingName("MacToys.KeyboardManager.Editor") { window.center() }
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.draft = nil
        window.makeFirstResponder(nil)
    }
}

/// Filter chips, the Keys and Shortcuts sections, and the add/edit sheet.
struct RemapEditorView: View {
    @Bindable var model: RemapEditorModel
    /// Draws a stand-in title bar, for offscreen previews without a real window.
    var showsWindowControls = false
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            if showsWindowControls { PreviewTitleBar(searching: $searching, model: model) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    chips
                    if !model.orphans.isEmpty {
                        let names = model.orphans.map(\.name).formatted(.list(type: .and, width: .narrow))
                        InfoBar(.warning, title: Text("Some keys can no longer be typed"),
                                message: Text("\(names) — no key produces them. Map another key to them if you need them.",
                                              comment: "%@ is a list of key names"))
                    }
                    let visible = model.visible
                    let keys = visible.filter { $0.kind == .key }
                    let shortcuts = visible.filter { $0.kind == .shortcut }
                    if visible.isEmpty { emptyState }
                    if !keys.isEmpty { section("Keys", keys) }
                    if !shortcuts.isEmpty { section("Shortcuts", shortcuts) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(edges: showsWindowControls ? .top : [])
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    ModuleIcon(symbol: "keyboard.fill", tint: .orange, size: 20)
                    Text("Keyboard Manager").font(.system(size: 13, weight: .semibold))
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if searching {
                    TextField("Search", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
                Button { searching.toggle(); if !searching { model.search = "" } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search remaps")
                addMenu
            }
        }
        .sheet(item: $model.draft) { draft in
            RemapSheet(remap: draft.remap, isNew: draft.isNew, model: model)
        }
        .onDeleteCommand { model.delete(model.selection) }
    }

    private var addMenu: some View {
        Menu {
            Button("Remap a key…") { model.addKey() }
            Button("Remap a shortcut…") { model.addShortcut() }
        } label: {
            Text("Add remap")
        } primaryAction: {
            model.addKey()
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(Text("All", comment: "Filter: every remap"), .all, count: model.remaps.count)
                chip(Text("Keys", comment: "Filter: key remaps"), .keys, count: model.count(.keys))
                chip(Text("Shortcuts", comment: "Filter: shortcut remaps"), .shortcuts, count: model.count(.shortcuts))
                ForEach(model.apps, id: \.self) { app in
                    chip(Text(verbatim: RemapFormatting.appName(app)), .app(app), count: nil)
                }
                chip(Text("Global", comment: "Remap filter and scope: applies in every app"), .global, count: nil)
            }
        }
    }

    private func chip(_ title: Text, _ f: RemapEditorModel.Filter, count: Int?) -> some View {
        let selected = model.filter == f
        return Button { model.filter = f } label: {
            HStack(spacing: 4) {
                title
                if let count { Text(count, format: .number).opacity(selected ? 0.9 : 0.6) }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .frame(height: 24)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor)))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Color.primary.opacity(0.13)))
        }
        .buttonStyle(.plain)
    }

    private func section(_ title: LocalizedStringKey, _ rows: [Remap]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider().padding(.leading, 12) }
                    RemapRow(remap: r, selected: model.selection.contains(r.id), model: model)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "keyboard").font(.system(size: 34)).foregroundStyle(.tertiary)
            (model.remaps.isEmpty ? Text("No remaps yet") : Text("No remaps match")).font(.headline)
            (model.remaps.isEmpty
                ? Text("Remap a key (⇪ → esc, Right ⌘ → F18) or a shortcut (⌥⇧K → ⌘⇧K in Xcode, ⌃⌥E → your email address).")
                : Text("Try another filter or search."))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.remaps.isEmpty {
                HStack {
                    Button("Remap a key…") { model.addKey() }
                    Button("Remap a shortcut…") { model.addShortcut() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.selection.isEmpty {
                Text("\(model.remaps.count) remaps · profile “\(model.profileName)” · app-specific remaps take precedence over global ones",
                     comment: "Number of remaps, then the profile name")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("\(model.selection.count) selected").font(.system(size: 11.5, weight: .medium))
                Button("Enable") { model.setEnabled(model.selection, true) }.controlSize(.small)
                Button("Disable") { model.setEnabled(model.selection, false) }.controlSize(.small)
                Button("Delete", role: .destructive) { model.delete(model.selection) }.controlSize(.small)
            }
            Spacer()
            if !model.remaps.isEmpty {
                Button("Select All") { model.selectAll() }.controlSize(.small).buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One "from → to" row with its scope badge.
struct RemapRow: View {
    let remap: Remap
    let selected: Bool
    let model: RemapEditorModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) { Keycaps(remap.triggerKeycaps) }
                .frame(width: 160, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
            target
            if let note = RemapFormatting.annotation(remap) {
                Text(verbatim: note).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering {
                Button { model.edit(remap.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help(Text("Edit", comment: "Button: edit the remap"))
            }
            ScopeBadge(remap: remap)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .opacity(remap.isEnabled ? 1 : 0.45)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.click(remap.id, modifiers: NSEvent.modifierFlags) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.edit(remap.id) })
        .contextMenu {
            Button("Edit…") { model.edit(remap.id) }
            Button("Duplicate") { model.duplicate(remap.id) }
            Button(remap.isEnabled ? "Disable" : "Enable") { model.setEnabled([remap.id], !remap.isEnabled) }
            Divider()
            Button("Delete", role: .destructive) {
                model.delete(model.selection.contains(remap.id) ? model.selection : [remap.id])
            }
        }
    }

    @ViewBuilder private var target: some View {
        switch remap.action.kind {
        case .send:
            Keycaps(remap.action.combo?.keycaps ?? [])
        case .text:
            Text(verbatim: RemapFormatting.actionSummary(remap.action)).lineLimit(1)
        case .run:
            Text(verbatim: RemapFormatting.actionSummary(remap.action)).lineLimit(1)
        case .openURL:
            Text(verbatim: remap.action.url ?? "").lineLimit(1).truncationMode(.middle)
        case .disable:
            Text(verbatim: RemapFormatting.actionSummary(remap.action)).foregroundStyle(.secondary)
        }
    }
}

struct ScopeBadge: View {
    let remap: Remap

    var body: some View {
        let global = remap.isGlobal
        Text(verbatim: RemapFormatting.scope(remap))
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(global ? Color.secondary : Color(nsColor: Tint.orange.nsColor.blended(withFraction: 0.25, of: .black) ?? .orange))
            .background(Capsule().fill(global ? Color.primary.opacity(0.07) : Tint.orange.color.opacity(0.16)))
    }
}

/// The window chrome the snapshot can't draw: traffic lights, title, search and Add remap.
private struct PreviewTitleBar: View {
    @Binding var searching: Bool
    let model: RemapEditorModel

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
            }
            .padding(.trailing, 10)
            ModuleIcon(symbol: "keyboard.fill", tint: .orange, size: 20)
            Text("Keyboard Manager").font(.system(size: 13, weight: .semibold))
            Spacer()
            Image(systemName: "magnifyingglass")
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.15)))
            Text("Add remap")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}
