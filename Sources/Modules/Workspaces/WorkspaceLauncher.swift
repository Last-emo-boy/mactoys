import AppKit
import MacToysCore
import Observation

/// The live state of one workspace launch, shown in the progress panel.
@MainActor
@Observable
final class LaunchSession: Identifiable {
    enum Status: Equatable {
        case waiting, launching, arranging, launched, moved, failed(String), cancelled

        var isFinal: Bool {
            switch self {
            case .waiting, .launching, .arranging: false
            default: true
            }
        }

        var isSuccess: Bool { self == .launched || self == .moved }

        var label: String {
            switch self {
            case .waiting: "Waiting"
            case .launching: "Launching…"
            case .arranging: "Arranging…"
            case .launched: "Launched"
            case .moved: "Moved into place"
            case .failed(let why): why
            case .cancelled: "Cancelled"
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let appPath: String
        let detail: String
        var status: Status
    }

    let id = UUID()
    let workspaceID: UUID
    let workspaceName: String
    var rows: [Row]
    var isFinished = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(workspace: Workspace, rows: [Row]) {
        workspaceID = workspace.id
        workspaceName = workspace.name
        self.rows = rows
    }

    convenience init(workspace: Workspace) {
        let rows = workspace.apps.map { app in
            Row(id: app.id, name: app.name, appPath: app.appPath,
                detail: WorkspaceText.placement(of: app, in: workspace), status: .waiting)
        }
        self.init(workspace: workspace, rows: rows)
    }

    func set(_ id: UUID, _ status: Status) {
        // Final states stick: a late cancel doesn't undo a window that was already placed.
        guard let i = rows.firstIndex(where: { $0.id == id }), !rows[i].status.isFinal else { return }
        rows[i].status = status
    }

    func cancel() { task?.cancel() }

    /// Marks everything still in progress as cancelled.
    func cancelRemaining() {
        for i in rows.indices where !rows[i].status.isFinal { rows[i].status = .cancelled }
    }

    var failedCount: Int { rows.filter { if case .failed = $0.status { true } else { false } }.count }

    var summary: String {
        let done = rows.filter(\.status.isFinal).count
        guard isFinished else { return "\(done) of \(rows.count) ready" }
        if rows.contains(where: { $0.status == .cancelled }) { return "Cancelled" }
        let failed = failedCount
        return failed == 0 ? "All windows are in place" : failed == 1 ? "1 window couldn't be placed" : "\(failed) windows couldn't be placed"
    }
}

/// Opens a workspace's apps and moves their windows into place.
@MainActor
enum WorkspaceLauncher {
    /// A window that was placed, with its position in the workspace (0 = frontmost).
    private struct Placed {
        let order: Int
        let window: WindowRef
    }

    @MainActor private final class PlacedList {
        var items: [Placed] = []
    }

    /// Launches every app concurrently, waits up to `timeout` for each app's windows, arranges them.
    static func run(_ workspace: Workspace, timeout: TimeInterval, session: LaunchSession) async {
        let displays = WorkspaceCapture.geometries()
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (i, app) in workspace.apps.enumerated() {
            if groups[app.appKey] == nil { order.append(app.appKey) }
            groups[app.appKey, default: []].append(i)
        }
        let placed = PlacedList()
        await withTaskGroup(of: Void.self) { group in
            for key in order {
                let indices = groups[key] ?? []
                group.addTask { @MainActor in
                    await launch(workspace, indices: indices, displays: displays, timeout: timeout,
                                 session: session, placed: placed)
                }
            }
        }
        if Task.isCancelled {
            session.cancelRemaining()
        } else {
            restack(placed.items)
        }
        session.isFinished = true
    }

    private static func launch(_ ws: Workspace, indices: [Int], displays: [DisplayGeometry], timeout: TimeInterval,
                               session: LaunchSession, placed: PlacedList) async {
        let entries = indices.map { ws.apps[$0] }
        guard let first = entries.first else { return }
        func setAll(_ status: LaunchSession.Status) { for e in entries { session.set(e.id, status) } }
        guard let appURL = applicationURL(for: first) else {
            setAll(.failed("App not found"))
            return
        }
        setAll(.launching)
        var app = runningApp(for: first)
        let wasRunning = app != nil
        let before = Set(app.map { WorkspaceCapture.standardWindows(of: $0.processIdentifier).compactMap(\.windowID) } ?? [])
        let reuse = wasRunning && ws.moveExistingWindows
        let needed = entries.filter { $0.state != .hidden }.count
        do {
            let withTargets = entries.filter { OpenTarget.url($0.openTarget) != nil }
            if !wasRunning {
                app = try await open(appURL, entry: first)
                for e in withTargets where e.id != first.id { _ = try await open(appURL, entry: e) }
            } else if !reuse || before.count < needed {
                // Ask the running app for (more) windows: open the targets, or reopen it.
                if withTargets.isEmpty { _ = try await open(appURL, entry: first) }
                for e in withTargets { _ = try await open(appURL, entry: e) }
            }
        } catch {
            setAll(Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
            return
        }
        guard let app else {
            setAll(.failed("The app didn't start"))
            return
        }
        if app.isHidden && entries.contains(where: { $0.state != .hidden }) { app.unhide() }

        let windows: [WindowRef]
        do {
            windows = try await waitForWindows(pid: app.processIdentifier, needed: needed, existing: before,
                                               reuse: reuse, wasRunning: wasRunning, timeout: timeout)
        } catch {
            setAll(.cancelled)
            return
        }
        let match = WindowMatcher.assign(saved: entries.map(\.windowTitle), windows: windows.map { $0.title ?? "" })
        for (k, entry) in entries.enumerated() {
            guard let j = match[k] else {
                session.set(entry.id, entry.state == .hidden ? .launched : .failed("No window appeared"))
                continue
            }
            session.set(entry.id, .arranging)
            let window = windows[j]
            do {
                try await arrange(window, entry, in: ws, displays: displays)
            } catch {
                session.set(entry.id, .cancelled)
                return
            }
            placed.items.append(Placed(order: indices[k], window: window))
            let existed = window.windowID.map(before.contains) ?? false
            session.set(entry.id, existed ? .moved : .launched)
        }
        if entries.contains(where: { $0.state == .hidden }) { app.hide() }
    }

    /// Polls the app's windows until enough appeared, appearances settle, or `timeout` passes.
    /// Throws only when cancelled.
    private static func waitForWindows(pid: pid_t, needed: Int, existing: Set<CGWindowID>, reuse: Bool,
                                       wasRunning: Bool, timeout: TimeInterval) async throws -> [WindowRef] {
        let start = Date()
        var firstSeen: Date?
        while true {
            try Task.checkCancellation()
            let all = WorkspaceCapture.standardWindows(of: pid)
            let fresh = all.filter { w in w.windowID.map { !existing.contains($0) } ?? false }
            // New windows first: they were opened for this workspace.
            let candidates = reuse ? fresh + all.filter { w in !fresh.contains(w) } : fresh
            if candidates.count >= needed { return candidates }
            let now = Date()
            if !candidates.isEmpty {
                let seen = firstSeen ?? now
                firstSeen = seen
                if now.timeIntervalSince(seen) > 2.5 { return candidates }
            }
            // A running app that won't open another window: move the ones it has.
            if wasRunning && fresh.isEmpty && !all.isEmpty && now.timeIntervalSince(start) > 3 { return all }
            if now.timeIntervalSince(start) > timeout { return candidates }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Moves one window to its saved place and applies its launch state. Throws only when cancelled.
    private static func arrange(_ w: WindowRef, _ e: WorkspaceApp, in ws: Workspace, displays: [DisplayGeometry]) async throws {
        AXUIElementSetMessagingTimeout(w.element, 1)
        guard let target = DisplayMapper.target(for: e.displayID, among: displays) else { return }
        let saved = ws.displays.first { $0.id == e.displayID }
        let frame = e.state == .fill ? target.visibleFrame : DisplayMapper.map(e.frame, from: saved, to: target)
        if w.isFullScreen && e.state != .fullScreen {
            w.element.set("AXFullScreen", kCFBooleanFalse)
            try await Task.sleep(for: .milliseconds(900))
        }
        if w.isMinimized {
            w.minimize(false)
            try await Task.sleep(for: .milliseconds(350))
        }
        w.setFrame(frame)
        // Apps restoring their own state sometimes move a window right after it appears.
        try await Task.sleep(for: .milliseconds(500))
        if let now = w.frame, abs(now.minX - frame.minX) > 2 || abs(now.minY - frame.minY) > 2
            || abs(now.width - frame.width) > 2 || abs(now.height - frame.height) > 2 {
            w.setFrame(frame)
        }
        switch e.state {
        case .minimized: w.minimize(true)
        case .fullScreen: w.element.set("AXFullScreen", kCFBooleanTrue)
        case .saved, .fill, .hidden: break
        }
    }

    /// Restores the saved stacking: back windows raised first, then the front app activated.
    private static func restack(_ items: [Placed]) {
        for p in items.sorted(by: { $0.order > $1.order }) where !p.window.isMinimized { p.window.raise() }
        guard let front = items.filter({ !$0.window.isMinimized }).min(by: { $0.order < $1.order }) else { return }
        front.window.focus()
        AXUIElementCreateApplication(front.window.pid).set(kAXFrontmostAttribute, kCFBooleanTrue)
    }

    private static func open(_ appURL: URL, entry: WorkspaceApp) async throws -> NSRunningApplication {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.arguments = ArgumentSplitter.split(entry.arguments)
        if let target = OpenTarget.url(entry.openTarget) {
            return try await NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: config)
        }
        return try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    static func applicationURL(for app: WorkspaceApp) -> URL? {
        if let id = app.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        guard !app.appPath.isEmpty, FileManager.default.fileExists(atPath: app.appPath) else { return nil }
        return URL(fileURLWithPath: app.appPath)
    }

    private static func runningApp(for app: WorkspaceApp) -> NSRunningApplication? {
        if let id = app.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
            return running
        }
        return NSWorkspace.shared.runningApplications.first { !$0.isTerminated && $0.bundleURL?.path == app.appPath }
    }
}

/// Human-readable bits shared by the editor and the progress panel.
enum WorkspaceText {
    /// "Display 1 · left two thirds".
    static func placement(of app: WorkspaceApp, in ws: Workspace) -> String {
        let display = ws.displays.first { $0.id == app.displayID }
        var parts = ["Display \(ws.displayNumber(of: app.displayID))"]
        switch app.state {
        case .saved:
            if let display { parts.append(PositionDescriber.describe(app.frame, in: display.visibleFrame)) }
        case .minimized: parts.append("minimized")
        case .fill: parts.append("fills the screen")
        case .fullScreen: parts.append("full screen")
        case .hidden: parts.append("hidden")
        }
        return parts.joined(separator: " · ")
    }

    /// Placement plus launch options: "Display 1 · top right · run: make dev".
    static func subtitle(of app: WorkspaceApp, in ws: Workspace) -> String {
        var parts = [placement(of: app, in: ws)]
        if !app.openTarget.isEmpty { parts.append("open \(OpenTarget.display(app.openTarget))") }
        if !app.arguments.isEmpty { parts.append("args: \(app.arguments)") }
        return parts.joined(separator: " · ")
    }

    /// "3 apps · 2 displays", "2 apps · login item", "3 apps · last used Tue".
    static func summary(of ws: Workspace, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let n = ws.appCount
        var parts = [n == 1 ? "1 app" : "\(n) apps"]
        if ws.displays.count > 1 { parts.append("\(ws.displays.count) displays") }
        if ws.launchAtLogin {
            parts.append("login item")
        } else if let last = ws.lastLaunched {
            parts.append("last used \(relativeDay(last, now: now, calendar: calendar, locale: locale))")
        }
        return parts.joined(separator: " · ")
    }

    static func relativeDay(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "yesterday" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = locale
        f.timeZone = calendar.timeZone
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7, days >= 0 {
            f.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return f.string(from: date)
    }
}
