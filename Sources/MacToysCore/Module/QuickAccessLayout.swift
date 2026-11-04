import Foundation

/// Which quick actions the menu bar flyout shows up front. With dozens of utilities on, listing every
/// tile and switch makes the flyout taller than the screen, so it shows a chosen set and keeps the
/// rest one click away.
public enum QuickAccessLayout {
    public static let tileCount = 9
    public static let switchCount = 6

    /// Shown until the user picks their own; ids of utilities that are off are skipped.
    public static let defaultTiles = [
        "cmdpal.open", "screenshot.area", "textextractor.capture", "colorpicker.pick", "clipboard.open",
        "shelf.new", "fancyzones.editor", "zoomit.zoom", "privacyscreen.lock",
    ]
    public static let defaultSwitches = [
        "awake.toggle", "focusdimmer.toggle", "clipboard.recording", "switches.hideDesktopIcons",
        "switches.showHiddenFiles", "switches.darkMode",
    ]

    /// The ids to show and the ids left for "More", from the available ids in registry order.
    /// A user's own list is used as is (even when empty); the defaults are topped up to `limit`
    /// with other available ids so the flyout isn't empty when the default utilities are off.
    public static func split(available: [String], chosen: [String]?, defaults: [String], limit: Int)
        -> (shown: [String], more: [String]) {
        let set = Set(available)
        var shown: [String]
        if let chosen {
            shown = chosen.filter(set.contains)
        } else {
            shown = Array(defaults.filter(set.contains).prefix(limit))
            for id in available where shown.count < limit && !shown.contains(id) { shown.append(id) }
        }
        let shownSet = Set(shown)
        return (shown, available.filter { !shownSet.contains($0) })
    }

    /// The new list after turning `id` on or off, starting from what is shown now.
    public static func toggling(_ id: String, on: Bool, shown: [String]) -> [String] {
        var list = shown.filter { $0 != id }
        if on { list.append(id) }
        return list
    }
}
