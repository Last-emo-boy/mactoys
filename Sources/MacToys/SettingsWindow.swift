import AppKit
import MacToysCore
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case general
    case module(String)

    init(page: String?) {
        switch page {
        case nil, "home": self = .home
        case "general": self = .general
        case let id?: self = .module(id)
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selection: SidebarItem? = .home
}

/// The main window. Showing it turns MacToys into a regular (Dock) app until it closes.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(page: String?) {
        if let page { SettingsNavigation.shared.selection = SidebarItem(page: page) }
        if window == nil {
            let controller = NSHostingController(rootView: SettingsRootView())
            let w = NSWindow(contentViewController: controller)
            w.title = "MacToys"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.toolbar = NSToolbar(identifier: "settings")
            w.setContentSize(NSSize(width: 1180, height: 780))
            w.minSize = NSSize(width: 860, height: 560)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacToysSettings")
            w.delegate = self
            if w.frame.origin == .zero { w.center() }
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !WelcomeWindow.shared.isVisible { NSApp.setActivationPolicy(.accessory) }
    }
}

struct SettingsRootView: View {
    @State private var registry = ModuleRegistry.shared
    @State private var nav = SettingsNavigation.shared
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.selection) {
                if search.isEmpty {
                    Section {
                        SidebarRow(title: String(localized: "Home"), symbol: "house.fill", tint: .graphite)
                            .tag(SidebarItem.home)
                        SidebarRow(title: String(localized: "General", comment: "Settings page for app-wide options"),
                                   symbol: "gearshape.fill", tint: .graphite)
                            .tag(SidebarItem.general)
                    }
                }
                ForEach(ModuleCategory.allCases) { category in
                    let mods = registry.modules(in: category).filter(matches)
                    if !mods.isEmpty {
                        Section(header: Text(verbatim: category.title)) {
                            ForEach(mods, id: \.info.id) { m in
                                SidebarRow(title: m.info.name, symbol: m.info.symbol, tint: m.info.tint,
                                           dimmed: !registry.isEnabled(m.info.id))
                                    .tag(SidebarItem.module(m.info.id))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    @ViewBuilder private var detail: some View {
        switch nav.selection ?? .home {
        case .home: HomeView()
        case .general: GeneralView()
        case .module(let id):
            if let m = registry.module(id) {
                m.settingsView().id(id)
            } else {
                ContentUnavailableView("Not found", systemImage: "questionmark.square.dashed")
            }
        }
    }

    private func matches(_ m: any ToyModule) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        return ([m.info.name, m.info.summary] + m.info.keywords).contains { $0.lowercased().contains(q) }
    }
}

struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Tint
    var dimmed = false

    var body: some View {
        Label {
            Text(verbatim: title).foregroundStyle(dimmed ? .secondary : .primary)
        } icon: {
            ModuleIcon(symbol: symbol, tint: tint, size: 20).saturation(dimmed ? 0.2 : 1)
        }
    }
}
