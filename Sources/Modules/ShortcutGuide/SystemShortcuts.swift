import Foundation

/// Default macOS shortcuts (Apple's "Mac keyboard shortcuts" support article), grouped for the macOS tab.
/// Titles and group names are localized; keycaps aren't.
enum SystemShortcuts {
    private static func s(_ title: LocalizedStringResource, _ keys: String...) -> ShortcutItem {
        ShortcutItem(String(localized: title), keys)
    }

    private static func group(_ title: LocalizedStringResource, _ items: [ShortcutItem]) -> ShortcutGroup {
        ShortcutGroup(String(localized: title), items)
    }

    static let groups: [ShortcutGroup] = [
        group("Apps & windows", [
            s(LocalizedStringResource("Spotlight", comment: "macOS shortcut: open Spotlight search (feature name)"), "⌘", "Space"),
            s("Switch apps", "⌘", "⇥"),
            s("Switch windows of the app", "⌘", "`"),
            s("Hide the app", "⌘", "H"),
            s("Hide other apps", "⌥", "⌘", "H"),
            s("Minimize window", "⌘", "M"),
            s("Close window", "⌘", "W"),
            s("Close all windows of the app", "⌥", "⌘", "W"),
            s("New window or document", "⌘", "N"),
            s(LocalizedStringResource("Open", comment: "macOS shortcut: open a file"), "⌘", "O"),
            s("Settings for the app", "⌘", ","),
            s("Quit the app", "⌘", "Q"),
            s(LocalizedStringResource("Force Quit", comment: "macOS shortcut: open the Force Quit window"), "⌥", "⌘", "⎋"),
            s("Enter or exit full screen", "fn", "F"),
            s("Emoji & Symbols", "fn", "E"),
            s("Character Viewer", "⌃", "⌘", "Space"),
        ]),
        group("Window tiling", [
            s("Fill the screen", "fn", "⌃", "F"),
            // A key of its own: "Center" is also a position elsewhere, and many languages use a verb here.
            s(LocalizedStringResource("Center (window tiling)", defaultValue: "Center",
                                      comment: "macOS shortcut: move the window to the center of the screen (a verb)"),
              "fn", "⌃", "C"),
            s("Tile left half", "fn", "⌃", "←"),
            s("Tile right half", "fn", "⌃", "→"),
            s("Tile top half", "fn", "⌃", "↑"),
            s("Tile bottom half", "fn", "⌃", "↓"),
            s("Arrange left and right", "fn", "⌃", "⇧", "←"),
            s("Arrange top and bottom", "fn", "⌃", "⇧", "↑"),
            s("Return to previous size", "fn", "⌃", "R"),
        ]),
        group("Mission Control & Spaces", [
            s(LocalizedStringResource("Mission Control", comment: "macOS shortcut: show Mission Control (feature name)"), "⌃", "↑"),
            s(LocalizedStringResource("Application windows", comment: "macOS shortcut: App Exposé, the current app's windows"), "⌃", "↓"),
            s("Move one space left", "⌃", "←"),
            s("Move one space right", "⌃", "→"),
            s("Show Desktop", "F11"),
        ]),
        group("Screenshots", [
            s("Screenshot or recording options", "⇧", "⌘", "5"),
            s("Capture the whole screen", "⇧", "⌘", "3"),
            s("Capture a selection", "⇧", "⌘", "4"),
            s("Capture a window (then press Space)", "⇧", "⌘", "4"),
            s("Copy the whole screen", "⌃", "⇧", "⌘", "3"),
            s("Copy a selection", "⌃", "⇧", "⌘", "4"),
        ]),
        group("Editing", [
            s(LocalizedStringResource("Undo", comment: "macOS shortcut: Edit menu command"), "⌘", "Z"),
            s(LocalizedStringResource("Redo", comment: "macOS shortcut: Edit menu command"), "⇧", "⌘", "Z"),
            s(LocalizedStringResource("Cut", comment: "macOS shortcut: Edit menu command"), "⌘", "X"),
            s(LocalizedStringResource("Copy", comment: "macOS shortcut: Edit menu command"), "⌘", "C"),
            s(LocalizedStringResource("Paste", comment: "macOS shortcut: Edit menu command"), "⌘", "V"),
            s("Paste and match style", "⌥", "⇧", "⌘", "V"),
            s("Select all", "⌘", "A"),
            s(LocalizedStringResource("Find", comment: "macOS shortcut: Edit menu command"), "⌘", "F"),
            s("Find next", "⌘", "G"),
            s("Find previous", "⇧", "⌘", "G"),
            s(LocalizedStringResource("Bold", comment: "macOS shortcut: text style"), "⌘", "B"),
            s(LocalizedStringResource("Italic", comment: "macOS shortcut: text style"), "⌘", "I"),
            s(LocalizedStringResource("Underline", comment: "macOS shortcut: text style"), "⌘", "U"),
            s("Show fonts", "⌘", "T"),
            s("Look up the selected word", "⌃", "⌘", "D"),
            s("Show spelling and grammar", "⌘", ":"),
            s("Check document now", "⌘", ";"),
        ]),
        group("Text navigation", [
            s("Start of line", "⌘", "←"),
            s("End of line", "⌘", "→"),
            s("Start of document", "⌘", "↑"),
            s("End of document", "⌘", "↓"),
            s("Previous word", "⌥", "←"),
            s("Next word", "⌥", "→"),
            s("Delete previous word", "⌥", "⌫"),
            s("Delete to start of line", "⌘", "⌫"),
            s("Forward delete", "fn", "⌫"),
            s("Start of line or paragraph", "⌃", "A"),
            s("End of line or paragraph", "⌃", "E"),
            s("Delete to end of line", "⌃", "K"),
            s("Swap characters", "⌃", "T"),
        ]),
        group("Documents", [
            s(LocalizedStringResource("Save", comment: "macOS shortcut: File menu command"), "⌘", "S"),
            s("Duplicate or save as", "⇧", "⌘", "S"),
            s(LocalizedStringResource("Print", comment: "macOS shortcut: File menu command"), "⌘", "P"),
            s("Page setup", "⇧", "⌘", "P"),
            s("New tab", "⌘", "T"),
            s("Show next tab", "⌃", "⇥"),
            s("Show previous tab", "⌃", "⇧", "⇥"),
        ]),
        group("Finder", [
            s("New Finder window", "⌘", "N"),
            s("New folder", "⇧", "⌘", "N"),
            s(LocalizedStringResource("Get Info", comment: "macOS shortcut: Finder command"), "⌘", "I"),
            s(LocalizedStringResource("Duplicate", comment: "macOS shortcut: Finder command, duplicate the selected files"), "⌘", "D"),
            s(LocalizedStringResource("Quick Look", comment: "macOS shortcut: Finder, preview the selected file (feature name)"), "Space"),
            s(LocalizedStringResource("Open", comment: "macOS shortcut: Finder command, open the selected item"), "⌘", "↓"),
            s(LocalizedStringResource("Enclosing folder", comment: "macOS shortcut: Finder, go to the parent folder"), "⌘", "↑"),
            s("Move to Trash", "⌘", "⌫"),
            s("Empty Trash", "⇧", "⌘", "⌫"),
            s("Go to folder", "⇧", "⌘", "G"),
            s("Show hidden files", "⇧", "⌘", "."),
            s(LocalizedStringResource("Applications", comment: "macOS shortcut: Finder, go to the Applications folder"), "⇧", "⌘", "A"),
            s(LocalizedStringResource("Desktop", comment: "macOS shortcut: Finder, go to the Desktop folder"), "⇧", "⌘", "D"),
            s(LocalizedStringResource("Downloads", comment: "macOS shortcut: Finder, go to the Downloads folder"), "⌥", "⌘", "L"),
            s(LocalizedStringResource("Home", comment: "macOS shortcut: Finder, go to the home folder"), "⇧", "⌘", "H"),
            s(LocalizedStringResource("Utilities", comment: "macOS shortcut: Finder, go to the Utilities folder"), "⇧", "⌘", "U"),
            s("Finder search window", "⌥", "⌘", "Space"),
            s("Show or hide the Dock", "⌥", "⌘", "D"),
        ]),
        group("Session & accessibility", [
            s("Lock screen", "⌃", "⌘", "Q"),
            s("Log out", "⇧", "⌘", "Q"),
            s("Accessibility shortcuts", "⌥", "⌘", "F5"),
            s(LocalizedStringResource("VoiceOver", comment: "macOS shortcut: turn VoiceOver on or off (feature name)"), "⌘", "F5"),
        ]),
    ]
}
