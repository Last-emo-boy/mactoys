import AppKit
import ApplicationServices
import MacToysCore

/// One open window, captured off the main thread.
struct WindowSnapshot: @unchecked Sendable {
    let ref: MacToysCore.WindowRef?
    let windowID: CGWindowID?
    let pid: pid_t
    let title: String
    let appName: String
    let appPath: String?
    let minimized: Bool
    let hidden: Bool
    let frame: CGRect?
}

enum WindowCollector {
    /// Every window of every regular app, front-most first. Uses Accessibility when trusted (titles of
    /// minimized and off-screen windows too), otherwise the window server's on-screen list.
    static func collect(includeMinimized: Bool, includeHidden: Bool) -> [WindowSnapshot] {
        let own = ProcessInfo.processInfo.processIdentifier
        let onScreen = WindowInfo.onScreen()
        let zOrder = Dictionary(onScreen.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != own
        }
        var result: [WindowSnapshot] = []
        if AXIsProcessTrusted() {
            for app in apps {
                if app.isHidden && !includeHidden { continue }
                let axApp = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(axApp, 0.25)
                let windows: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
                for w in windows {
                    AXUIElementSetMessagingTimeout(w, 0.25)
                    let ref = MacToysCore.WindowRef(element: w, pid: app.processIdentifier)
                    let subrole = ref.subrole
                    guard subrole == kAXStandardWindowSubrole as String || subrole == kAXDialogSubrole as String else { continue }
                    let minimized = ref.isMinimized
                    if minimized && !includeMinimized { continue }
                    result.append(WindowSnapshot(ref: ref, windowID: ref.windowID, pid: app.processIdentifier,
                                                 title: ref.title ?? "", appName: app.localizedName ?? "",
                                                 appPath: app.bundleURL?.path, minimized: minimized, hidden: app.isHidden,
                                                 frame: ref.frame))
                }
            }
        } else {
            let byPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
            for info in onScreen {
                guard let app = byPID[info.pid] else { continue }
                result.append(WindowSnapshot(ref: nil, windowID: info.id, pid: info.pid, title: info.title,
                                             appName: app.localizedName ?? info.ownerName, appPath: app.bundleURL?.path,
                                             minimized: false, hidden: false, frame: info.frame))
            }
        }
        return result.enumerated().sorted { a, b in
            let za = a.element.windowID.flatMap { zOrder[$0] } ?? Int.max
            let zb = b.element.windowID.flatMap { zOrder[$0] } ?? Int.max
            return za != zb ? za < zb : a.offset < b.offset
        }.map(\.element)
    }
}

/// Window Walker (`<`): switch to, close or minimize any open window.
@MainActor
final class WindowsProvider: SearchProvider {
    let id = "windows"
    let name = String(localized: "Windows", comment: "Provider name: open windows")
    let summary = String(localized: "Switch to, close or minimize open windows of any app")
    let icon = ItemIcon.symbol("macwindow.on.rectangle", .indigo)
    let defaultKeyword = "<"
    var examples: [String] {
        ["< safari", "< readme",
         String(localized: "\("<")  (every window)", comment: "Run help example: %@ is what to type, the parentheses explain it")]
    }

    private let engine: LauncherEngine
    private var cache: [WindowSnapshot] = []
    private var cachedAt: Date?

    init(engine: LauncherEngine) { self.engine = engine }

    var commands: [PaletteItem] {
        [pageCommand(title: Phrase("Switch Windows"), subtitle: String(localized: "Every open window of every app"),
                     keywords: ["windows", "window walker", "switch"])]
    }

    func launcherWillShow() { cachedAt = nil }

    func search(_ query: SearchQuery) async -> [PaletteItem] {
        let text = query.text.trimmingCharacters(in: .whitespaces)
        guard query.scoped || text.count >= 2 else { return [] }
        let windows = await snapshot()
        guard !Task.isCancelled else { return [] }
        if text.isEmpty {
            return windows.enumerated().map { i, w in item(w, score: 1000 - Double(i)) }
        }
        return windows.compactMap { w in
            guard let s = FuzzyMatcher.best(text, title: w.title.isEmpty ? w.appName : w.title, keywords: [w.appName]) else { return nil }
            return item(w, score: query.scoped ? s : s * 0.8)
        }
    }

    private func snapshot() async -> [WindowSnapshot] {
        if let at = cachedAt, Date().timeIntervalSince(at) < 2 { return cache }
        let o = engine.options.value
        let minimized = o.windowsIncludeMinimized, hidden = o.windowsIncludeHidden
        cache = await background { WindowCollector.collect(includeMinimized: minimized, includeHidden: hidden) }
        cachedAt = Date()
        return cache
    }

    func item(_ w: WindowSnapshot, score: Double) -> PaletteItem {
        let app = NSRunningApplication(processIdentifier: w.pid)
        var notes = [w.appName]
        if w.minimized { notes.append(String(localized: "Minimized", comment: "Window state")) }
        if w.hidden { notes.append(String(localized: "Hidden", comment: "Window state: its app is hidden")) }
        var actions: [PaletteAction] = []
        if let ref = w.ref {
            actions.append(PaletteAction(id: "close", title: String(localized: "Close Window"), symbol: "xmark.square", shortcut: ActionKeys.close) {
                ref.close()
                self.cachedAt = nil
                return .refresh
            })
            actions.append(PaletteAction(id: "minimize", title: w.minimized ? String(localized: "Restore Window") : String(localized: "Minimize Window"),
                                         symbol: "minus.square", shortcut: Shortcut.cmd(0x2E /* kVK_ANSI_M */)) {
                ref.minimize(!w.minimized)
                self.cachedAt = nil
                return .refresh
            })
        }
        if let app {
            actions.append(PaletteAction(id: "hide", title: String(localized: "Hide \(w.appName)", comment: "Action; %@ is an app name"), symbol: "eye.slash") {
                app.hide()
                self.cachedAt = nil
                return .refresh
            })
            actions.append(PaletteAction(id: "quit", title: String(localized: "Quit \(w.appName)", comment: "Action; %@ is an app name"),
                                         symbol: "xmark.circle", shortcut: ActionKeys.quit) {
                app.terminate()
                self.cachedAt = nil
                return .refresh
            })
            actions.append(PaletteAction(id: "kill", title: String(localized: "Kill Process"), symbol: "xmark.octagon", destructive: true) {
                .confirm(Confirmation(title: String(localized: "Kill \(w.appName)?", comment: "Confirmation prompt; %@ is an app name"),
                                      message: String(localized: "The app quits immediately; unsaved changes are lost."),
                                      confirmTitle: String(localized: "Kill", comment: "Confirmation button: force a process to stop")) {
                    app.forceTerminate()
                    self.cachedAt = nil
                    return .refresh
                })
            })
        }
        if let path = w.appPath {
            actions.append(PaletteAction(id: "reveal", title: String(localized: "Show App in Finder"), symbol: "folder") {
                Launch.reveal(URL(fileURLWithPath: path))
                return .dismiss
            })
        }
        let frame = w.frame
        var rows = [DetailRow(label: Labels.app, value: w.appName, monospaced: false),
                    DetailRow(label: "PID", value: String(w.pid))]
        if let frame {
            rows.append(DetailRow(label: String(localized: "Position", comment: "Detail row: window position in points"),
                                  value: "\(Int(frame.minX)), \(Int(frame.minY))"))
            rows.append(DetailRow(label: Labels.size,
                                  value: "\(Int(frame.width)) × \(Int(frame.height))"))
        }
        return PaletteItem(
            id: "windows:\(w.pid):\(w.windowID ?? 0)", title: w.title.isEmpty ? w.appName : w.title,
            subtitle: notes.joined(separator: " · "), icon: w.appPath.map { .file($0) } ?? icon, providerID: id,
            accessory: String(localized: "Window", comment: "Result row label: an open window"), score: score,
            primary: PaletteAction(id: "focus", title: String(localized: "Switch to Window"), symbol: "macwindow") {
                .dismissThen {
                    if let ref = w.ref {
                        if w.minimized { ref.minimize(false) }
                        app?.unhide()
                        ref.focus()
                    } else {
                        app?.activate()
                    }
                }
            },
            actions: actions,
            details: ItemDetails(icon: w.appPath.map { .file($0) } ?? icon, title: w.title.isEmpty ? w.appName : w.title,
                                 subtitle: notes.joined(separator: " · "), rows: rows),
            isPinnable: false)
    }
}
