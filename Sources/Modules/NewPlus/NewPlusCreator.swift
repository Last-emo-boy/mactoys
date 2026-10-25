import Foundation
import MacToysCore

/// Variables in template names (when "Replace variables" is on):
/// date and time (`$YYYY`, `$MM`, `$DD`, `$hh`, … see `DateTokens`, case-sensitive),
/// `$PARENT_FOLDER_NAME`, `$USERNAME`, and `%ENVIRONMENT_VARIABLE%` (case-insensitive;
/// `%USERNAME%` and `%USERPROFILE%` work as on Windows).
public enum NewPlusVariables {
    public struct Context: Sendable {
        public var date: Date
        /// The name of the folder the item is created in.
        public var parentFolderName: String
        public var environment: [String: String]

        public init(date: Date = Date(), parentFolderName: String, environment: [String: String] = Self.defaultEnvironment) {
            self.date = date
            self.parentFolderName = parentFolderName
            self.environment = environment
        }

        /// The process environment plus Windows-style names.
        public static var defaultEnvironment: [String: String] {
            var env = ProcessInfo.processInfo.environment
            env["USERNAME"] = env["USERNAME"] ?? NSUserName()
            env["USERPROFILE"] = env["USERPROFILE"] ?? NSHomeDirectory()
            env["USER"] = env["USER"] ?? NSUserName()
            env["HOME"] = env["HOME"] ?? NSHomeDirectory()
            return env
        }
    }

    /// Replaces the variables in one name. Characters a name can't hold (`/`, `:`) in values become spaces.
    public static func expand(_ name: String, context: Context) -> String {
        let upperEnv = Dictionary(context.environment.map { ($0.key.uppercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        var out = ""
        var i = name.startIndex
        while i < name.endIndex {
            let c = name[i]
            let rest = name[name.index(after: i)...]
            if c == "$" {
                if rest.hasPrefix("PARENT_FOLDER_NAME") {
                    out += clean(context.parentFolderName)
                    i = name.index(i, offsetBy: 1 + "PARENT_FOLDER_NAME".count)
                    continue
                }
                if rest.hasPrefix("USERNAME") {
                    out += clean(upperEnv["USERNAME"] ?? NSUserName())
                    i = name.index(i, offsetBy: 1 + "USERNAME".count)
                    continue
                }
                if let token = DateTokens.match(rest) {
                    out += DateTokens.value(of: token, date: context.date)
                    i = name.index(i, offsetBy: 1 + token.count)
                    continue
                }
            }
            if c == "%", let close = rest.firstIndex(of: "%") {
                let key = String(rest[..<close])
                if !key.isEmpty, !key.contains(" "), let value = upperEnv[key.uppercased()] {
                    out += clean(value)
                    i = name.index(after: close)
                    continue
                }
            }
            out.append(c)
            i = name.index(after: i)
        }
        return out
    }

    static func clean(_ value: String) -> String {
        String(value.map { $0 == "/" || $0 == ":" || $0 == "\0" || $0.isNewline ? " " : $0 })
    }
}

/// Copies a template into a folder.
public enum NewPlusCreator {
    public struct Options: Sendable {
        public var replaceVariables = false
        /// Drop leading digits, spaces and dots from the new item's name (with "Hide leading digits").
        public var stripLeadingDigits = false
        public var date = Date()

        public init(replaceVariables: Bool = false, stripLeadingDigits: Bool = false, date: Date = Date()) {
            self.replaceVariables = replaceVariables
            self.stripLeadingDigits = stripLeadingDigits
            self.date = date
        }
    }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Creates the item and returns its URL. Never overwrites: "Name 2.ext" is used when the name is taken.
    public static func create(from template: NewPlusTemplate, in folder: URL, options: Options = Options()) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure(message: String(localized: "“\(folder.lastPathComponent)” is not a folder"))
        }
        guard fm.fileExists(atPath: template.url.path) else {
            throw Failure(message: String(localized: "The template “\(template.fileName)” no longer exists"))
        }
        let base = targetName(for: template.fileName, isFolder: template.isFolder, folder: folder, options: options)
        let target = uniqueURL(base, isFolder: template.isFolder, in: folder)
        do {
            if options.replaceVariables && template.isFolder {
                try copyExpanding(template.url, to: target, options: options)
            } else {
                try fm.copyItem(at: template.url, to: target)
            }
            // A fresh item, not a copy of an old one.
            let now = Date()
            try? fm.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: target.path)
        } catch {
            try? fm.removeItem(at: target)
            throw Failure(message: error.localizedDescription)
        }
        return target
    }

    /// The new item's name before numbering.
    static func targetName(for fileName: String, isFolder: Bool, folder: URL, options: Options) -> String {
        var name = fileName
        if options.stripLeadingDigits { name = NewPlusNames.stripLeadingDigits(name) }
        if options.replaceVariables {
            name = NewPlusVariables.expand(name, context: .init(date: options.date, parentFolderName: folder.lastPathComponent))
        }
        name = name.trimmingCharacters(in: .whitespaces)
        guard name.isEmpty || name == "." || name == ".." else { return name }
        // Finder's names for new items, in the user's language.
        return isFolder ? String(localized: "untitled folder", comment: "Name of a new folder, as Finder names it")
                        : String(localized: "untitled", comment: "Name of a new file, as Finder names it")
    }

    static func uniqueURL(_ name: String, isFolder: Bool, in folder: URL) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent(NewPlusNames.numbered(name, n, isFolder: isFolder), isDirectory: isFolder)
            // lstat-based, so a dangling symlink counts as taken.
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil { return url }
            n += 1
        }
    }

    /// Copies a folder, replacing variables in every name inside it.
    private static func copyExpanding(_ source: URL, to target: URL, options: Options) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        if let attrs = try? fm.attributesOfItem(atPath: source.path), let perms = attrs[.posixPermissions] {
            try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: target.path)
        }
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let context = NewPlusVariables.Context(date: options.date, parentFolderName: target.lastPathComponent)
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isFolder = (values?.isDirectory ?? false) && !(values?.isSymbolicLink ?? false)
            var name = NewPlusVariables.expand(child.lastPathComponent, context: context).trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == "." || name == ".." { name = child.lastPathComponent }
            let dest = uniqueURL(name, isFolder: isFolder, in: target)
            if isFolder {
                try copyExpanding(child, to: dest, options: options)
            } else {
                try fm.copyItem(at: child, to: dest)
            }
        }
    }
}
