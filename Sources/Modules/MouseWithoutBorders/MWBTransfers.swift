import AppKit
import CryptoKit
import MacToysCore
import Observation

/// File transfers between Macs: 256 KiB chunks, the next one sent when the network stack has
/// taken the previous (so memory stays flat), SHA-256 checked on arrival.
@MainActor
@Observable
final class MWBTransferCenter {
    struct Transfer: Identifiable, Equatable {
        enum Direction: Equatable { case incoming, outgoing }
        enum State: Equatable {
            case running
            case done
            case failed(String)
            case cancelled
        }

        let id = UUID()
        let transferID: UInt32
        let peer: UUID
        let peerName: String
        let name: String
        let size: UInt64
        var done: UInt64 = 0
        let direction: Direction
        let purpose: MWBFileStart.Purpose
        var state: State = .running
        var savedURL: URL?

        var fraction: Double { size == 0 ? 1 : min(1, Double(done) / Double(size)) }
    }

    private(set) var transfers: [Transfer] = []
    var isBusy: Bool { transfers.contains { $0.state == .running } }

    /// Sends a message to a peer; false when it isn't connected.
    @ObservationIgnored var transmit: (MWBMessage, UUID, (() -> Void)?) -> Bool = { _, _, _ in false }
    @ObservationIgnored var maxBytes: UInt64 = 100_000_000
    /// Where files sent with "send" (drag across, Send File…) are saved.
    @ObservationIgnored var downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    /// Where files copied to the clipboard on another Mac land.
    @ObservationIgnored var clipboardFolder: URL = Paths.data(for: "mwb").appendingPathComponent("Clipboard", isDirectory: true)
    @ObservationIgnored var onReceived: ((Transfer, URL) -> Void)?
    @ObservationIgnored var onFailed: ((Transfer) -> Void)?

    private struct Outgoing {
        var handle: FileHandle
        var hasher = SHA256()
        var sent: UInt64 = 0
    }

    private struct Incoming {
        var handle: FileHandle
        var temp: URL
        var hasher = SHA256()
        var received: UInt64 = 0
        var lastActivity = Date()
    }

    @ObservationIgnored private var outgoing: [UInt32: Outgoing] = [:]
    @ObservationIgnored private var incoming: [String: Incoming] = [:]
    @ObservationIgnored private var nextID = UInt32.random(in: 1...0x7FFF_FFFF)
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private let log = Log.for("mwb")

    // MARK: - Sending

    /// Starts sending a regular file. Returns false (and records why) when it can't.
    @discardableResult
    func send(file url: URL, to peer: UUID, peerName: String, purpose: MWBFileStart.Purpose) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let size = UInt64(values?.fileSize ?? 0)
        var t = Transfer(transferID: nextID, peer: peer, peerName: peerName, name: url.lastPathComponent, size: size,
                         direction: .outgoing, purpose: purpose)
        nextID &+= 1
        guard values?.isRegularFile == true else {
            t.state = .failed("Only single files can be sent (zip folders first).")
            record(t)
            return false
        }
        guard size <= maxBytes else {
            t.state = .failed("Larger than the \(maxBytes / 1_000_000) MB limit.")
            record(t)
            return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            t.state = .failed("Couldn’t read the file.")
            record(t)
            return false
        }
        record(t)
        outgoing[t.transferID] = Outgoing(handle: handle)
        let started = transmit(.fileStart(MWBFileStart(transferID: t.transferID, name: t.name, size: size, purpose: purpose)), peer, nil)
        guard started else {
            finishOutgoing(t.transferID, state: .failed("Not connected."))
            return false
        }
        pump(t.transferID)
        return true
    }

    func cancel(_ id: UUID) {
        guard let t = transfers.first(where: { $0.id == id }), t.state == .running else { return }
        _ = transmit(.fileCancel(t.transferID), t.peer, nil)
        if t.direction == .outgoing { finishOutgoing(t.transferID, state: .cancelled) }
        else { finishIncoming(key(t.peer, t.transferID), state: .cancelled) }
    }

    private func pump(_ tid: UInt32) {
        guard var o = outgoing[tid], let t = transfers.first(where: { $0.transferID == tid && $0.direction == .outgoing }),
              t.state == .running else { return }
        let chunk: Data
        do { chunk = try o.handle.read(upToCount: MWBProtocol.fileChunkSize) ?? Data() } catch {
            finishOutgoing(tid, state: .failed("Read error: \(error.localizedDescription)"))
            return
        }
        if chunk.isEmpty {
            let digest = Data(o.hasher.finalize())
            _ = transmit(.fileEnd(MWBFileEnd(transferID: tid, sha256: digest)), t.peer, nil)
            finishOutgoing(tid, state: o.sent == t.size ? .done : .failed("The file changed while sending."))
            return
        }
        o.hasher.update(data: chunk)
        let offset = o.sent
        o.sent += UInt64(chunk.count)
        outgoing[tid] = o
        update(tid, .outgoing) { $0.done = o.sent }
        let ok = transmit(.fileChunk(MWBFileChunk(transferID: tid, offset: offset, data: chunk)), t.peer) { [weak self] in
            self?.pump(tid)
        }
        if !ok { finishOutgoing(tid, state: .failed("Disconnected.")) }
    }

    private func finishOutgoing(_ tid: UInt32, state: Transfer.State) {
        if let o = outgoing.removeValue(forKey: tid) { try? o.handle.close() }
        update(tid, .outgoing) { $0.state = state }
        if case .failed = state, let t = transfers.first(where: { $0.transferID == tid && $0.direction == .outgoing }) {
            onFailed?(t)
        }
    }

    // MARK: - Receiving

    /// Handles transfer messages; returns false for other messages.
    func handle(_ message: MWBMessage, from peer: UUID, peerName: String) -> Bool {
        switch message {
        case .fileStart(let f): start(f, from: peer, peerName: peerName)
        case .fileChunk(let c): chunk(c, from: peer)
        case .fileEnd(let e): end(e, from: peer)
        case .fileCancel(let id):
            if incoming[key(peer, id)] != nil { finishIncoming(key(peer, id), state: .cancelled) }
            if outgoing[id] != nil { finishOutgoing(id, state: .cancelled) }
        default: return false
        }
        return true
    }

    /// A safe file name: the last path component, no separators or leading dots.
    nonisolated static func sanitize(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
        n = n.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        n = n.filter { !$0.isNewline && $0 != "\0" }
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "File" : String(n.prefix(200))
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext` … when taken.
    nonisolated static func uniqueURL(for name: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func key(_ peer: UUID, _ id: UInt32) -> String { "\(peer.uuidString)-\(id)" }

    private func start(_ f: MWBFileStart, from peer: UUID, peerName: String) {
        var t = Transfer(transferID: f.transferID, peer: peer, peerName: peerName, name: Self.sanitize(f.name), size: f.size,
                         direction: .incoming, purpose: f.purpose)
        guard f.size <= maxBytes else {
            t.state = .failed("Larger than the \(maxBytes / 1_000_000) MB limit.")
            record(t)
            _ = transmit(.fileCancel(f.transferID), peer, nil)
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacToys-MWB-\(UUID().uuidString).part")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else {
            t.state = .failed("Couldn’t create a temporary file.")
            record(t)
            _ = transmit(.fileCancel(f.transferID), peer, nil)
            return
        }
        record(t)
        incoming[key(peer, f.transferID)] = Incoming(handle: handle, temp: temp)
        startWatchdog()
    }

    private func chunk(_ c: MWBFileChunk, from peer: UUID) {
        let k = key(peer, c.transferID)
        guard var i = incoming[k], let t = transfers.first(where: { $0.transferID == c.transferID && $0.peer == peer && $0.direction == .incoming }) else { return }
        guard c.offset == i.received, i.received + UInt64(c.data.count) <= t.size else {
            _ = transmit(.fileCancel(c.transferID), peer, nil)
            finishIncoming(k, state: .failed("Out-of-order data."))
            return
        }
        do { try i.handle.write(contentsOf: c.data) } catch {
            _ = transmit(.fileCancel(c.transferID), peer, nil)
            finishIncoming(k, state: .failed("Write error: \(error.localizedDescription)"))
            return
        }
        i.hasher.update(data: c.data)
        i.received += UInt64(c.data.count)
        i.lastActivity = Date()
        incoming[k] = i
        update(c.transferID, .incoming, peer: peer) { $0.done = i.received }
    }

    private func end(_ e: MWBFileEnd, from peer: UUID) {
        let k = key(peer, e.transferID)
        guard let i = incoming[k], let t = transfers.first(where: { $0.transferID == e.transferID && $0.peer == peer && $0.direction == .incoming }) else { return }
        guard i.received == t.size, Data(i.hasher.finalize()) == e.sha256 else {
            finishIncoming(k, state: .failed("The file arrived damaged."))
            return
        }
        try? i.handle.close()
        let folder = t.purpose == .clipboard ? clipboardFolder : downloads
        do {
            if t.purpose == .clipboard {
                // Only the latest clipboard file is kept.
                try? FileManager.default.removeItem(at: clipboardFolder)
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = Self.uniqueURL(for: t.name, in: folder) { FileManager.default.fileExists(atPath: $0.path) }
            try FileManager.default.moveItem(at: i.temp, to: dest)
            incoming[k] = nil
            update(e.transferID, .incoming, peer: peer) {
                $0.state = .done
                $0.savedURL = dest
            }
            if let done = transfers.first(where: { $0.transferID == e.transferID && $0.peer == peer && $0.direction == .incoming }) {
                onReceived?(done, dest)
            }
        } catch {
            finishIncoming(k, state: .failed("Couldn’t save: \(error.localizedDescription)"))
        }
    }

    private func finishIncoming(_ k: String, state: Transfer.State) {
        guard let i = incoming.removeValue(forKey: k) else { return }
        try? i.handle.close()
        try? FileManager.default.removeItem(at: i.temp)
        if let index = transfers.firstIndex(where: { key($0.peer, $0.transferID) == k && $0.direction == .incoming && $0.state == .running }) {
            transfers[index].state = state
            if case .failed = state { onFailed?(transfers[index]) }
        }
    }

    /// Fails every running transfer with a machine that went away.
    func peerDisconnected(_ peer: UUID) {
        for t in transfers where t.peer == peer && t.state == .running {
            if t.direction == .outgoing { finishOutgoing(t.transferID, state: .failed("Disconnected.")) }
            else { finishIncoming(key(peer, t.transferID), state: .failed("Disconnected.")) }
        }
    }

    func cancelAll() {
        for t in transfers where t.state == .running { cancel(t.id) }
    }

    func clearFinished() { transfers.removeAll { $0.state != .running } }

    private func record(_ t: Transfer) {
        transfers.insert(t, at: 0)
        if transfers.count > 30 {
            let excess = transfers.enumerated().filter { $0.offset >= 30 && $0.element.state != .running }.map(\.element.id)
            transfers.removeAll { excess.contains($0.id) }
        }
    }

    private func update(_ tid: UInt32, _ direction: Transfer.Direction, peer: UUID? = nil, _ change: (inout Transfer) -> Void) {
        guard let i = transfers.firstIndex(where: {
            $0.transferID == tid && $0.direction == direction && (peer == nil || $0.peer == peer) && $0.state == .running
        }) else { return }
        change(&transfers[i])
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let stale = self.incoming.filter { Date().timeIntervalSince($0.value.lastActivity) > 60 }.map(\.key)
                for k in stale { self.finishIncoming(k, state: .failed("Timed out.")) }
                if self.incoming.isEmpty {
                    self.watchdog?.invalidate()
                    self.watchdog = nil
                }
            }
        }
    }
}

/// Watches this Mac's clipboard and writes what other Macs copied.
@MainActor
final class MWBClipboardSync {
    enum Payload: Equatable {
        case text(String)
        case image(Data)
        case file(URL)
    }

    var onLocalChange: ((Payload) -> Void)?
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var ownChange = -1
    private let log = Log.for("mwb")

    static let concealedTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]

    func start() {
        guard timer == nil else { return }
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func applyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        markOwn()
    }

    func applyImage(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        if let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        markOwn()
    }

    func applyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        if ["png", "jpg", "jpeg", "heic", "tiff", "gif"].contains(url.pathExtension.lowercased()),
           let data = try? Data(contentsOf: url), let image = NSImage(data: data), let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
        markOwn()
    }

    private func markOwn() {
        ownChange = NSPasteboard.general.changeCount
        lastChange = ownChange
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard pb.changeCount != ownChange else { return }
        if let types = pb.types, types.contains(where: Self.concealedTypes.contains) { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                onLocalChange?(.file(urls[0]))
            } else {
                log.info("Clipboard has \(urls.count) items or a folder; only single files are shared")
            }
            return
        }
        if pb.availableType(from: [.png, .tiff]) != nil {
            if let png = pb.data(forType: .png) {
                onLocalChange?(.image(png))
                return
            }
            if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                onLocalChange?(.image(png))
                return
            }
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            onLocalChange?(.text(text))
        }
    }
}
