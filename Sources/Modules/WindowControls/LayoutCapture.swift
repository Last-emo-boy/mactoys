import AppKit
import ApplicationServices
import MacToysCore

/// Reads the windows on screen into a layout, and puts open windows back where a layout says.
@MainActor
enum LayoutCapture {
    /// Windows of regular apps on the current Space, front to back.
    ///
    /// The window server lists them without talking to any app. With `accessibility`, each app is
    /// asked for its standard windows: only those are kept, with their titles (the window server
    /// gives titles only with Screen Recording access). Background snapshots skip that, so they can
    /// never stall on a busy app.
    static func found(excluded: [String], accessibility: Bool) -> [SavedLayout.Found] {
        let own = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        let useAX = accessibility && AXIsProcessTrusted()
        var apps: [pid_t: NSRunningApplication?] = [:]
        var standard: [pid_t: [CGWindowID: String]] = [:]
        var result: [SavedLayout.Found] = []
        for d in list {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let boundsDict = d[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 80, frame.height >= 60 else { continue }
            if let alpha = d[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            let app: NSRunningApplication?
            if let cached = apps[pid] { app = cached } else {
                app = NSRunningApplication(processIdentifier: pid)
                apps[pid] = app
            }
            guard let app, app.activationPolicy == .regular, !app.isTerminated, let bundleID = app.bundleIdentifier,
                  !excluded.matches(app: app) else { continue }
            var title = d[kCGWindowName as String] as? String ?? ""
            if useAX {
                if standard[pid] == nil { standard[pid] = standardWindowTitles(of: pid) }
                guard let axTitle = standard[pid]?[id] else { continue }
                if !axTitle.isEmpty { title = axTitle }
            }
            result.append(SavedLayout.Found(bundleID: bundleID, appName: app.localizedName ?? bundleID, title: title,
                                            frame: frame))
        }
        return result
    }

    /// A layout of the windows on screen now.
    static func snapshot(name: String, excluded: [String], accessibility: Bool) -> SavedLayout {
        SavedLayout.assemble(name: name, windows: found(excluded: excluded, accessibility: accessibility),
                             displays: Screens.layoutDisplays())
    }

    /// Standard, visible windows of an app by window number, with their titles.
    private static func standardWindowTitles(of pid: pid_t) -> [CGWindowID: String] {
        var map: [CGWindowID: String] = [:]
        for w in standardWindows(of: pid) {
            if let id = w.windowID { map[id] = w.title ?? "" }
        }
        return map
    }

    /// Standard windows of an app that aren't minimized or full screen, with short Accessibility
    /// timeouts so a hung app can't stall the UI.
    static func standardWindows(of pid: pid_t) -> [WindowRef] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        let elements: [AXUIElement] = axApp.ax(kAXWindowsAttribute) ?? []
        return elements.compactMap { element in
            AXUIElementSetMessagingTimeout(element, 0.5)
            let ref = WindowRef(element: element, pid: pid)
            return ref.isStandard && !ref.isMinimized && !ref.isFullScreen ? ref : nil
        }
    }

    /// How a restore went.
    struct RestoreResult: Equatable {
        var moved = 0
        /// Windows of the layout whose app or window isn't open.
        var missing = 0
        /// Windows left alone because Auto Tiling arranges their display.
        var tiled = 0
    }

    /// Moves the open windows of the layout's apps to their saved frames. Apps that aren't running
    /// and windows that are gone are skipped.
    static func restore(_ layout: SavedLayout, mover: WindowMover, excluded: [String]) -> RestoreResult {
        var result = RestoreResult()
        guard AXIsProcessTrusted() else { return result }
        let displays = Screens.current()
        var rank: [CGWindowID: Int] = [:]
        for (i, info) in WindowInfo.onScreen().enumerated() where rank[info.id] == nil { rank[info.id] = i }

        var live: [LiveWindow] = []
        var refs: [WindowRef] = []
        var bundles: [String] = []
        for w in layout.windows where !bundles.contains(w.bundleID) { bundles.append(w.bundleID) }
        for bundle in bundles {
            var windows: [(ref: WindowRef, rank: Int)] = []
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            where !app.isTerminated && !excluded.matches(app: app) {
                for ref in standardWindows(of: app.processIdentifier) {
                    windows.append((ref, ref.windowID.flatMap { rank[$0] } ?? Int.max))
                }
            }
            // Front to back, as the layout numbered them; windows the window server doesn't list go last.
            let ordered = windows.enumerated().sorted { a, b in
                a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset
            }
            for (index, w) in ordered.enumerated() {
                live.append(LiveWindow(bundleID: bundle, index: index, title: w.element.ref.title ?? ""))
                refs.append(w.element.ref)
            }
        }

        let matches = LayoutMatcher.match(saved: layout.windows, live: live)
        for (saved, match) in zip(layout.windows, matches) {
            guard let j = match, let target = LayoutPlanner.target(for: saved, in: layout, displays: displays) else {
                result.missing += 1
                continue
            }
            switch mover.place(refs[j], at: target, displays: displays, quiet: true, focus: false) {
            case .moved, .unchanged: result.moved += 1
            case .tiled: result.tiled += 1
            case .failed: result.missing += 1
            }
        }
        return result
    }
}
