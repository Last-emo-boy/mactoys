import Foundation

/// A file or folder in the templates folder.
public struct NewPlusTemplate: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isFolder: Bool

    public init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
    }

    public var id: String { url.path }
    public var fileName: String { url.lastPathComponent }

    /// The name shown in menus.
    public func title(hideExtension: Bool, hideLeadingDigits: Bool) -> String {
        var name = fileName
        if hideLeadingDigits { name = NewPlusNames.stripLeadingDigits(name) }
        if hideExtension && !isFolder { name = NewPlusNames.stripExtension(name) }
        return name.isEmpty ? fileName : name
    }
}

/// Name rules shared by menus and creation.
public enum NewPlusNames {
    /// "1. Report.docx" → "Report.docx", "02 - Notes" → "- Notes" (digits, spaces and dots only, as in PowerToys).
    public static func stripLeadingDigits(_ name: String) -> String {
        let stripped = name.drop { $0.isNumber || $0 == " " || $0 == "." }
        return stripped.isEmpty ? name : String(stripped)
    }

    /// "Report.docx" → "Report"; dot files keep their name.
    public static func stripExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }

    /// "Report.docx" → "Report 2.docx" (Finder's style); folders and dot files number the whole name.
    public static func numbered(_ name: String, _ n: Int, isFolder: Bool) -> String {
        guard n > 1 else { return name }
        if !isFolder, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "\(name[..<dot]) \(n)\(name[dot...])"
        }
        return "\(name) \(n)"
    }
}

/// Listing and seeding the templates folder.
public enum NewPlusTemplates {
    /// Templates, folders first, then in Finder order (so leading digits sort as numbers).
    public static func list(in folder: URL) -> [NewPlusTemplate] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [.skipsHiddenFiles])) ?? []
        let items = urls.map { url -> NewPlusTemplate in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return NewPlusTemplate(url: url, isFolder: (v?.isDirectory ?? false) && !(v?.isPackage ?? false))
        }
        return items.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder
                : $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    /// Finds a template by its file name, then by its shown title (case-insensitive).
    public static func find(_ name: String, in templates: [NewPlusTemplate], hideExtension: Bool,
                            hideLeadingDigits: Bool) -> NewPlusTemplate? {
        templates.first { $0.fileName == name }
            ?? templates.first { $0.fileName.caseInsensitiveCompare(name) == .orderedSame }
            ?? templates.first {
                $0.title(hideExtension: hideExtension, hideLeadingDigits: hideLeadingDigits)
                    .caseInsensitiveCompare(name) == .orderedSame
            }
    }

    /// Fills an empty templates folder with a few useful starting points. The names are in the user's
    /// language at the time (this runs once); from then on they are the user's files. Contents stay as they are.
    public static func seed(_ folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func write(_ relative: String, _ text: String, executable: Bool = false) throws {
            let url = folder.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        // A translated name is one path component, whatever the translation holds.
        func name(_ s: String) -> String { String(s.map { $0 == "/" || $0 == ":" ? "-" : $0 }) }
        let project = name(String(localized: "Project", comment: "New+ default template: a folder, created once with this name"))
        try write(name(String(localized: "Text Document", comment: "New+ default template file name, created once (.txt is added)")) + ".txt", "")
        try write(name(String(localized: "Markdown Note", comment: "New+ default template file name, created once (.md is added)")) + ".md",
                  "# Untitled\n\n")
        try write(name(String(localized: "Rich Text Document", comment: "New+ default template file name, created once (.rtf is added)")) + ".rtf",
                  #"{\rtf1\ansi\ansicpg1252\cocoartf2822{\fonttbl\f0\fswiss Helvetica;}\f0\fs24 }"#)
        try write(name(String(localized: "Shell Script", comment: "New+ default template file name, created once (.sh is added)")) + ".sh",
                  "#!/bin/zsh\nset -euo pipefail\n\n", executable: true)
        try write(name(String(localized: "Python Script", comment: "New+ default template file name, created once (.py is added)")) + ".py",
                  "#!/usr/bin/env python3\n\n\ndef main() -> None:\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n",
                  executable: true)
        try write(name(String(localized: "Web Page", comment: "New+ default template file name, created once (.html is added)")) + ".html", """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Untitled</title>
            </head>
            <body>

            </body>
            </html>

            """)
        try write(project + "/README.md", "# Project\n\n")
        for sub in ["docs", "src"] {
            try fm.createDirectory(at: folder.appendingPathComponent(project).appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try write(project + "/.gitignore", ".DS_Store\n")
    }
}
