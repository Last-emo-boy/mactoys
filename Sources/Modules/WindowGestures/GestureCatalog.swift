import Foundation
import MacToysCore

/// Every gesture that is on, with what it does: the cheat sheet, the Shortcut Guide list and the
/// settings hero are built from this.
struct GestureEntry: Identifiable, Equatable {
    enum Place: Equatable { case titleBar, dock, menuBar }

    let id: String
    let place: Place
    let glyph: GestureGlyph.Kind
    /// What it does: "Left or right half".
    let title: String
    /// More about it: "Again: a third, then two thirds".
    let detail: String?
    /// Chips for keycap-style lists: ["Swipe", "←", "→"].
    let keys: [String]
}

enum GestureCatalog {
    static func entries(_ s: WindowGesturesSettings) -> [GestureEntry] {
        let swipe = Word.swipe
        var list: [GestureEntry] = []
        func add(_ id: String, _ place: GestureEntry.Place, _ glyph: GestureGlyph.Kind, _ title: String,
                 _ detail: String? = nil, keys: [String]) {
            list.append(GestureEntry(id: id, place: place, glyph: glyph, title: title, detail: detail, keys: keys))
        }
        if s.swipeToHalves {
            add("halves", .titleBar, .swipe(.left), String(localized: "Left or right half"),
                s.cycleSizes ? String(localized: "Again toward the edge: ⅓, then ⅔") : nil, keys: [swipe, "←", "→"])
            if s.cycleSizes {
                add("slide", .titleBar, .swipeAgain(.right), String(localized: "Slide a third over"),
                    String(localized: "Swipe the other way to move one column"), keys: [swipe, "→", "←"])
            }
        }
        if s.cornerSwipes {
            add("corners", .titleBar, .corner(.right, .up), String(localized: "Quarter in that corner"),
                s.cycleSizes ? String(localized: "Sideways, then up or down; again for a sixth")
                    : String(localized: "Sideways, then up or down"), keys: [swipe, "→", "↑"])
        }
        if s.swipeUp != .nothing {
            add("up", .titleBar, .swipe(.up), s.swipeUp.title, nil, keys: [swipe, "↑"])
        }
        if s.swipeDown != .nothing {
            add("down", .titleBar, .swipe(.down), s.swipeDown.title,
                s.swipeDown == .restoreThenMinimize ? String(localized: "A tiled window gets its old size back") : nil,
                keys: [swipe, "↓"])
        }
        if s.pinchIn != .nothing {
            let confirm = s.confirmClose && (s.pinchIn == .closeWindow || s.pinchIn == .quitApp)
            add("pinch-in", .titleBar, .pinchIn, s.pinchIn.title,
                confirm ? String(localized: "Hold until the ring fills") : nil, keys: [Word.pinchIn])
        }
        if s.pinchOut != .nothing {
            add("pinch-out", .titleBar, .pinchOut, s.pinchOut.title, nil, keys: [Word.pinchOut])
        }
        if s.doubleTap != .nothing {
            add("double-tap", .titleBar, .doubleTap, s.doubleTap.title,
                String(localized: "Two fingers, with Smart zoom on"), keys: [Word.doubleTap])
        }
        if let glyph = s.displayModifier.glyph {
            add("display", .titleBar, .swipe(.right), String(localized: "Move to the next display"),
                String(localized: "Swipe while holding \(glyph)", comment: "Window Gestures cheat sheet; the modifier key's symbol"),
                keys: [Word.hold, glyph, swipe])
        }
        if s.dockGestures {
            if s.dockUp != .nothing {
                add("dock-up", .dock, .swipe(.up), s.dockUp.title, nil, keys: [swipe, "↑"])
            }
            if s.dockDown != .nothing {
                add("dock-down", .dock, .swipe(.down), s.dockDown.title, nil, keys: [swipe, "↓"])
            }
        }
        if s.menuBarFill {
            add("menubar", .menuBar, .swipe(.down), String(localized: "Fill the front window"), nil, keys: [swipe, "↓"])
        }
        return list
    }

    /// The entries as Shortcut Guide rows, each title saying where the gesture is made.
    static func bindings(_ s: WindowGesturesSettings) -> [ShortcutBinding] {
        entries(s).map { e in
            let title: String = switch e.place {
            case .titleBar: String(localized: "\(e.title) · on a title bar",
                                   comment: "Shortcut list: a Window Gestures action, made on a window's title bar")
            case .dock: String(localized: "\(e.title) · on a Dock icon",
                               comment: "Shortcut list: a Window Gestures action, made on an app's Dock icon")
            case .menuBar: String(localized: "\(e.title) · on the menu bar",
                                  comment: "Shortcut list: a Window Gestures action, made on the menu bar")
            }
            return ShortcutBinding(title, keys: e.keys)
        }
    }

    /// Words shown as chips next to the arrows.
    enum Word {
        static var swipe: String { String(localized: "Swipe", comment: "Gesture chip: a two-finger swipe on the trackpad") }
        static var pinchIn: String { String(localized: "Pinch in", comment: "Gesture chip: two fingers moving together") }
        static var pinchOut: String { String(localized: "Pinch out", comment: "Gesture chip: two fingers moving apart") }
        static var doubleTap: String { String(localized: "Double-tap", comment: "Gesture chip: a two-finger double-tap") }
        static var hold: String { String(localized: "Hold", comment: "Keycap label: hold down the key that follows") }
    }
}
