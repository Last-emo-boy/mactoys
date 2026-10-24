import Darwin
import Foundation

/// How a process uses a path.
public enum LockKind: String, Codable, Hashable, Sendable {
    /// An open file descriptor.
    case openFile
    /// The process's current directory.
    case workingDirectory
    /// The process's root directory (chroot).
    case rootDirectory
    /// The program file itself (or, from `lsof`, a memory-mapped file such as a library).
    case executable
}

/// One path in use by a process.
public struct LockedFile: Codable, Hashable, Sendable {
    public var path: String
    public var kind: LockKind
    /// The descriptor number for open files.
    public var descriptor: Int32?

    public init(path: String, kind: LockKind, descriptor: Int32? = nil) {
        self.path = path
        self.kind = kind
        self.descriptor = descriptor
    }
}

/// A process that uses one of the scanned paths.
public struct LockingProcess: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int32
    /// The process name (`Xcode`, `zsh`).
    public var name: String
    public var executablePath: String?
    public var uid: UInt32
    public var user: String
    /// Start time in microseconds since 1970; with the pid it identifies the process across pid reuse.
    public var startTime: UInt64
    /// The matching paths, sorted, without duplicates.
    public var files: [LockedFile]

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, executablePath: String?, uid: UInt32, user: String, startTime: UInt64,
                files: [LockedFile]) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
        self.uid = uid
        self.user = user
        self.startTime = startTime
        self.files = files
    }
}

/// Finds the processes that use files or folders, with libproc (no privileges: processes of other
/// users are not visible) or by parsing `lsof` run as root (`LsofParser`).
public enum FileLocksmithScanner {
    public struct Report: Sendable {
        public var processes: [LockingProcess]
        /// Processes whose open files could not be read (other users, protected system processes).
        public var inaccessible: Int
    }

    /// The processes using any of `paths`. Folders match everything inside them, recursively.
    public static func scan(paths: [URL]) -> [LockingProcess] {
        scanReport(paths: paths).processes
    }

    public static func scanReport(paths: [URL]) -> Report {
        let matcher = PathMatcher(paths)
        guard !matcher.isEmpty else { return Report(processes: [], inaccessible: 0) }
        var found: [LockingProcess] = []
        var inaccessible = 0
        for pid in allPIDs() where pid > 0 {
            switch files(of: pid, matching: matcher) {
            case .none:
                inaccessible += 1
            case .some(let files) where !files.isEmpty:
                if let info = processInfo(pid) {
                    found.append(LockingProcess(pid: pid, name: info.name, executablePath: info.path, uid: info.uid,
                                                user: userName(info.uid), startTime: info.start, files: normalize(files)))
                }
            default:
                break
            }
        }
        return Report(processes: sort(found), inaccessible: inaccessible)
    }

    /// Whether the process still runs (and is the same one: pids are reused).
    public static func isRunning(_ process: LockingProcess) -> Bool {
        guard let info = processInfo(process.pid) else { return kill(process.pid, 0) == 0 || errno == EPERM }
        return process.startTime == 0 || info.start == process.startTime
    }

    // MARK: libproc

    static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return Array(pids.prefix(max(0, Int(n))))
    }

    /// The matching paths a process uses, or nil when its descriptors can't be read.
    static func files(of pid: pid_t, matching matcher: PathMatcher) -> [LockedFile]? {
        var result: [LockedFile] = []
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        // Room for descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 32)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return nil }
        for fd in fds.prefix(Int(used) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = cString(&info.pvip.vip_path)
            if matcher.matches(path) { result.append(LockedFile(path: path, kind: .openFile, descriptor: fd.proc_fd)) }
        }
        var dirs = proc_vnodepathinfo()
        let dirSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &dirs, dirSize) == dirSize {
            let cwd = cString(&dirs.pvi_cdir.vip_path)
            if matcher.matches(cwd) { result.append(LockedFile(path: cwd, kind: .workingDirectory)) }
            let root = cString(&dirs.pvi_rdir.vip_path)
            if !root.isEmpty, root != "/", matcher.matches(root) { result.append(LockedFile(path: root, kind: .rootDirectory)) }
        }
        if let exe = executablePath(pid), matcher.matches(exe) {
            result.append(LockedFile(path: exe, kind: .executable))
        }
        return result
    }

    struct ProcessInfoLite {
        var name: String
        var path: String?
        var uid: UInt32
        var start: UInt64
    }

    static func processInfo(_ pid: pid_t) -> ProcessInfoLite? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        let path = executablePath(pid)
        var name = cString(&bsd.pbi_name)
        if name.isEmpty { name = cString(&bsd.pbi_comm) }
        if let path, let last = path.split(separator: "/").last, last.hasPrefix(name) || name.count >= 15 {
            name = String(last)
        }
        return ProcessInfoLite(name: name, path: path, uid: bsd.pbi_uid,
                               start: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec)
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func userName(_ uid: UInt32) -> String {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return String(uid) }
        return String(cString: name)
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    // MARK: Results

    static func normalize(_ files: [LockedFile]) -> [LockedFile] {
        var seen = Set<LockedFile>()
        return files.filter { seen.insert($0).inserted }.sorted {
            $0.path == $1.path ? ($0.descriptor ?? -1) < ($1.descriptor ?? -1) : $0.path < $1.path
        }
    }

    /// Most files first, then by name.
    static func sort(_ processes: [LockingProcess]) -> [LockingProcess] {
        processes.sorted {
            $0.files.count != $1.files.count ? $0.files.count > $1.files.count
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

/// Matches kernel paths against the scanned files and folders.
struct PathMatcher: Sendable {
    /// Resolved targets without a trailing slash ("/" stays "/").
    let targets: [String]

    init(_ urls: [URL]) {
        var list: [String] = []
        for url in urls {
            let resolved = Self.resolve(url.path)
            for p in Set([resolved, url.standardizedFileURL.path]) where !list.contains(p) { list.append(p) }
        }
        targets = list
    }

    init(paths: [String]) {
        targets = paths.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    }

    var isEmpty: Bool { targets.isEmpty }

    /// The path itself or anything below it.
    func matches(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        for t in targets {
            if t == "/" || path == t { return true }
            if path.hasPrefix(t), path.utf8.count > t.utf8.count,
               path.utf8[path.utf8.index(path.utf8.startIndex, offsetBy: t.utf8.count)] == UInt8(ascii: "/") {
                return true
            }
        }
        return false
    }

    /// Follows symlinks (`/tmp` → `/private/tmp`) as the kernel reports paths. For a path that
    /// doesn't exist (any more), its nearest existing folder is resolved.
    static func resolve(_ path: String) -> String {
        var head = URL(fileURLWithPath: path).standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let p = realpath(head, nil) {
                defer { free(p) }
                var s = String(cString: p)
                for part in tail.reversed() { s = (s == "/" ? "" : s) + "/" + part }
                return s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s
            }
            guard head != "/", !head.isEmpty else { return URL(fileURLWithPath: path).standardizedFileURL.path }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }
}

/// Parses `lsof -nP -w +c 0 -F pcuLftn` output.
public enum LsofParser {
    /// The arguments to run lsof with.
    public static let arguments = ["-nP", "-w", "+c", "0", "-F", "pcuLftn"]

    /// The processes using any of `paths`. Accepts `\n` or `\r` line ends (AppleScript output).
    public static func parse(_ output: String, paths: [URL]) -> [LockingProcess] {
        parse(output, matcher: PathMatcher(paths))
    }

    static func parse(_ output: String, matcher: PathMatcher) -> [LockingProcess] {
        var result: [Int32: LockingProcess] = [:]
        var order: [Int32] = []
        var current: LockingProcess?
        var fd = ""

        func flush() {
            guard let p = current, !p.files.isEmpty else { return }
            if result[p.pid] == nil { order.append(p.pid) }
            var merged = result[p.pid] ?? p
            if result[p.pid] != nil { merged.files += p.files }
            merged.files = FileLocksmithScanner.normalize(merged.files)
            result[p.pid] = merged
        }

        for raw in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let field = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch field {
            case "p":
                flush()
                fd = ""
                guard let pid = Int32(value) else { current = nil; continue }
                current = LockingProcess(pid: pid, name: "", executablePath: nil, uid: 0, user: "", startTime: 0, files: [])
            case "c": current?.name = value
            case "u":
                current?.uid = UInt32(value) ?? 0
                if current?.user.isEmpty == true { current?.user = value }
            case "L": current?.user = value
            case "f": fd = value
            case "t": break
            case "n":
                guard current != nil, value.hasPrefix("/") else { continue }
                // lsof may append " (deleted)" or similar notes after the path.
                let path = value.hasSuffix(")") ? String(value[..<(value.range(of: " (")?.lowerBound ?? value.endIndex)]) : value
                // The first "txt" entry is the program itself.
                if fd == "txt", current?.executablePath == nil { current?.executablePath = path }
                guard matcher.matches(path) else { continue }
                let file: LockedFile
                switch fd {
                case "cwd": file = LockedFile(path: path, kind: .workingDirectory)
                case "rtd": file = LockedFile(path: path, kind: .rootDirectory)
                case "txt": file = LockedFile(path: path, kind: .executable)
                default:
                    let digits = fd.prefix { $0.isNumber }
                    file = LockedFile(path: path, kind: .openFile, descriptor: Int32(digits))
                }
                current?.files.append(file)
            default:
                break
            }
        }
        flush()
        return FileLocksmithScanner.sort(order.compactMap { result[$0] })
    }
}
