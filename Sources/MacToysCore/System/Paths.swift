import Foundation
import os

public enum Paths {
    public static let bundleIdentifier = "com.w33d.mactoys"
    public static let urlScheme = "mactoys"

    /// ~/Library/Application Support/MacToys
    public static var appSupport: URL {
        directory(named: nil)
    }

    /// Settings JSON files, one per module (`<module-id>.json`) plus `general.json`.
    public static var settings: URL { directory(named: "Settings") }

    /// A per-module data directory, created on demand.
    public static func data(for moduleID: String) -> URL { directory(named: moduleID) }

    private static func directory(named name: String?) -> URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacToys", isDirectory: true)
        if let name { url.appendPathComponent(name, isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// `Log.for("fancyzones").info("…")`
public enum Log {
    public static func `for`(_ category: String) -> Logger {
        Logger(subsystem: Paths.bundleIdentifier, category: category)
    }
}
