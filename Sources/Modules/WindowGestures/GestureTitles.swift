import Foundation

/// Names and symbols for what gestures do, shared by the preview, the cheat sheet and the settings page.
enum GestureTitles {
    static func title(_ action: WindowAction) -> String {
        switch action {
        case .tile(let t, _): t.title
        case .restore: String(localized: "Restore", comment: "Window Gestures preview: put the window back to its size before it was tiled")
        case .moveToDisplay: String(localized: "Move to the other display")
        case .minimize: String(localized: "Minimize", comment: "Window Gestures action: minimize the window to the Dock")
        case .close: String(localized: "Close", comment: "Window Gestures action: close the window")
        case .quit: String(localized: "Quit", comment: "Window Gestures action: quit the app")
        case .enterFullScreen: String(localized: "Full Screen", comment: "Window Gestures preview: the window goes full screen")
        case .exitFullScreen: String(localized: "Exit Full Screen", comment: "Window Gestures preview")
        }
    }

    static func symbol(_ action: WindowAction) -> String {
        switch action {
        case .tile: "rectangle.split.2x1"
        case .restore: "arrow.uturn.backward"
        case .moveToDisplay: "display"
        case .minimize: "dock.arrow.down.rectangle"
        case .close: "xmark"
        case .quit: "power"
        case .enterFullScreen: "arrow.up.left.and.arrow.down.right"
        case .exitFullScreen: "arrow.down.right.and.arrow.up.left"
        }
    }

    static func dock(_ intent: DockIntent, app: String, settings s: WindowGesturesSettings) -> String {
        switch intent {
        case .show:
            switch s.dockUp {
            case .appExpose: String(localized: "Show \(app) windows", comment: "Window Gestures Dock badge; the app's name")
            case .showWindows, .nothing: String(localized: "Bring \(app) forward", comment: "Window Gestures Dock badge; the app's name")
            }
        case .hide:
            switch s.dockDown {
            case .minimize: String(localized: "Minimize \(app) windows", comment: "Window Gestures Dock badge; the app's name")
            case .hide, .nothing: String(localized: "Hide \(app)", comment: "Window Gestures Dock badge; the app's name")
            }
        }
    }

    static func symbol(_ intent: DockIntent, settings s: WindowGesturesSettings) -> String {
        switch intent {
        case .show: s.dockUp == .appExpose ? "rectangle.on.rectangle" : "macwindow.on.rectangle"
        case .hide: s.dockDown == .minimize ? "dock.arrow.down.rectangle" : "eye.slash"
        }
    }
}
