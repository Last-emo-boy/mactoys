import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import Workspaces

@Suite struct WorkspacesTests {
    // Built-in 1512×982 (menu bar 33) and an external 1920×1080 to its right.
    private let laptop = SavedDisplay(id: "A", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949), isMain: true)
    private let monitor = SavedDisplay(id: "B", name: "Studio", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
                                       visibleFrame: CGRect(x: 1512, y: 25, width: 1920, height: 1055), isMain: false)

    private func geometry(_ d: SavedDisplay) -> DisplayGeometry {
        DisplayGeometry(id: d.id, frame: d.frame, visibleFrame: d.visibleFrame, isMain: d.isMain)
    }

    // MARK: Capture and serialization

    @Test func assembleOrdersWindowsAndRecordsDisplaysAndStates() {
        typealias W = WorkspaceCapture.FoundWindow
        let windows = [
            W(id: 11, appName: "Music", bundleID: "com.apple.Music", appPath: "/System/Applications/Music.app",
              title: "Music", frame: CGRect(x: 1700, y: 200, width: 900, height: 600), isMinimized: true),
            W(id: 12, appName: "Xcode", bundleID: "com.apple.dt.Xcode", appPath: "/Applications/Xcode.app",
              title: "mactoys", frame: CGRect(x: 0, y: 33, width: 1008, height: 949)),
            W(id: 13, appName: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app",
              title: "Docs", frame: CGRect(x: 1600, y: 100, width: 1200, height: 800), isAppHidden: true),
            W(id: 14, appName: "Tiny", bundleID: nil, appPath: "/Applications/Tiny.app",
              title: "", frame: CGRect(x: 10, y: 10, width: 40, height: 30)),
        ]
        let ws = WorkspaceCapture.assemble(name: "Deep work", windows: windows, displays: [laptop, monitor],
                                           zOrder: [13, 12], moveExisting: false)
        #expect(ws.name == "Deep work")
        #expect(ws.moveExistingWindows == false)
        #expect(ws.apps.map(\.name) == ["Safari", "Xcode", "Music"])   // front to back, minimized last, tiny dropped
        #expect(ws.apps.map(\.displayID) == ["B", "A", "B"])
        #expect(ws.apps.map(\.state) == [.hidden, .saved, .minimized])
        #expect(ws.apps[1].windowTitle == "mactoys")
        #expect(ws.appCount == 3)
    }

    @Test func workspaceJSONRoundTrip() throws {
        var ws = Workspace(name: "Deep work", apps: [
            WorkspaceApp(name: "Code", bundleID: "com.microsoft.VSCode", appPath: "/Applications/Visual Studio Code.app",
                         windowTitle: "main.swift", displayID: "A", frame: CGRect(x: 0, y: 33, width: 1000, height: 949),
                         state: .fill, arguments: "--reuse-window \"~/My Project\"", openTarget: "~/Projects/app"),
        ], displays: [laptop, monitor], shortcut: Shortcut(0x12, [.control, .option]), launchAtLogin: true)
        ws.lastLaunched = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONEncoder().encode(ws)
        let back = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(back == ws)
    }

    @Test func olderFilesWithMissingKeysStillLoad() throws {
        let json = """
        {"name": "Old", "apps": [{"name": "Mail", "appPath": "/System/Applications/Mail.app", "displayID": "A",
          "frame": [[10, 40], [800, 600]]}], "displays": []}
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(ws.name == "Old")
        #expect(ws.moveExistingWindows)
        #expect(ws.shortcut == nil)
        #expect(ws.apps.first?.state == .saved)
        #expect(ws.apps.first?.arguments == "")
        #expect(ws.apps.first?.frame == CGRect(x: 10, y: 40, width: 800, height: 600))
    }

    @Test func settingsPersistThroughTheStore() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SettingsStore(directory: dir)
        var s = WorkspacesSettings()
        s.workspaces = [Workspace(name: "Morning", apps: [], displays: [laptop], launchAtLogin: true)]
        s.windowTimeout = 30
        store.save(s, id: "workspaces")
        let loaded = store.load("workspaces", default: WorkspacesSettings())
        #expect(loaded == s)
        #expect(loaded.editorShortcut == Shortcut(0x0D, [.control, .option]))
    }

    @Test func recaptureKeepsLaunchOptions() {
        let old = Workspace(name: "Dev", apps: [
            WorkspaceApp(name: "Terminal", bundleID: "com.apple.Terminal", appPath: "/T.app", displayID: "A",
                         frame: .zero, openTarget: "~/src"),
            WorkspaceApp(name: "Code", bundleID: "com.code", appPath: "/C.app", displayID: "A", frame: .zero,
                         arguments: "--reuse-window"),
        ], displays: [laptop], shortcut: Shortcut(0x12, [.control, .option]))
        let fresh = Workspace(name: "Workspace 9", apps: [
            WorkspaceApp(name: "Code", bundleID: "com.code", appPath: "/C.app", displayID: "B",
                         frame: CGRect(x: 1600, y: 30, width: 900, height: 700)),
            WorkspaceApp(name: "Safari", bundleID: "com.apple.Safari", appPath: "/S.app", displayID: "A", frame: .zero),
        ], displays: [laptop, monitor])
        let merged = fresh.keepingOptions(from: old)
        #expect(merged.id == old.id)
        #expect(merged.name == "Dev")
        #expect(merged.shortcut == old.shortcut)
        #expect(merged.apps.map(\.name) == ["Code", "Safari"])
        #expect(merged.apps[0].arguments == "--reuse-window")
        #expect(merged.apps[0].displayID == "B")
        #expect(merged.apps[1].arguments.isEmpty)
    }

    // MARK: Frame mapping when displays change

    @Test func sameDisplayKeepsTheExactFrame() {
        let frame = CGRect(x: 1008, y: 33, width: 504, height: 474)
        #expect(DisplayMapper.map(frame, from: laptop, to: geometry(laptop)) == frame)
    }

    @Test func rearrangedDisplayMovesTheFrameAlong() {
        // The monitor is now left of the laptop.
        var moved = geometry(monitor)
        moved.frame.origin = CGPoint(x: -1920, y: -100)
        moved.visibleFrame.origin = CGPoint(x: -1920, y: -75)
        let frame = CGRect(x: 1612, y: 125, width: 800, height: 600)
        #expect(DisplayMapper.map(frame, from: monitor, to: moved) == CGRect(x: -1820, y: 25, width: 800, height: 600))
    }

    @Test func changedResolutionScalesProportionally() {
        var scaled = geometry(laptop)
        scaled.frame.size = CGSize(width: 1728, height: 1117)
        scaled.visibleFrame = CGRect(x: 0, y: 33, width: 1728, height: 1084)
        // Left half of the old visible area stays the left half.
        let r = DisplayMapper.map(CGRect(x: 0, y: 33, width: 756, height: 949), from: laptop, to: scaled)
        #expect(r == CGRect(x: 0, y: 33, width: 864, height: 1084))
    }

    @Test func missingDisplayFallsBackToTheMainOne() {
        let current = [geometry(laptop)]
        let target = DisplayMapper.target(for: "B", among: current)
        #expect(target?.id == "A")
        // A window on the right half of the gone monitor lands on the right half of the laptop.
        let frame = CGRect(x: 1512 + 960, y: 25, width: 960, height: 1055)
        let r = DisplayMapper.map(frame, from: monitor, to: target!)
        #expect(r == CGRect(x: 756, y: 33, width: 756, height: 949))
    }

    @Test func unknownDisplayIsClampedOntoTheTarget() {
        let r = DisplayMapper.map(CGRect(x: 3000, y: -50, width: 2000, height: 400), from: nil, to: geometry(laptop))
        #expect(r == CGRect(x: 0, y: 33, width: 1512, height: 400))
        #expect(DisplayMapper.target(for: "Z", among: []) == nil)
    }

    @Test func draggedWindowIsRehomedToTheDisplayShowingMostOfIt() {
        let frame = CGRect(x: 1400, y: 100, width: 800, height: 600)
        #expect(DisplayMapper.display(for: frame, among: [laptop, monitor])?.id == "B")
    }

    // MARK: Editor geometry and text

    @Test func canvasMappingRoundTripsAndFits() {
        let map = CanvasMapping(displays: [laptop.frame, monitor.frame], canvas: CGSize(width: 600, height: 240), padding: 16)
        let r = CGRect(x: 1008, y: 33, width: 504, height: 474)
        let back = map.toGlobal(map.toCanvas(r))
        #expect(abs(back.minX - r.minX) < 0.001 && abs(back.width - r.width) < 0.001)
        let all = map.toCanvas(laptop.frame.union(monitor.frame))
        #expect(all.minX >= 16 - 0.001 && all.maxX <= 600 - 16 + 0.001)
        #expect(all.minY >= 0 && all.maxY <= 240)
        #expect(abs(all.midX - 300) < 0.001 && abs(all.midY - 120) < 0.001)
        #expect(abs(map.toGlobal(CGSize(width: map.scale * 10, height: 0)).width - 10) < 1e-9)
    }

    @Test func positionsAreDescribedInWords() {
        let v = laptop.visibleFrame
        #expect(PositionDescriber.describe(CGRect(x: 0, y: 33, width: 1008, height: 949), in: v) == "left two thirds")
        #expect(PositionDescriber.describe(CGRect(x: 1008, y: 33, width: 504, height: 474), in: v) == "top right")
        #expect(PositionDescriber.describe(CGRect(x: 1008, y: 507, width: 504, height: 475), in: v) == "bottom right")
        #expect(PositionDescriber.describe(CGRect(x: 756, y: 33, width: 756, height: 949), in: v) == "right half")
        #expect(PositionDescriber.describe(CGRect(x: 0, y: 40, width: 1500, height: 930), in: v) == "full screen")
        #expect(PositionDescriber.describe(CGRect(x: 300, y: 250, width: 600, height: 400), in: v) == "center")
        #expect(PositionDescriber.describe(CGRect(x: 0, y: 33, width: 1512, height: 474), in: v) == "top half")
    }

    @Test func workspaceSummaryAndPlacement() {
        var ws = Workspace(name: "Deep work", apps: [
            WorkspaceApp(name: "Xcode", bundleID: "x", appPath: "/X.app", displayID: "A",
                         frame: CGRect(x: 0, y: 33, width: 1008, height: 949), openTarget: NSHomeDirectory() + "/mactoys"),
            WorkspaceApp(name: "Music", bundleID: "m", appPath: "/M.app", displayID: "B", frame: .zero, state: .minimized),
            WorkspaceApp(name: "Xcode", bundleID: "x", appPath: "/X.app", displayID: "A", frame: .zero),
        ], displays: [monitor, laptop])
        #expect(WorkspaceText.summary(of: ws) == "2 apps · 2 displays")
        #expect(WorkspaceText.subtitle(of: ws.apps[0], in: ws) == "Display 1 · left two thirds · open ~/mactoys")
        #expect(WorkspaceText.placement(of: ws.apps[1], in: ws) == "Display 2 · minimized")
        ws.launchAtLogin = true
        #expect(WorkspaceText.summary(of: ws).hasSuffix("login item"))
    }

    @Test func lastUsedReadsAsARelativeDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_793_000_000)          // Monday, 26 Oct 2026
        let en = Locale(identifier: "en_US")
        #expect(WorkspaceText.relativeDay(now.addingTimeInterval(-600), now: now, calendar: cal, locale: en) == "today")
        #expect(WorkspaceText.relativeDay(now.addingTimeInterval(-86_400), now: now, calendar: cal, locale: en) == "yesterday")
        #expect(WorkspaceText.relativeDay(now.addingTimeInterval(-5 * 86_400), now: now, calendar: cal, locale: en) == "Wed")
        #expect(WorkspaceText.relativeDay(now.addingTimeInterval(-40 * 86_400), now: now, calendar: cal, locale: en) == "Sep 16")
    }

    // MARK: Launching

    @Test func argumentsSplitLikeAShell() {
        #expect(ArgumentSplitter.split("--reuse-window  ~/a") == ["--reuse-window", "~/a"])
        #expect(ArgumentSplitter.split(#"--profile "Ubuntu 24" 'x y' z\ w"#) == ["--profile", "Ubuntu 24", "x y", "z w"])
        #expect(ArgumentSplitter.split(#"a "b\"c" "d\n""#) == ["a", #"b"c"#, #"d\n"#])
        #expect(ArgumentSplitter.split(#"'' x"#) == ["", "x"])
        #expect(ArgumentSplitter.split("   ").isEmpty)
    }

    @Test func openTargetsBecomeURLsOrFiles() {
        let home = "/Users/test"
        #expect(OpenTarget.url("~/Projects/app", home: home)?.path == "/Users/test/Projects/app")
        #expect(OpenTarget.url("/tmp/a b.txt", home: home)?.isFileURL == true)
        #expect(OpenTarget.url("https://developer.apple.com", home: home)?.host == "developer.apple.com")
        #expect(OpenTarget.url("developer.apple.com/documentation", home: home)?.absoluteString
                == "https://developer.apple.com/documentation")
        #expect(OpenTarget.url("vscode://file/x", home: home)?.scheme == "vscode")
        #expect(OpenTarget.url("  ", home: home) == nil)
        #expect(OpenTarget.display("/Users/test/src", home: home) == "~/src")
        #expect(OpenTarget.display("https://swift.org", home: home) == "swift.org")
    }

    @Test func windowsAreMatchedByTitleThenOrder() {
        let saved = ["Notes — Ideas", "", "Inbox"]
        let windows = ["Inbox (3)", "Untitled", "Notes — Ideas"]
        #expect(WindowMatcher.assign(saved: saved, windows: windows) == [2, 1, 0])
        #expect(WindowMatcher.assign(saved: ["a", "b"], windows: ["x"]) == [0, nil])
        #expect(WindowMatcher.assign(saved: [], windows: ["x"]).isEmpty)
    }

    @Test func frontToBackKeepsUnstackedWindowsInOrder() {
        let ordered = WindowOrder.frontToBack([1, 2, 3, 4] as [CGWindowID], id: { $0 }, zOrder: [3, 1])
        #expect(ordered == [3, 1, 2, 4])
    }

    @MainActor @Test func launchSessionTracksStatuses() {
        let ws = Workspace(name: "Dev", apps: [
            WorkspaceApp(name: "A", bundleID: "a", appPath: "/A.app", displayID: "A", frame: .zero),
            WorkspaceApp(name: "B", bundleID: "b", appPath: "/B.app", displayID: "A", frame: .zero),
        ], displays: [laptop])
        let session = LaunchSession(workspace: ws)
        #expect(session.summary == "0 of 2 ready")
        session.set(ws.apps[0].id, .launched)
        session.set(ws.apps[1].id, .failed("No window appeared"))
        session.set(ws.apps[0].id, .launching)                     // final statuses stick
        #expect(session.rows[0].status == .launched)
        session.isFinished = true
        #expect(session.failedCount == 1)
        #expect(session.summary == "1 window couldn't be placed")
    }

    // MARK: Shortcuts and login

    @Test func exportedShortcutsOpenTheLaunchURL() throws {
        let ws = Workspace(name: "Deep work & more", apps: [], displays: [])
        let url = WorkspaceExport.launchURL(for: ws)
        let command = AppCommand(url: url)
        #expect(command?.module == "workspaces")
        #expect(command?.action == "launch")
        #expect(command?.parameters["name"] == "Deep work & more")

        let plist = try PropertyListSerialization.propertyList(from: WorkspaceExport.weblocData(for: url), format: nil)
        #expect((plist as? [String: String])?["URL"] == url.absoluteString)
        let script = WorkspaceExport.commandScript(for: url)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("open '\(url.absoluteString)'"))
        #expect(WorkspaceExport.appleScript(for: url) == "open location \"\(url.absoluteString)\"")
        #expect(WorkspaceExport.fileName(for: "a/b: c", kind: .webloc) == "a-b- c.webloc")
        #expect(WorkspaceExport.fileName(for: "  ", kind: .app) == "Workspace.app")
    }

    @Test func webLocationAndScriptAreWrittenToDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ws = Workspace(name: "Morning", apps: [], displays: [])
        let webloc = dir.appendingPathComponent("Morning.webloc")
        try WorkspaceExport.write(.webloc, for: ws, to: webloc)
        #expect(FileManager.default.fileExists(atPath: webloc.path))
        let script = dir.appendingPathComponent("Morning.command")
        try WorkspaceExport.write(.command, for: ws, to: script)
        let perms = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(perms == 0o755)
    }

    @Test func loginLaunchWindow() {
        let login = Date(timeIntervalSince1970: 1_000_000)
        #expect(LoginSession.isLoginLaunch(appLaunch: login.addingTimeInterval(20), login: login))
        #expect(!LoginSession.isLoginLaunch(appLaunch: login.addingTimeInterval(3600), login: login))
        #expect(!LoginSession.isLoginLaunch(appLaunch: login, login: nil))
    }
}
