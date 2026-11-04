import Darwin
import Foundation

/// Where the charge helper lives and how it is installed and removed. The scripts run through one
/// administrator prompt (`Privileged.run`); everything here is plain text so tests can check it.
public enum HelperPaths {
    public static let label = "com.w33d.mactoys.chargelimit"
    /// Root-owned copy of the `mactoys` command-line tool (never run a user-writable binary as root).
    public static let helper = "/Library/PrivilegedHelperTools/com.w33d.mactoys.chargelimit"
    public static let launchDaemon = "/Library/LaunchDaemons/com.w33d.mactoys.chargelimit.plist"
    /// The helper's settings and state (root-owned).
    public static let stateDirectory = "/Library/Application Support/MacToys/ChargeLimit"
    public static let stateFile = stateDirectory + "/helper-state.json"
    /// Created by the helper in its root-owned directory, owned by the console user, mode 0600.
    public static let socket = stateDirectory + "/helper.socket"
    /// The hidden CLI subcommand that runs the helper.
    public static let subcommand = "charge-helper"

    /// Every path the helper installs or creates, for the settings page and uninstall.
    public static let installed = [helper, launchDaemon, stateDirectory]
}

public struct HelperInstallPlan: Equatable, Sendable {
    /// The app's bundled CLI (`MacToys.app/Contents/Helpers/mactoys`).
    public var source: String
    /// The user allowed to talk to the helper.
    public var ownerUID: UInt32

    public init(source: String, ownerUID: UInt32) {
        self.source = source
        self.ownerUID = ownerUID
    }

    public var programArguments: [String] {
        [HelperPaths.helper, HelperPaths.subcommand, "--owner-uid", String(ownerUID)]
    }

    /// The LaunchDaemon: started at boot, restarted after a crash, not after a clean exit.
    public var launchDaemonPlist: String {
        let plist: [String: Any] = [
            "Label": HelperPaths.label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "AssociatedBundleIdentifiers": ["com.w33d.mactoys"],
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Stops an old helper, copies the tool root:wheel 0755, writes the LaunchDaemon root:wheel 0644
    /// and starts it.
    public var installScript: String {
        let q = Self.quote
        return """
        set -e
        umask 022
        /bin/launchctl bootout system/\(HelperPaths.label) >/dev/null 2>&1 || true
        /bin/mkdir -p /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 0755 \(q(source)) \(q(HelperPaths.helper))
        /bin/mkdir -p \(q(HelperPaths.stateDirectory))
        /usr/sbin/chown root:wheel \(q(HelperPaths.stateDirectory))
        /bin/chmod 0755 \(q(HelperPaths.stateDirectory))
        /bin/cat > \(q(HelperPaths.launchDaemon)) <<'MACTOYS_PLIST'
        \(launchDaemonPlist.trimmingCharacters(in: .newlines))
        MACTOYS_PLIST
        /usr/sbin/chown root:wheel \(q(HelperPaths.launchDaemon))
        /bin/chmod 0644 \(q(HelperPaths.launchDaemon))
        /bin/launchctl bootstrap system \(q(HelperPaths.launchDaemon))
        """
    }

    /// Fallback removal when the helper doesn't answer: stops it, lets the installed copy restore normal
    /// charging once, then deletes every file.
    public static var uninstallScript: String {
        let q = quote
        return """
        /bin/launchctl bootout system/\(HelperPaths.label) >/dev/null 2>&1 || true
        if [ -x \(q(HelperPaths.helper)) ]; then \(q(HelperPaths.helper)) \(HelperPaths.subcommand) --restore >/dev/null 2>&1 || true; fi
        /bin/rm -f \(q(HelperPaths.launchDaemon)) \(q(HelperPaths.helper))
        /bin/rm -rf \(q(HelperPaths.stateDirectory))
        /bin/rmdir \(q((HelperPaths.stateDirectory as NSString).deletingLastPathComponent)) >/dev/null 2>&1 || true
        true
        """
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// `charge-helper --owner-uid <uid>` runs the daemon; `charge-helper --restore` restores normal
/// charging once and exits.
public enum HelperArguments: Equatable, Sendable {
    case run(ownerUID: UInt32)
    case restore

    public static func parse(_ args: [String]) -> HelperArguments? {
        if args == ["--restore"] { return .restore }
        guard args.count == 2, args[0] == "--owner-uid", let uid = UInt32(args[1]), uid > 0 else { return nil }
        return .run(ownerUID: uid)
    }
}

/// The helper refuses to run as root unless its own executable is the installed, root-owned copy
/// that nobody else can replace.
public enum HelperSelfCheck {
    public struct FileInfo: Equatable, Sendable {
        public var owner: UInt32
        public var mode: UInt16
        public var isDirectory: Bool
        public var isSymlink: Bool

        public init(owner: UInt32, mode: UInt16, isDirectory: Bool, isSymlink: Bool = false) {
            self.owner = owner
            self.mode = mode
            self.isDirectory = isDirectory
            self.isSymlink = isSymlink
        }
    }

    /// Nil when safe; otherwise why not.
    public static func problem(executable: String, info: (String) -> FileInfo?) -> String? {
        guard executable == HelperPaths.helper else { return "runs from \(executable), not \(HelperPaths.helper)" }
        var path = executable
        while true {
            guard let i = info(path) else { return "cannot inspect \(path)" }
            if i.isSymlink { return "\(path) is a symbolic link" }
            if i.owner != 0 { return "\(path) is not owned by root" }
            // Group/other writable is unsafe, except sticky directories like /Library/PrivilegedHelperTools on some systems.
            let writable = i.mode & 0o022 != 0
            let sticky = i.isDirectory && i.mode & 0o1000 != 0
            if writable && !sticky { return "\(path) is writable by other users" }
            if path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
            if path.isEmpty { path = "/" }
        }
        return nil
    }

    /// `lstat` of a path.
    public static func lstatInfo(_ path: String) -> FileInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileInfo(owner: st.st_uid, mode: UInt16(st.st_mode & 0o7777),
                        isDirectory: (st.st_mode & S_IFMT) == S_IFDIR, isSymlink: (st.st_mode & S_IFMT) == S_IFLNK)
    }

    /// This process's executable path.
    public static var executablePath: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }
}
