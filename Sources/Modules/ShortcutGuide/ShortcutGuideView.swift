import AppKit
import MacToysCore
import Observation
import SwiftUI

@MainActor
@Observable
final class GuideModel {
    enum Tab: Hashable { case app, macOS, macToys }

    let appName: String
    let appIcon: NSImage?
    let bundleID: String
    var appGroups: [ShortcutGroup] = []
    var loading = true
    /// Shown instead of the app's shortcuts (no Accessibility, no menu bar).
    var appMessage: String?
    let systemGroups: [ShortcutGroup]
    let macToysGroups: [ShortcutGroup]
    var tab: Tab = .app
    var query = ""
    var openedByHold: Bool
    var pinned: Set<String>
    /// Bumped to move keyboard focus to the search field (⌘F).
    var searchFocusRequest = 0
    var onTogglePin: (ShortcutItem) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(appName: String, appIcon: NSImage?, bundleID: String, systemGroups: [ShortcutGroup],
         macToysGroups: [ShortcutGroup], openedByHold: Bool, pinned: Set<String>) {
        self.appName = appName
        self.appIcon = appIcon
        self.bundleID = bundleID
        self.systemGroups = systemGroups
        self.macToysGroups = macToysGroups
        self.openedByHold = openedByHold
        self.pinned = pinned
    }

    var appShortcutCount: Int { appGroups.reduce(0) { $0 + $1.items.count } }

    /// The current tab's groups after search, with pinned shortcuts first on the app tab.
    var visibleGroups: [ShortcutGroup] {
        let groups: [ShortcutGroup]
        switch tab {
        case .app:
            let pins = appGroups.flatMap { g in g.items.filter { pinned.contains($0.id) } }
            let pinnedGroup = ShortcutGroup(String(localized: "Pinned", comment: "Shortcut Guide: group of shortcuts pinned to the top"), pins)
            groups = (pins.isEmpty ? [] : [pinnedGroup]) + appGroups
        case .macOS: groups = systemGroups
        case .macToys: groups = macToysGroups
        }
        return ShortcutFilter.filter(groups, query: query)
    }
}

/// The full-screen guide (design 09).
struct ShortcutGuideView: View {
    @Bindable var model: GuideModel
    var dimOpacity: Double = 0.5
    var scheme: ColorScheme? = nil
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var systemScheme

    private var effectiveScheme: ColorScheme { scheme ?? systemScheme }
    private var dark: Bool { effectiveScheme == .dark }
    // Explicit colors: inside the large glass surface `.primary` doesn't follow the forced theme.
    private var ink: Color { dark ? .white : .black }
    private var secondaryInk: Color { ink.opacity(0.55) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(dimOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onClose() }
                card
                    .frame(width: min(geo.size.width * 0.86, 1440), height: min(geo.size.height * 0.84, 920))
            }
        }
        .ignoresSafeArea()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 26)
                .padding(.top, 26)
                .padding(.bottom, 18)
            content
        }
        .background(dark ? Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.78) : Color.white.opacity(0.78))
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(ink.opacity(0.12)))
        .environment(\.colorScheme, effectiveScheme)
        .onTapGesture {}   // keep clicks on the card from closing it
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    ModuleIcon(symbol: "app.dashed", tint: .graphite, size: 40)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: model.appName).font(.system(size: 22, weight: .bold)).foregroundStyle(ink)
                Text(verbatim: subtitle).font(.system(size: 12.5)).foregroundStyle(secondaryInk)
            }
            Spacer(minLength: 20)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(secondaryInk)
                TextField("Filter shortcuts", text: $model.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(ink)
                    .focused($searchFocused)
                    .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
            }
            .padding(.horizontal, 10)
            .frame(width: 260, height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(ink.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(ink.opacity(0.1)))
            Picker("", selection: $model.tab) {
                Text(verbatim: model.appName).tag(GuideModel.Tab.app)
                Text(verbatim: "macOS").tag(GuideModel.Tab.macOS)
                Text(verbatim: "MacToys").tag(GuideModel.Tab.macToys)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var subtitle: String {
        let what = switch model.tab {
        case .app where model.loading: String(localized: "Reading the menu bar…")
        case .app: String(localized: "\(model.appShortcutCount) shortcuts read from the menu bar")
        case .macOS: String(localized: "macOS keyboard shortcuts")
        case .macToys: String(localized: "Shortcuts of the MacToys utilities you have on")
        }
        let close = model.openedByHold
            ? String(localized: "release ⌘ to close", comment: "Shortcut Guide hint after the tab description")
            : String(localized: "esc to close", comment: "Shortcut Guide hint after the tab description")
        return "\(what) · \(close)"
    }

    @ViewBuilder private var content: some View {
        let groups = model.visibleGroups
        if model.tab == .app, let message = model.appMessage {
            placeholder(message, symbol: "exclamationmark.shield")
        } else if model.tab == .app, model.loading {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else if groups.isEmpty {
            placeholder(model.query.isEmpty ? String(localized: "No keyboard shortcuts.")
                                            : String(localized: "No shortcuts match “\(model.query)”.", comment: "%@ is the search text"),
                        symbol: "keyboard")
        } else {
            let columns = ColumnLayout.distribute(groups, columns: 3)
            ScrollView {
                HStack(alignment: .top, spacing: 30) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(column) { group in groupView(group) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    ForEach(0..<max(0, 3 - columns.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(secondaryInk)
            Text(verbatim: text).font(.system(size: 13)).foregroundStyle(secondaryInk).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: group.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 4)
            ForEach(group.items) { item in
                GuideRow(item: item, pinnable: model.tab == .app, pinned: model.pinned.contains(item.id), dark: dark) {
                    model.onTogglePin(item)
                }
            }
        }
    }
}

private struct GuideRow: View {
    let item: ShortcutItem
    let pinnable: Bool
    let pinned: Bool
    let dark: Bool
    let onPin: () -> Void
    @State private var hovering = false
    private var ink: Color { dark ? .white : .black }

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: item.title)
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(item.enabled ? 0.92 : 0.45))
                .lineLimit(1)
                .truncationMode(.middle)
            if pinnable && (hovering || pinned) {
                Button(action: onPin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(pinned ? Color.accentColor : ink.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(pinned ? Text("Unpin") : Text("Pin to the top"))
            }
            Spacer(minLength: 10)
            Keycaps(item.keys, dark: dark).opacity(item.enabled ? 1 : 0.5)
        }
        .frame(height: 31)
        .overlay(alignment: .bottom) { Rectangle().fill(ink.opacity(0.07)).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
