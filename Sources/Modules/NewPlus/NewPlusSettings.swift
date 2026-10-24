import Foundation
import MacToysCore

public struct NewPlusSettings: Codable, Equatable, Sendable {
    /// A templates folder chosen by the user (for example in iCloud Drive); nil for the default one.
    public var customTemplatesFolder: String?
    /// Show "Report" for "Report.docx" in menus.
    public var hideExtensions = true
    /// Show "Report" for "1. Report": leading digits, spaces and dots only order the templates.
    /// The new item's name drops them too.
    public var hideLeadingDigits = false
    /// Replace `$YYYY`, `$PARENT_FOLDER_NAME`, `%USERNAME%`, … in the names of new items.
    public var replaceVariables = false
    /// Select the new item in Finder and start renaming it (needs Accessibility to press Return).
    public var startRename = true
    /// Read by the Finder extension (the New+ submenu on folder backgrounds).
    public var showInFinderMenu = true
    /// Optional shortcut that opens the template picker for the frontmost Finder folder.
    public var activation: Shortcut?
    /// The default templates were written once; deleting them later doesn't bring them back.
    public var seeded = false

    public init() {}

    public static var defaultTemplatesFolder: URL {
        Paths.data(for: "NewPlus").appendingPathComponent("Templates", isDirectory: true)
    }

    public var templatesFolder: URL {
        if let custom = customTemplatesFolder, !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return Self.defaultTemplatesFolder
    }
}

/// The template list the Finder extension shows, written by the app whenever templates or settings change
/// (the sandboxed extension can't read a custom templates folder).
public struct NewPlusMenuManifest: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var fileName: String
        public var title: String
        public var isFolder: Bool
    }

    public var templatesFolder: String
    public var items: [Item]

    public static var url: URL { Paths.data(for: "NewPlus").appendingPathComponent("menu.json") }

    public init(templates: [NewPlusTemplate], settings: NewPlusSettings) {
        templatesFolder = settings.templatesFolder.path
        items = templates.map {
            Item(fileName: $0.fileName,
                 title: $0.title(hideExtension: settings.hideExtensions, hideLeadingDigits: settings.hideLeadingDigits),
                 isFolder: $0.isFolder)
        }
    }
}
