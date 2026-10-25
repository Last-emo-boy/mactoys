import Foundation
import MacToysCore
import Network

/// Connection state shown per machine (the colors follow the PowerToys status table).
public enum MWBStatus: String, Codable, Sendable {
    case notConnected, resolving, connecting, handshaking, connected, error, closed, invalidKey, timeout, sendError

    public var title: String {
        switch self {
        case .notConnected: String(localized: "Not connected", comment: "Mouse Without Borders connection state")
        case .resolving: String(localized: "Resolving", comment: "Connection state: looking up the other Mac's address")
        case .connecting: String(localized: "Connecting", comment: "Mouse Without Borders connection state")
        case .handshaking: String(localized: "Handshaking", comment: "Connection state: checking the security key with the other Mac")
        case .connected: String(localized: "Connected", comment: "Mouse Without Borders connection state")
        case .error: String(localized: "Error", comment: "Mouse Without Borders connection state: the connection failed")
        case .closed: String(localized: "Closed", comment: "Mouse Without Borders connection state: the connection was closed")
        case .invalidKey: String(localized: "Invalid security key", comment: "Mouse Without Borders connection state")
        case .timeout: String(localized: "Timed out", comment: "Mouse Without Borders connection state")
        case .sendError: String(localized: "Send error", comment: "Connection state: sending data to the other Mac failed")
        }
    }

    /// `#RRGGBB`.
    public var colorHex: String {
        switch self {
        case .notConnected: "#717171"
        case .resolving: "#E6C200"
        case .connecting: "#FFA500"
        case .handshaking: "#3478F6"
        case .connected: "#30B050"
        case .error: "#FF3B30"
        case .closed: "#800080"
        case .invalidKey: "#A52A2A"
        case .timeout: "#FF8FA3"
        case .sendError: "#800000"
        }
    }

    init(_ failure: MWBFailure?) {
        switch failure {
        case nil, .closedByPeer: self = .notConnected
        case .invalidKey: self = .invalidKey
        case .timeout: self = .timeout
        case .network: self = .error
        case .protocolError, .incompatibleVersion: self = .error
        case .selfConnection, .duplicate, .notSameSubnet: self = .closed
        }
    }
}

/// One TCP connection to another Mac: handshake, then sealed messages both ways.
/// Runs on the main queue. Unauthenticated peers never get past the handshake.
@MainActor
final class MWBPeerConnection {
    enum Phase: Equatable { case connecting, handshaking, established, closed }

    let role: Handshake.Role
    let connection: NWConnection
    private var handshake: Handshake
    private var crypto: SessionCrypto?
    private var decoder = FrameDecoder()
    private(set) var phase: Phase = .connecting
    private(set) var failure: MWBFailure?
    private var heartbeat: Timer?
    private var lastHeard = Date()
    private var deadline: DispatchWorkItem?
    private let log = Log.for("mwb")

    /// The machine a Bonjour result said this is (outbound connections).
    var expectedMachineID: UUID?
    /// The manual host string this connection was made for.
    var manualHost: String?
    /// Checked against the local interfaces once the connection is up.
    var sameSubnetOnly = false
    var heartbeatInterval: TimeInterval = 2
    var silenceTimeout: TimeInterval = 9

    var onEstablished: ((MWBPeerConnection) -> Void)?
    var onMessage: ((MWBPeerConnection, MWBMessage) -> Void)?
    var onClosed: ((MWBPeerConnection, MWBFailure?) -> Void)?

    init(connection: NWConnection, role: Handshake.Role, local: MWBHello, secret: String) {
        self.connection = connection
        self.role = role
        handshake = Handshake(role: role, local: local, secret: secret)
    }

    var peer: MWBHello? { handshake.peer }

    /// The other side's IP address, when known.
    var remoteHost: String? {
        let endpoint = connection.currentPath?.remoteEndpoint ?? connection.endpoint
        if case .hostPort(let host, _) = endpoint {
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return nil
            }
        }
        return nil
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state) }
        }
        connection.start(queue: .main)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase != .established else { return }
                self.close(.timeout)
            }
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// Sends a message (sealed). The completion runs when the network stack has taken the bytes,
    /// which file transfers use for flow control.
    func send(_ message: MWBMessage, completion: (() -> Void)? = nil) {
        guard phase == .established, var c = crypto else { completion?(); return }
        let sealed: Data
        do { sealed = try c.seal(message.encoded()) } catch {
            log.error("Seal failed: \(String(describing: error), privacy: .public)")
            completion?()
            return
        }
        crypto = c
        write(MWBFrame(kind: .sealed, payload: sealed), completion: completion)
    }

    func close(_ reason: MWBFailure?) {
        guard phase != .closed else { return }
        phase = .closed
        failure = reason
        heartbeat?.invalidate()
        heartbeat = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(self, reason)
    }

    // MARK: - Internals

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard phase == .connecting else { return }
            if sameSubnetOnly, let host = remoteHost, let bytes = Subnet.parse(host),
               !Subnet.isLocal(bytes, interfaces: Subnet.localInterfaces()) {
                close(.notSameSubnet)
                return
            }
            phase = .handshaking
            write(handshake.start(), completion: nil)
            receive()
        case .failed(let error):
            close(.network(error.localizedDescription))
        case .waiting(let error):
            // Network.framework would keep waiting; the registry retries on its own schedule.
            close(.network(error.localizedDescription))
        case .cancelled:
            if phase != .closed { close(.closedByPeer) }
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.phase != .closed else { return }
                if let data, !data.isEmpty { self.ingest(data) }
                guard self.phase != .closed else { return }
                if let error {
                    self.close(.network(error.localizedDescription))
                } else if isComplete {
                    self.close(.closedByPeer)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func ingest(_ data: Data) {
        lastHeard = Date()
        decoder.append(data)
        while phase != .closed {
            let frame: MWBFrame?
            do { frame = try decoder.next() } catch {
                close(.protocolError(String(describing: error)))
                return
            }
            guard let frame else { return }
            handle(frame)
        }
    }

    private func handle(_ frame: MWBFrame) {
        switch phase {
        case .handshaking:
            for out in handshake.receive(frame) { write(out, completion: nil) }
            switch handshake.state {
            case .established:
                crypto = handshake.crypto
                phase = .established
                deadline?.cancel()
                deadline = nil
                startHeartbeat()
                onEstablished?(self)
            case .failed(let f):
                close(f)
            default:
                break
            }
        case .established:
            guard frame.kind == .sealed, var c = crypto else {
                close(.protocolError("plaintext after handshake"))
                return
            }
            do {
                let plain = try c.open(frame.payload)
                crypto = c
                let message = try MWBMessage.decode(plain)
                if message == .heartbeat { return }
                onMessage?(self, message)
            } catch let e as MWBCryptoError {
                close(e == .replayed ? .protocolError("replayed frame") : .invalidKey)
            } catch {
                close(.protocolError(String(describing: error)))
            }
        case .connecting, .closed:
            break
        }
    }

    private func write(_ frame: MWBFrame, completion: (() -> Void)?) {
        connection.send(content: frame.encoded(), completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                if let error, let self, self.phase != .closed {
                    self.log.error("Send failed: \(error.localizedDescription, privacy: .public)")
                    self.close(.network(error.localizedDescription))
                }
                completion?()
            }
        })
    }

    private func startHeartbeat() {
        heartbeat = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .established else { return }
                if Date().timeIntervalSince(self.lastHeard) > self.silenceTimeout {
                    self.close(.timeout)
                    return
                }
                self.send(.heartbeat)
            }
        }
    }
}

/// Every connection of this Mac: the listener (advertised over Bonjour), the browser, manual
/// hosts, and one authenticated connection per machine.
@MainActor
final class MWBNetwork {
    struct Identity: Equatable {
        var machineID: UUID
        var name: String
    }

    var identity: Identity
    var secret: String?
    var sameSubnetOnly = false
    var manualHosts: [String] = []
    /// Bonjour advertising and browsing (off in tests).
    var useBonjour = true
    var preferredPort: UInt16 = MWBProtocol.defaultPort

    private(set) var isRunning = false
    private(set) var listeningPort: UInt16?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: MWBPeerConnection] = [:]
    private(set) var peers: [UUID: MWBPeerConnection] = [:]
    private(set) var names: [UUID: String] = [:]
    private(set) var status: [UUID: MWBStatus] = [:]
    private(set) var hostStatus: [String: MWBStatus] = [:]
    private var discovered: [UUID: NWEndpoint] = [:]
    private var retryAfter: [String: Date] = [:]
    private var retryTimer: Timer?
    private let log = Log.for("mwb")

    var onConnected: ((MWBHello) -> Void)?
    var onDisconnected: ((UUID, MWBFailure?) -> Void)?
    var onMessage: ((UUID, MWBMessage) -> Void)?
    var onChange: (() -> Void)?

    init(identity: Identity) { self.identity = identity }

    var connectedIDs: [UUID] { Array(peers.keys) }

    func isConnected(_ id: UUID) -> Bool { peers[id] != nil }

    func address(of id: UUID) -> String? { peers[id]?.remoteHost }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startListener(port: preferredPort)
        if useBonjour { startBrowser() }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.connectEverything() }
        }
        connectEverything()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        retryTimer?.invalidate()
        retryTimer = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        listeningPort = nil
        for c in connections.values {
            c.onClosed = nil
            c.close(nil)
        }
        let ids = Array(peers.keys)
        connections = [:]
        peers = [:]
        discovered = [:]
        retryAfter = [:]
        for id in ids {
            status[id] = .notConnected
            onDisconnected?(id, nil)
        }
        hostStatus = hostStatus.mapValues { _ in .notConnected }
        onChange?()
    }

    /// Drops every connection and connects again (the Reconnect shortcut and button).
    func reconnect() {
        let wasRunning = isRunning
        stop()
        if wasRunning { start() }
    }

    @discardableResult
    func send(_ message: MWBMessage, to id: UUID, completion: (() -> Void)? = nil) -> Bool {
        guard let c = peers[id] else { completion?(); return false }
        c.send(message, completion: completion)
        return true
    }

    func broadcast(_ message: MWBMessage) {
        for c in peers.values { c.send(message) }
    }

    /// Connects to a host typed by the user (`192.168.1.20`, `studio.local`, `[fe80::1%en0]:15101`).
    func connect(host: String) {
        guard let endpoint = Self.endpoint(for: host) else {
            hostStatus[host] = .error
            onChange?()
            return
        }
        retryAfter[host] = nil
        open(to: endpoint, expected: nil, manualHost: host)
    }

    nonisolated static func endpoint(for text: String) -> NWEndpoint? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var port = MWBProtocol.defaultPort
        if s.hasPrefix("[") , let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { port = p }
            s = host
        } else if s.filter({ $0 == ":" }).count == 1, let colon = s.lastIndex(of: ":"), let p = UInt16(s[s.index(after: colon)...]) {
            port = p
            s = String(s[..<colon])
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(s), port: nwPort)
    }

    // MARK: - Listener and browser

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = false
        return params
    }

    private func startListener(port: UInt16) {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener: NWListener
        do { listener = try NWListener(using: Self.parameters(), on: nwPort) } catch {
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            if port != 0 { startListener(port: 0) }
            return
        }
        if useBonjour {
            let txt = NWTXTRecord(["id": identity.machineID.uuidString, "v": String(MWBProtocol.version)])
            listener.service = NWListener.Service(name: identity.name, type: MWBProtocol.serviceType, domain: nil, txtRecord: txt)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.listeningPort = listener.port?.rawValue
                    self.onChange?()
                case .failed(let error):
                    self.log.error("Listener: \(error.localizedDescription, privacy: .public)")
                    listener.cancel()
                    self.listener = nil
                    // The port is taken: listen on any port (Bonjour still finds us).
                    if self.isRunning && port != 0 { self.startListener(port: 0) }
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MWBProtocol.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.browsed(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                MainActor.assumeIsolated { self?.log.error("Browser: \(error.localizedDescription, privacy: .public)") }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    private func browsed(_ results: Set<NWBrowser.Result>) {
        var seen: [UUID: NWEndpoint] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let raw = txt["id"], let id = UUID(uuidString: raw),
                  id != identity.machineID else { continue }
            seen[id] = r.endpoint
            if case .service(let name, _, _, _) = r.endpoint, names[id] == nil { names[id] = name }
            if status[id] == nil || status[id] == .notConnected { status[id] = .resolving }
        }
        discovered = seen
        connectEverything()
        onChange?()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard isRunning, let secret, connections.count < 16 else {
            connection.cancel()
            return
        }
        let c = MWBPeerConnection(connection: connection, role: .responder, local: hello(), secret: secret)
        track(c)
        c.start()
    }

    /// Connects to discovered machines and manual hosts that aren't connected yet.
    private func connectEverything() {
        guard isRunning, secret != nil else { return }
        let now = Date()
        for (id, endpoint) in discovered where peers[id] == nil {
            if connections.values.contains(where: { $0.expectedMachineID == id }) { continue }
            if let t = retryAfter[id.uuidString], t > now { continue }
            open(to: endpoint, expected: id, manualHost: nil)
        }
        for host in manualHosts {
            if connections.values.contains(where: { $0.manualHost == host }) { continue }
            if let t = retryAfter[host], t > now { continue }
            guard let endpoint = Self.endpoint(for: host) else { hostStatus[host] = .error; continue }
            open(to: endpoint, expected: nil, manualHost: host)
        }
    }

    private func open(to endpoint: NWEndpoint, expected: UUID?, manualHost: String?) {
        guard let secret else { return }
        let c = MWBPeerConnection(connection: NWConnection(to: endpoint, using: Self.parameters()), role: .initiator,
                                  local: hello(), secret: secret)
        c.expectedMachineID = expected
        c.manualHost = manualHost
        if let expected { status[expected] = .connecting }
        if let manualHost { hostStatus[manualHost] = .connecting }
        track(c)
        c.start()
        onChange?()
    }

    private func hello() -> MWBHello {
        Handshake.hello(machineID: identity.machineID, name: identity.name, listenPort: listeningPort ?? preferredPort)
    }

    private func track(_ c: MWBPeerConnection) {
        c.sameSubnetOnly = sameSubnetOnly
        connections[ObjectIdentifier(c)] = c
        c.onEstablished = { [weak self] c in self?.established(c) }
        c.onMessage = { [weak self] c, message in
            guard let self, let id = c.peer?.machineID, self.peers[id] === c else { return }
            self.onMessage?(id, message)
        }
        c.onClosed = { [weak self] c, failure in self?.closed(c, failure) }
    }

    private func established(_ c: MWBPeerConnection) {
        guard let hello = c.peer else { c.close(.protocolError("no hello")); return }
        let id = hello.machineID
        if let existing = peers[id], existing !== c {
            // Both sides connected to each other: keep the connection opened by the machine with
            // the smaller id, on both machines alike.
            let preferred = min(identity.machineID.uuidString, id.uuidString)
            func initiator(_ x: MWBPeerConnection) -> String { x.role == .initiator ? identity.machineID.uuidString : id.uuidString }
            if initiator(existing) == preferred {
                c.close(.duplicate)
                return
            }
            existing.onClosed = nil
            existing.close(.duplicate)
            connections[ObjectIdentifier(existing)] = nil
        }
        peers[id] = c
        names[id] = hello.name
        status[id] = .connected
        if let host = c.manualHost { hostStatus[host] = .connected }
        retryAfter[id.uuidString] = nil
        log.info("Connected to \(hello.name, privacy: .public)")
        onConnected?(hello)
        onChange?()
    }

    private func closed(_ c: MWBPeerConnection, _ failure: MWBFailure?) {
        connections[ObjectIdentifier(c)] = nil
        if failure == .duplicate { return }
        let st = MWBStatus(failure)
        let backoff: TimeInterval = failure == .invalidKey ? 30 : 5
        if let host = c.manualHost {
            hostStatus[host] = st
            retryAfter[host] = Date().addingTimeInterval(backoff)
        }
        if let id = c.peer?.machineID ?? c.expectedMachineID {
            retryAfter[id.uuidString] = Date().addingTimeInterval(backoff)
            if peers[id] === c {
                peers[id] = nil
                status[id] = st
                onDisconnected?(id, failure)
            } else if peers[id] == nil {
                status[id] = st
            }
        }
        if let failure, failure != .closedByPeer {
            log.notice("Connection closed: \(String(describing: failure), privacy: .public)")
        }
        onChange?()
    }
}
