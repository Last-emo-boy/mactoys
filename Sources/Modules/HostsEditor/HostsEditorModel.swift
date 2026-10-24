import AppKit
import Foundation
import MacToysCore
import Observation

struct HostsSettings: Codable, Equatable {
    var showWarningOnStart = true
    var placement: HostsDocument.Placement = .top
    var loopbackDuplicates = false
    var backupsEnabled = true
    var retention: HostsBackups.Retention = .ageAndCount
    var backupCount = 5
    var backupDays = 15
    var pingOnOpen = true
}

enum PingState: Equatable {
    case pending
    case reply(Double)
    case noReply
    case skipped
}

/// The editor's document, filters, ping results and save pipeline.
@MainActor
@Observable
final class HostsEditorModel {
    struct Message: Equatable {
        var kind: InfoKind
        var title: String
        var text: String
    }

    let path: String
    let settings: Persisted<HostsSettings>
    private let log = Log.for("hosts")

    var document = HostsDocument(lines: [], lineEnding: "\n", hasTrailingNewline: true, hasBOM: false)
    /// What's on disk, to tell unsaved edits apart.
    private(set) var diskText = ""
    var loaded = false
    var pings: [String: PingState] = [:]
    var selection: Set<UUID> = []
    var message: Message?
    var saving = false
    var changedOnDisk = false

    // Filters
    var searchText = ""
    var addressFilter = ""
    var hostFilter = ""
    var commentFilter = ""
    var activeOnly = false
    var duplicatesOnly = false

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?

    init(path: String = "/private/etc/hosts", settings: Persisted<HostsSettings>) {
        self.path = path
        self.settings = settings
    }

    var isDirty: Bool { loaded && document.serialize() != diskText }

    var duplicates: [UUID: Set<String>] {
        HostsValidator.duplicates(document.entries, loopbackDuplicates: settings.value.loopbackDuplicates)
    }

    var hasFilters: Bool {
        !addressFilter.isEmpty || !hostFilter.isEmpty || !commentFilter.isEmpty || activeOnly || duplicatesOnly
    }

    func clearFilters() {
        addressFilter = ""; hostFilter = ""; commentFilter = ""; activeOnly = false; duplicatesOnly = false
    }

    var visibleEntries: [HostsEntry] {
        let dupes = duplicates
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return document.entries.filter { e in
            if activeOnly && !e.active { return false }
            if duplicatesOnly && dupes[e.id] == nil { return false }
            if !addressFilter.isEmpty && !e.address.localizedCaseInsensitiveContains(addressFilter) { return false }
            if !hostFilter.isEmpty && !e.hostsText.localizedCaseInsensitiveContains(hostFilter) { return false }
            if !commentFilter.isEmpty && !e.comment.localizedCaseInsensitiveContains(commentFilter) { return false }
            if !q.isEmpty && !(e.address.lowercased().contains(q) || e.hostsText.lowercased().contains(q) || e.comment.lowercased().contains(q)) {
                return false
            }
            return true
        }
    }

    // MARK: - Loading

    func load() {
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            diskText = text
            document = HostsDocument.parse(text)
            loaded = true
            changedOnDisk = false
        } catch {
            message = Message(kind: .error, title: "Couldn't read \(path)", text: error.localizedDescription)
            log.error("read hosts: \(error.localizedDescription, privacy: .public)")
        }
        if settings.value.pingOnOpen { pingAll() }
    }

    /// Re-reads the file; with unsaved edits only flags the change.
    func diskChanged() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), text != diskText else { return }
        if isDirty { changedOnDisk = true } else { load() }
    }

    func startWatching() {
        stopWatching()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.watcher else { return }
                let replaced = !source.data.intersection([.rename, .delete]).isEmpty
                self.diskChanged()
                // Editors that replace the file need a fresh descriptor.
                if replaced {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        MainActor.assumeIsolated { self?.startWatching() }
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - Ping

    func pingAll() {
        let addresses = Array(Set(document.entries.map(\.address)))
        for a in addresses { pings[a] = .pending }
        Task { [weak self] in
            await withTaskGroup(of: (String, PingState).self) { group in
                var iterator = addresses.makeIterator()
                for _ in 0..<min(6, addresses.count) {
                    if let a = iterator.next() { group.addTask { (a, await Pinger.ping(a)) } }
                }
                for await (address, state) in group {
                    self?.pings[address] = state
                    if let a = iterator.next() { group.addTask { (a, await Pinger.ping(a)) } }
                }
            }
        }
    }

    func ping(_ address: String) {
        pings[address] = .pending
        Task { [weak self] in
            let state = await Pinger.ping(address)
            self?.pings[address] = state
        }
    }

    // MARK: - Editing

    func entry(_ id: UUID) -> HostsEntry? { document.entries.first { $0.id == id } }

    func add(_ entry: HostsEntry) {
        document.add(entry, placement: settings.value.placement)
        selection = [entry.id]
        ping(entry.address)
    }

    func update(_ entry: HostsEntry) {
        let oldAddress = self.entry(entry.id)?.address
        document.update(entry)
        if oldAddress != entry.address { ping(entry.address) }
    }

    func setActive(_ id: UUID, _ on: Bool) { document.setActive(id, on) }

    func delete(_ ids: Set<UUID>) {
        for id in ids { document.remove(id) }
        selection.subtract(ids)
    }

    func duplicate(_ id: UUID) {
        if let copy = document.duplicate(id) { selection = [copy.id] }
    }

    func revert() {
        document = HostsDocument.parse(diskText)
        changedOnDisk = false
    }

    /// Edited entries that would write an invalid line.
    var blockingIssues: [(HostsEntry, [HostsValidator.Issue])] {
        document.entries.filter { $0.original == nil }.compactMap { e in
            let errors = HostsValidator.issues(e).filter(\.isError)
            return errors.isEmpty ? nil : (e, errors)
        }
    }

    // MARK: - Saving

    var backupDirectory: URL { Paths.data(for: "Hosts") }

    /// Writes a temp file, backs up the current hosts file, copies the new one over it as root
    /// (one administrator prompt), then flushes the DNS cache.
    func save() {
        guard !saving, isDirty else { return }
        if let (entry, issues) = blockingIssues.first {
            message = Message(kind: .error, title: "Fix \(entry.address) \(entry.hostsText) first",
                              text: issues.map(\.message).joined(separator: " · "))
            return
        }
        saving = true
        let text = document.serialize()
        let path = self.path
        let s = settings.value
        let backups = backupDirectory
        Task.detached {
            let result = HostsWriter.write(text, to: path, settings: s, backups: backups)
            await MainActor.run { self.finishSave(result, text: text) }
        }
    }

    private func finishSave(_ result: Result<String?, HostsWriter.Failure>, text: String) {
        saving = false
        switch result {
        case .success(let backup):
            diskText = (try? String(contentsOfFile: path, encoding: .utf8)) ?? text
            let reread = HostsDocument.parse(diskText)
            // Keep ids (and with them selection and pings) for unchanged positions.
            document = Self.carryIDs(from: document, to: reread)
            changedOnDisk = false
            message = Message(kind: .success, title: "Saved", text: backup.map { "DNS cache flushed. Backup: \($0)" } ?? "DNS cache flushed.")
            log.info("hosts saved")
        case .failure(let f):
            message = Message(kind: f.cancelled ? .info : .error, title: f.cancelled ? "Not saved" : "Failed to save hosts file", text: f.message)
            log.error("save hosts: \(f.message, privacy: .public)")
        }
    }

    static func carryIDs(from old: HostsDocument, to new: HostsDocument) -> HostsDocument {
        var out = new
        let oldEntries = old.entries
        var n = 0
        for i in out.lines.indices {
            guard case .entry(var e) = out.lines[i] else { continue }
            if n < oldEntries.count, oldEntries[n].address == e.address, oldEntries[n].hosts == e.hosts { e.id = oldEntries[n].id }
            out.lines[i] = .entry(e)
            n += 1
        }
        return out
    }
}

/// Runs `ping` with a hard timeout.
enum Pinger {
    static func ping(_ address: String) async -> PingState {
        // Unspecified addresses (used to block names) aren't reachable hosts.
        guard HostsValidator.isValidAddress(address), !["0.0.0.0", "::", "0:0:0:0:0:0:0:0"].contains(address) else { return .skipped }
        let v6 = HostsValidator.isValidIPv6(address)
        let output = await run(v6 ? "/sbin/ping6" : "/sbin/ping",
                               v6 ? ["-c", "1", "-n", address] : ["-c", "1", "-t", "1", "-n", address], timeout: 2.5)
        return PingParser.milliseconds(output ?? "").map { .reply($0) } ?? .noReply
    }

    private static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do { try process.run() } catch {
                continuation.resume(returning: nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// The privileged write, off the main thread.
enum HostsWriter {
    struct Failure: Error {
        var message: String
        var cancelled = false
    }

    /// Returns the backup's file name, if one was written.
    static func write(_ text: String, to path: String, settings: HostsSettings, backups: URL) -> Result<String?, Failure> {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("mactoys-hosts-\(UUID().uuidString)")
        do {
            try Data(text.utf8).write(to: temp, options: .atomic)
        } catch {
            return .failure(Failure(message: "Couldn't write a temporary file: \(error.localizedDescription)"))
        }
        defer { try? fm.removeItem(at: temp) }

        var backupName: String?
        if settings.backupsEnabled {
            do {
                try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                let name = HostsBackups.name(for: Date())
                let dest = backups.appendingPathComponent(name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: URL(fileURLWithPath: path), to: dest)
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
                backupName = name
            } catch {
                return .failure(Failure(message: "Couldn't back up the hosts file, so it wasn't changed: \(error.localizedDescription)"))
            }
        }

        // `cat >` keeps the file's owner, mode and inode; then flush the resolver caches.
        let command = "/bin/cat \(Shell.quote(temp.path)) > \(Shell.quote(path)) && /usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder 2>/dev/null; true"
        do {
            _ = try Privileged.run(command, prompt: "MacToys wants to save changes to the hosts file.")
        } catch let error as AppleScript.Failure {
            return .failure(Failure(message: error.code == -128 ? "Saving was cancelled." : error.message, cancelled: error.code == -128))
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }

        if settings.backupsEnabled, let files = try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let dated = files.map { ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for name in HostsBackups.toDelete(dated, retention: settings.retention, keep: settings.backupCount,
                                              days: settings.backupDays, now: Date()) {
                try? fm.removeItem(at: backups.appendingPathComponent(name))
            }
        }
        return .success(backupName)
    }
}
