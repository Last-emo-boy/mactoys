import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Runs command-line tools.
public enum Shell {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Runs `executable` with arguments synchronously. Use from a background task for slow tools.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String] = [], input: String? = nil,
                           environment: [String: String]? = nil, currentDirectory: URL? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        if input != nil { process.standardInput = inPipe }
        do { try process.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: String(decoding: o, as: UTF8.self),
                      stderr: String(decoding: e, as: UTF8.self))
    }

    /// Runs a command line through `/bin/zsh -lc` (login shell, so the user's PATH applies).
    @discardableResult
    public static func zsh(_ command: String, currentDirectory: URL? = nil) -> Result {
        run("/bin/zsh", ["-lc", command], currentDirectory: currentDirectory)
    }

    public static func runAsync(_ executable: String, _ arguments: [String] = [], input: String? = nil) async -> Result {
        await Task.detached { run(executable, arguments, input: input) }.value
    }

    /// Single-quotes a string for safe use inside a shell command line.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// AppleScript helpers.
public enum AppleScript {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public let code: Int
        public var errorDescription: String? { message }
    }

    @discardableResult
    public static func run(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw Failure(message: "Invalid script", code: -1) }
        let result = script.executeAndReturnError(&error)
        if let error {
            throw Failure(message: error[NSAppleScript.errorMessage] as? String ?? "AppleScript error",
                          code: error[NSAppleScript.errorNumber] as? Int ?? -1)
        }
        return result
    }

    /// Escapes a Swift string as an AppleScript string literal (with quotes).
    public static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs a shell command as root after the standard administrator password prompt.
public enum Privileged {
    public static func run(_ command: String, prompt: String = "MacToys needs administrator access.") throws -> String {
        let source = "do shell script \(AppleScript.literal(command)) with prompt \(AppleScript.literal(prompt)) with administrator privileges"
        return try AppleScript.run(source).stringValue ?? ""
    }
}

/// The Finder's current selection and folder (needs Automation permission for Finder).
public enum FinderSelection {
    public static func selectedURLs() -> [URL] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with i in (get selection)
                set out to out & POSIX path of (i as alias) & linefeed
            end repeat
            return out
        end tell
        """
        guard let s = try? AppleScript.run(script).stringValue else { return [] }
        return s.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// The folder of the frontmost Finder window (or the Desktop).
    public static func currentFolder() -> URL? {
        let script = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (desktop as alias)
            end if
        end tell
        """
        guard let s = try? AppleScript.run(script).stringValue else { return nil }
        return URL(fileURLWithPath: s, isDirectory: true)
    }

    public static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
    }
}

/// Launch at login through SMAppService.
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.for("loginitem").error("\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// User notifications.
public enum Notifier {
    public static func post(_ title: String, _ body: String = "") {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
