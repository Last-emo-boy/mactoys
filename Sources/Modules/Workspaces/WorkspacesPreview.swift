import Foundation
import MacToysCore
import SwiftUI

/// Sample workspaces for snapshots: two displays, a few well-known apps.
enum WorkspaceSamples {
    static let builtIn = SavedDisplay(id: "610-41262-0", name: "Built-in Retina Display",
                                      frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 33, width: 1512, height: 949), isMain: true)
    static let external = SavedDisplay(id: "7789-23345-4410", name: "LG UltraFine",
                                       frame: CGRect(x: 1512, y: 90, width: 1280, height: 800),
                                       visibleFrame: CGRect(x: 1512, y: 115, width: 1280, height: 775), isMain: false)

    static var deepWork: Workspace {
        Workspace(name: "Deep work", apps: [
            WorkspaceApp(name: "Xcode", bundleID: "com.apple.dt.Xcode", appPath: "/Applications/Xcode.app",
                         windowTitle: "mactoys", displayID: builtIn.id, frame: CGRect(x: 0, y: 33, width: 1008, height: 949),
                         openTarget: "~/Projects/mactoys/Package.swift"),
            WorkspaceApp(name: "Terminal", bundleID: "com.apple.Terminal", appPath: "/System/Applications/Utilities/Terminal.app",
                         displayID: builtIn.id, frame: CGRect(x: 1008, y: 33, width: 504, height: 474),
                         openTarget: "~/Projects/mactoys"),
            WorkspaceApp(name: "Safari", bundleID: "com.apple.Safari", appPath: "/Applications/Safari.app",
                         displayID: builtIn.id, frame: CGRect(x: 1008, y: 507, width: 504, height: 475),
                         openTarget: "developer.apple.com"),
            WorkspaceApp(name: "Music", bundleID: "com.apple.Music", appPath: "/System/Applications/Music.app",
                         displayID: external.id, frame: CGRect(x: 1640, y: 220, width: 1000, height: 560), state: .minimized),
        ], displays: [builtIn, external], shortcut: Shortcut(0x12, [.control, .option]))   // ⌃⌥1
    }

    static var all: [Workspace] {
        let day: TimeInterval = 86_400
        return [
            deepWork,
            Workspace(name: "Design review", apps: [
                WorkspaceApp(name: "Freeform", bundleID: "com.apple.freeform", appPath: "/System/Applications/Freeform.app",
                             displayID: builtIn.id, frame: CGRect(x: 0, y: 33, width: 1000, height: 949)),
                WorkspaceApp(name: "Messages", bundleID: "com.apple.MobileSMS", appPath: "/System/Applications/Messages.app",
                             displayID: builtIn.id, frame: CGRect(x: 1000, y: 33, width: 512, height: 949)),
                WorkspaceApp(name: "Notes", bundleID: "com.apple.Notes", appPath: "/System/Applications/Notes.app",
                             displayID: builtIn.id, frame: CGRect(x: 200, y: 200, width: 800, height: 600)),
            ], displays: [builtIn], lastLaunched: Date().addingTimeInterval(-5 * day)),
            Workspace(name: "Morning", apps: [
                WorkspaceApp(name: "Mail", bundleID: "com.apple.mail", appPath: "/System/Applications/Mail.app",
                             displayID: builtIn.id, frame: CGRect(x: 0, y: 33, width: 756, height: 949)),
                WorkspaceApp(name: "Calendar", bundleID: "com.apple.iCal", appPath: "/System/Applications/Calendar.app",
                             displayID: builtIn.id, frame: CGRect(x: 756, y: 33, width: 756, height: 949)),
            ], displays: [builtIn], launchAtLogin: true),
        ]
    }
}

/// Snapshot scene: the editor with three workspaces and "Deep work" selected.
struct WorkspacesEditorPreview: View {
    private let settings: Persisted<WorkspacesSettings>
    private let state = EditorState()

    init() {
        var s = WorkspacesSettings()
        s.workspaces = WorkspaceSamples.all
        // A throwaway store: the preview must never touch the user's workspaces.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mactoys-workspaces-preview-\(UUID().uuidString)")
        settings = Persisted("workspaces", default: s, store: SettingsStore(directory: dir))
        let first = s.workspaces.first
        state.selection = first?.id
        state.selectedApp = first?.apps.first?.id
        state.expandedApp = first?.apps.dropFirst().first?.id
    }

    var body: some View {
        WorkspacesEditorView(settings: settings, state: state, actions: EditorActions())
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Snapshot scene: the launch progress panel midway through "Deep work".
struct LaunchProgressPreview: View {
    var body: some View {
        LaunchProgressView(session: Self.session())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor static func session() -> LaunchSession {
        var ws = WorkspaceSamples.deepWork
        ws.apps.append(WorkspaceApp(name: "Figma", bundleID: "com.figma.Desktop", appPath: "/Applications/Figma.app",
                                    displayID: WorkspaceSamples.external.id,
                                    frame: CGRect(x: 1512, y: 115, width: 1280, height: 775)))
        let session = LaunchSession(workspace: ws)
        let statuses: [LaunchSession.Status] = [.launched, .moved, .arranging, .launching, .failed("App not found")]
        for (row, status) in zip(session.rows, statuses) { session.set(row.id, status) }
        return session
    }
}
