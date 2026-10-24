import CoreGraphics
import Foundation
import Testing
@testable import MacToysCore
@testable import MouseWithoutBorders

private let idA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let idB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let key = "ABCDEFGHJKLMNPQR"

private func hello(_ id: UUID, _ name: String) -> MWBHello {
    Handshake.hello(machineID: id, name: name, listenPort: 15101)
}

@Suite struct MWBProtocolTests {
    static let samples: [MWBMessage] = [
        .hello(MWBHello(machineID: idA, name: "Studio — 工作室", nonce: Data(repeating: 7, count: 32), listenPort: 15101)),
        .authProof(Data(repeating: 1, count: 32)),
        .heartbeat,
        .machineInfo(MWBMachineInfo(name: "Air", displays: [CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                            CGRect(x: -1920, y: -200, width: 1920, height: 1080)])),
        .layout(MWBLayoutMessage(revision: 1_760_000_000.5, singleRow: false, wrap: true,
                                 slots: [MachineSlot(id: idA, name: "A"), nil, MachineSlot(id: idB, name: "B"), nil])),
        .enter(x: 10.5, y: -20),
        .leave,
        .releaseControl,
        .mouseMove(MWBMouseMove(x: 100, y: 200.25, dx: -3, dy: 4.5)),
        .mouseButton(MWBMouseButton(button: 1, down: true, clickCount: 2, x: 5, y: 6)),
        .scroll(MWBScroll(dy: -12.5, dx: 3, lineDy: -1, lineDx: 0, phase: 2, momentumPhase: 0, continuous: true)),
        .key(MWBKey(keyCode: 0x24, down: false, flags: 0x0010_0108, autorepeat: true)),
        .mediaKey(MWBMediaKey(code: 16, down: true, autorepeat: false)),
        .clipboardText("Hello 👋 world\nline 2"),
        .clipboardImage(Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])),
        .fileStart(MWBFileStart(transferID: 42, name: "report.pdf", size: 1_234_567, purpose: .send)),
        .fileChunk(MWBFileChunk(transferID: 42, offset: 262_144, data: Data(repeating: 0xAB, count: 1000))),
        .fileEnd(MWBFileEnd(transferID: 42, sha256: Data(repeating: 9, count: 32))),
        .fileCancel(42),
        .userActivity,
        .lockScreen,
    ]

    @Test func everyMessageRoundTrips() throws {
        for m in Self.samples {
            #expect(try MWBMessage.decode(m.encoded()) == m)
        }
        // Type codes are unique.
        #expect(Set(Self.samples.map(\.type)).count == Self.samples.count)
    }

    @Test func malformedMessagesAreRejected() {
        #expect(throws: MWBProtocolError.unknownMessage(99)) { try MWBMessage.decode(Data([99])) }
        #expect(throws: MWBProtocolError.truncated) { try MWBMessage.decode(Data([13, 0, 0])) }
        var trailing = MWBMessage.leave.encoded()
        trailing.append(0)
        #expect(throws: (any Error).self) { try MWBMessage.decode(trailing) }
        #expect(throws: (any Error).self) { try MWBMessage.decode(Data()) }
        // A bool that isn't 0 or 1.
        #expect(throws: (any Error).self) { try MWBMessage.decode(Data([17, 16, 2, 0])) }
    }

    @Test func framesSplitAcrossReadsAndPackedTogether() throws {
        let frames = Self.samples.map { MWBFrame(kind: .plain, payload: $0.encoded()) }
        let stream = frames.reduce(Data()) { $0 + $1.encoded() }
        // Byte by byte.
        var decoder = FrameDecoder()
        var out: [MWBFrame] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let f = try decoder.next() { out.append(f) }
        }
        #expect(out == frames)
        #expect(decoder.bufferedBytes == 0)
        // All at once.
        var whole = FrameDecoder()
        whole.append(stream)
        var count = 0
        while try whole.next() != nil { count += 1 }
        #expect(count == frames.count)
    }

    @Test func badFramesFailTheStream() {
        var big = FrameDecoder()
        big.append(Data([0x7F, 0xFF, 0xFF, 0xFF, 1, 0]))
        #expect(throws: MWBProtocolError.frameTooLarge(0x7FFF_FFFF)) { try big.next() }
        var version = FrameDecoder()
        version.append(Data([0, 0, 0, 3, 9, 0, 3]))
        #expect(throws: MWBProtocolError.unsupportedVersion(9)) { try version.next() }
        var kind = FrameDecoder()
        kind.append(Data([0, 0, 0, 3, MWBProtocol.version, 7, 3]))
        #expect(throws: MWBProtocolError.unknownFrameKind(7)) { try kind.next() }
        var short = FrameDecoder()
        short.append(Data([0, 0, 0, 1, 1]))
        #expect(throws: MWBProtocolError.truncated) { try short.next() }
        var partial = FrameDecoder()
        partial.append(Data([0, 0, 0, 10, MWBProtocol.version, 0]))
        let pending = try? partial.next()
        #expect(pending == nil)
        #expect(partial.bufferedBytes == 6)
    }
}

@Suite struct MWBCryptoTests {
    func pair(_ secretA: String = key, _ secretB: String = key) -> (SessionCrypto, SessionCrypto) {
        let n1 = Data(repeating: 1, count: 32), n2 = Data(repeating: 2, count: 32)
        return (SessionCrypto(secret: secretA, initiatorNonce: n1, responderNonce: n2, isInitiator: true),
                SessionCrypto(secret: secretB, initiatorNonce: n1, responderNonce: n2, isInitiator: false))
    }

    @Test func sealOpenRoundTripBothWays() throws {
        var (a, b) = pair()
        for i in 0..<5 {
            let m = MWBMessage.mouseMove(MWBMouseMove(x: Double(i), y: 2, dx: 1, dy: 1)).encoded()
            let ab = try b.open(a.seal(m))
            let ba = try a.open(b.seal(m))
            #expect(ab == m)
            #expect(ba == m)
        }
    }

    @Test func ciphertextHidesThePlaintext() throws {
        var (a, _) = pair()
        let text = Data("super secret clipboard".utf8)
        let sealed = try a.seal(text)
        #expect(sealed.range(of: text) == nil)
        #expect(sealed.count == 8 + text.count + 16)
    }

    @Test func wrongKeyTamperingReplayAndReflectionFail() throws {
        var (a, wrong) = pair(key, "ZZZZZZZZZZZZZZZZ")
        let m = Data("hello".utf8)
        #expect(throws: MWBCryptoError.authenticationFailed) { try wrong.open(a.seal(m)) }

        var (a2, b2) = pair()
        var sealed = try a2.seal(m)
        sealed[sealed.count - 1] ^= 0x01
        #expect(throws: MWBCryptoError.authenticationFailed) { try b2.open(sealed) }

        var (a3, b3) = pair()
        let first = try a3.seal(m)
        _ = try b3.open(first)
        #expect(throws: MWBCryptoError.replayed) { try b3.open(first) }
        // Skipping ahead is fine (TCP never reorders), going back is not.
        _ = try a3.seal(m)
        let third = try a3.seal(m)
        _ = try b3.open(third)

        // A frame sealed by A can't be fed back to A.
        var (a4, _) = pair()
        let own = try a4.seal(m)
        #expect(throws: MWBCryptoError.authenticationFailed) { try a4.open(own) }

        var (_, b5) = pair()
        #expect(throws: MWBCryptoError.malformed) { try b5.open(Data([1, 2, 3])) }
    }

    @Test func securityKeys() {
        let k = SecurityKey.generate()
        #expect(k.count == 16)
        #expect(k.allSatisfy { SecurityKey.alphabet.contains($0) })
        #expect(SecurityKey.generate() != k)
        #expect(SecurityKey.normalize("abcd-efgh jklm-npqr") == "ABCDEFGHJKLMNPQR")
        #expect(SecurityKey.normalize("short") == nil)
        #expect(SecurityKey.normalize("ABCDEFGHJKLMNPQ!") == nil)
        #expect(SecurityKey.formatted("ABCDEFGHJKLMNPQR") == "ABCD-EFGH-JKLM-NPQR")
    }
}

@Suite struct MWBHandshakeTests {
    /// Runs two handshakes against each other, delivering frames until both settle.
    func run(_ a: inout Handshake, _ b: inout Handshake, tamper: ((MWBFrame) -> MWBFrame)? = nil) {
        var toB = [a.start()], toA = [b.start()]
        var rounds = 0
        while (!toA.isEmpty || !toB.isEmpty) && rounds < 10 {
            let nextB = toB.flatMap { b.receive(tamper?($0) ?? $0) }
            let nextA = toA.flatMap { a.receive($0) }
            toB = nextA
            toA = nextB
            rounds += 1
        }
    }

    @Test func sameKeyEstablishesBothSides() throws {
        var a = Handshake(role: .initiator, local: hello(idA, "A"), secret: key)
        var b = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        run(&a, &b)
        #expect(a.state == .established)
        #expect(b.state == .established)
        #expect(a.peer?.machineID == idB)
        #expect(b.peer?.name == "A")
        // The derived sessions talk to each other.
        var ca = try #require(a.crypto), cb = try #require(b.crypto)
        let m = MWBMessage.leave.encoded()
        // Each side already sealed/opened one proof; counters continue from there.
        let ab = try cb.open(ca.seal(m))
        let ba = try ca.open(cb.seal(m))
        #expect(ab == m)
        #expect(ba == m)
    }

    @Test func differentKeysAreRejected() {
        var a = Handshake(role: .initiator, local: hello(idA, "A"), secret: key)
        var b = Handshake(role: .responder, local: hello(idB, "B"), secret: "QRSTUVWXYZ234567")
        run(&a, &b)
        #expect(a.state == .failed(.invalidKey))
        #expect(b.state == .failed(.invalidKey))
    }

    @Test func tamperedHelloIsDetected() {
        // Someone in the middle rewrites A's hello (same key, so the proof opens, but the transcript differs).
        var a = Handshake(role: .initiator, local: hello(idA, "A"), secret: key)
        var b = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        run(&a, &b) { frame in
            guard frame.kind == .plain, case .hello(var h)? = try? MWBMessage.decode(frame.payload) else { return frame }
            h.name = "Mallory"
            return MWBFrame(kind: .plain, payload: MWBMessage.hello(h).encoded())
        }
        #expect(a.state == .failed(.invalidKey))
        #expect(b.state == .failed(.invalidKey))
    }

    @Test func protocolViolations() {
        var b = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        _ = b.receive(MWBFrame(kind: .plain, payload: MWBMessage.leave.encoded()))
        #expect(b.state == .failed(.protocolError("expected hello")))

        var c = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        _ = c.receive(MWBFrame(kind: .sealed, payload: Data(repeating: 0, count: 40)))
        if case .failed = c.state {} else { Issue.record("sealed frame before hello accepted") }

        var me = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        _ = me.receive(Handshake(role: .initiator, local: hello(idB, "B again"), secret: key).start())
        #expect(me.state == .failed(.selfConnection))

        var old = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        var h = hello(idA, "A")
        h.protocolVersion = 99
        _ = old.receive(MWBFrame(kind: .plain, payload: MWBMessage.hello(h).encoded()))
        #expect(old.state == .failed(.incompatibleVersion))

        // A plaintext frame where the proof should be.
        var d = Handshake(role: .responder, local: hello(idB, "B"), secret: key)
        _ = d.receive(Handshake(role: .initiator, local: hello(idA, "A"), secret: key).start())
        _ = d.receive(MWBFrame(kind: .plain, payload: MWBMessage.heartbeat.encoded()))
        #expect(d.state == .failed(.protocolError("expected proof")))
    }
}

@Suite struct MWBGeometryTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let wide = CGRect(x: 0, y: 0, width: 2560, height: 1440)

    @Test func exitOnlyAtOuterEdges() {
        let two = [laptop, CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
        #expect(EdgeMath.exit(from: CGPoint(x: 1511, y: 300), delta: CGVector(dx: 4, dy: 0), displays: two) == nil)
        let e = EdgeMath.exit(from: CGPoint(x: 4071, y: 300), delta: CGVector(dx: 4, dy: 0), displays: two)
        #expect(e?.0 == .right && e?.1 == two[1])
        #expect(EdgeMath.exit(from: CGPoint(x: 0, y: 300), delta: CGVector(dx: -1, dy: 0), displays: two)?.0 == .left)
        #expect(EdgeMath.exit(from: CGPoint(x: 600, y: 0), delta: CGVector(dx: 0, dy: -2), displays: two)?.0 == .up)
        #expect(EdgeMath.exit(from: CGPoint(x: 600, y: 981), delta: CGVector(dx: 0, dy: 2), displays: two)?.0 == .down)
        #expect(EdgeMath.exit(from: CGPoint(x: 4071, y: 300), delta: CGVector(dx: -4, dy: 0), displays: two) == nil)
    }

    @Test func entryMapsProportionallyBetweenDifferentSizes() {
        // Leaving the laptop's right edge a quarter of the way down enters a 1440-high display
        // a quarter of the way down its left edge.
        let p = EdgeMath.entryPoint(exit: CGPoint(x: 1511, y: 245.5), from: laptop, direction: .right, into: [wide])
        #expect(p == CGPoint(x: 1, y: 360))
        // Going left enters on the right edge.
        let q = EdgeMath.entryPoint(exit: CGPoint(x: 0, y: 491), from: laptop, direction: .left, into: [wide])
        #expect(q == CGPoint(x: 2558, y: 720))
        // Vertical moves keep the horizontal fraction.
        let r = EdgeMath.entryPoint(exit: CGPoint(x: 756, y: 981), from: laptop, direction: .down, into: [wide])
        #expect(r == CGPoint(x: 1280, y: 1))
        let s = EdgeMath.entryPoint(exit: CGPoint(x: 0, y: 0), from: laptop, direction: .up, into: [wide])
        #expect(s == CGPoint(x: 0, y: 1438))
    }

    @Test func entryAcrossAMultiDisplayEdge() {
        // The receiver has two displays stacked on its left side (offset coordinates).
        let top = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
        let bottom = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let displays = [main, top, bottom]
        // Coming in from the left (moving right) lands on the leftmost edge, spanning both stacked
        // displays: 75 % down the laptop is 75 % down the 2160-point span, on the bottom display.
        let p = EdgeMath.entryPoint(exit: CGPoint(x: 1511, y: 736.5), from: laptop, direction: .right, into: displays)
        #expect(p == CGPoint(x: -1919, y: 540))
        // Top of the span.
        let q = EdgeMath.entryPoint(exit: CGPoint(x: 1511, y: 0), from: laptop, direction: .right, into: displays)
        #expect(q == CGPoint(x: -1919, y: -1080))
        // Bottom edge clamps inside the last display.
        let r = EdgeMath.entryPoint(exit: CGPoint(x: 1511, y: 982), from: laptop, direction: .right, into: displays)
        #expect(r == CGPoint(x: -1919, y: 1079))
    }

    @Test func virtualPointerMovesSlidesAndExits() {
        let displays = [laptop]
        let inside = EdgeMath.move(CGPoint(x: 100, y: 100), by: CGVector(dx: 10, dy: -5), within: displays)
        #expect(inside.point == CGPoint(x: 110, y: 95))
        #expect(inside.exit == nil)
        // Pushing diagonally into the right edge slides along it and reports the exit.
        let edge = EdgeMath.move(CGPoint(x: 1500, y: 100), by: CGVector(dx: 30, dy: 10), within: displays)
        #expect(edge.point == CGPoint(x: 1511, y: 110))
        #expect(edge.exit?.0 == .right)
        // Into a gap between two displays of different heights: stays on the display.
        let mixed = [laptop, CGRect(x: 1512, y: 0, width: 800, height: 600)]
        let gap = EdgeMath.move(CGPoint(x: 1600, y: 590), by: CGVector(dx: 0, dy: 30), within: mixed)
        #expect(gap.point == CGPoint(x: 1600, y: 599))
        #expect(gap.exit?.0 == .down)
        // Across the boundary between the two displays: no exit.
        let across = EdgeMath.move(CGPoint(x: 1505, y: 300), by: CGVector(dx: 20, dy: 0), within: mixed)
        #expect(across.point == CGPoint(x: 1525, y: 300))
        #expect(across.exit == nil)
    }

    @Test func cornersAreDetected() {
        #expect(EdgeMath.nearCorner(CGPoint(x: 1511, y: 10), of: laptop, direction: .right))
        #expect(!EdgeMath.nearCorner(CGPoint(x: 1511, y: 500), of: laptop, direction: .right))
        #expect(EdgeMath.nearCorner(CGPoint(x: 1500, y: 981), of: laptop, direction: .down))
    }
}

@Suite struct MWBLayoutTests {
    let a = MachineSlot(id: UUID(), name: "A"), b = MachineSlot(id: UUID(), name: "B")
    let c = MachineSlot(id: UUID(), name: "C"), d = MachineSlot(id: UUID(), name: "D")

    @Test func singleRowSkipsEmptySlotsAndWraps() {
        var l = MachineLayout()
        l.slots = [a, nil, b, c]
        #expect(l.neighbor(of: a.id, .right, wrap: false) == b.id)
        #expect(l.neighbor(of: b.id, .left, wrap: false) == a.id)
        #expect(l.neighbor(of: c.id, .right, wrap: false) == nil)
        #expect(l.neighbor(of: c.id, .right, wrap: true) == a.id)
        #expect(l.neighbor(of: a.id, .left, wrap: true) == c.id)
        #expect(l.neighbor(of: a.id, .up, wrap: true) == nil)
        #expect(l.neighbor(of: UUID(), .right, wrap: true) == nil)
        var alone = MachineLayout()
        alone.slots = [a, nil, nil, nil]
        #expect(alone.neighbor(of: a.id, .right, wrap: true) == nil)
    }

    @Test func gridNeighbors() {
        var l = MachineLayout()
        l.singleRow = false
        l.slots = [a, b, c, d]
        #expect(l.neighbor(of: a.id, .right, wrap: false) == b.id)
        #expect(l.neighbor(of: a.id, .down, wrap: false) == c.id)
        #expect(l.neighbor(of: d.id, .up, wrap: false) == b.id)
        #expect(l.neighbor(of: d.id, .left, wrap: false) == c.id)
        #expect(l.neighbor(of: a.id, .left, wrap: false) == nil)
        #expect(l.neighbor(of: a.id, .left, wrap: true) == b.id)
        #expect(l.neighbor(of: c.id, .down, wrap: true) == a.id)
        l.slots = [a, nil, c, nil]
        #expect(l.neighbor(of: a.id, .right, wrap: true) == nil)
        #expect(l.neighbor(of: a.id, .down, wrap: false) == c.id)
    }

    @Test func editing() {
        var l = MachineLayout()
        let added = [l.add(a), l.add(b), l.add(c), l.add(d)]
        #expect(added == [true, true, true, true])
        let full = l.add(MachineSlot(id: UUID(), name: "E"))
        #expect(!full)
        let renamed = l.add(MachineSlot(id: a.id, name: "A renamed"))  // existing: updated in place
        #expect(renamed)
        #expect(l.slots[0]?.name == "A renamed")
        l.move(from: 0, to: 3)
        #expect(l.slots[3]?.id == a.id && l.slots[0]?.id == d.id)
        l.remove(b.id)
        #expect(!l.contains(b.id) && l.slots[1] == nil)
        var short = MachineLayout()
        short.slots = [a]
        #expect(short.normalized.slots.count == 4)
    }
}

@Suite struct MWBNetworkMathTests {
    @Test func subnetMatching() throws {
        let iface = Subnet.Interface(address: [192, 168, 1, 12], mask: [255, 255, 255, 0])
        #expect(Subnet.isLocal(try #require(Subnet.parse("192.168.1.200")), interfaces: [iface]))
        #expect(!Subnet.isLocal(try #require(Subnet.parse("192.168.2.5")), interfaces: [iface]))
        #expect(!Subnet.isLocal(try #require(Subnet.parse("8.8.8.8")), interfaces: [iface]))
        #expect(Subnet.isLocal(try #require(Subnet.parse("127.0.0.1")), interfaces: []))
        #expect(Subnet.isLocal(try #require(Subnet.parse("fe80::1%en0")), interfaces: []))
        #expect(Subnet.isLocal(try #require(Subnet.parse("::1")), interfaces: []))
        #expect(Subnet.isLocal(try #require(Subnet.parse("::ffff:192.168.1.7")), interfaces: [iface]))
        #expect(Subnet.parse("not an ip") == nil)
    }

    @Test func manualHostEndpoints() {
        #expect(MWBNetwork.endpoint(for: "192.168.1.20")?.debugDescription.contains("15101") == true)
        #expect(MWBNetwork.endpoint(for: "studio.local:2000")?.debugDescription.contains("2000") == true)
        #expect(MWBNetwork.endpoint(for: "[fe80::1]:3000")?.debugDescription.contains("3000") == true)
        #expect(MWBNetwork.endpoint(for: "  ") == nil)
    }

    @Test func fileNames() {
        #expect(MWBTransferCenter.sanitize("../../etc/passwd") == "passwd")
        #expect(MWBTransferCenter.sanitize(".hidden") == "hidden")
        #expect(MWBTransferCenter.sanitize("a:b.txt") == "a-b.txt")
        #expect(MWBTransferCenter.sanitize("") == "File")
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/report.pdf", "/tmp/x/report 2.pdf"]
        #expect(MWBTransferCenter.uniqueURL(for: "report.pdf", in: folder) { taken.contains($0.path) }.lastPathComponent == "report 3.pdf")
        #expect(MWBTransferCenter.uniqueURL(for: "notes", in: folder) { _ in false }.lastPathComponent == "notes")
    }

    @Test func statusMapping() {
        #expect(MWBStatus(.invalidKey) == .invalidKey)
        #expect(MWBStatus(.timeout) == .timeout)
        #expect(MWBStatus(nil) == .notConnected)
        #expect(MWBStatus(.network("x")) == .error)
    }
}

/// Two in-process endpoints over a real TCP loopback connection.
@Suite(.serialized) @MainActor struct MWBLoopbackTests {
    func makePair(secretA: String, secretB: String) -> (MWBNetwork, MWBNetwork) {
        let a = MWBNetwork(identity: .init(machineID: idA, name: "A"))
        a.useBonjour = false
        a.preferredPort = 0
        a.secret = secretA
        let b = MWBNetwork(identity: .init(machineID: idB, name: "B"))
        b.useBonjour = false
        b.preferredPort = 0
        b.secret = secretB
        return (a, b)
    }

    func wait(_ seconds: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func connectAuthenticateAndExchangeMessages() async throws {
        let (a, b) = makePair(secretA: key, secretB: key)
        var receivedByA: [MWBMessage] = []
        var receivedByB: [MWBMessage] = []
        a.onMessage = { _, m in receivedByA.append(m) }
        b.onMessage = { _, m in receivedByB.append(m) }
        a.start()
        await wait { a.listeningPort != nil }
        let port = try #require(a.listeningPort)
        b.manualHosts = ["127.0.0.1:\(port)"]
        b.start()
        await wait { a.isConnected(idB) && b.isConnected(idA) }
        #expect(a.isConnected(idB))
        #expect(b.isConnected(idA))
        #expect(a.names[idB] == "B")
        #expect(b.hostStatus["127.0.0.1:\(port)"] == .connected)

        let move = MWBMessage.mouseMove(MWBMouseMove(x: 1, y: 2, dx: 3, dy: 4))
        a.send(move, to: idB)
        b.broadcast(.clipboardText("from B"))
        let chunk = MWBMessage.fileChunk(MWBFileChunk(transferID: 1, offset: 0, data: Data(repeating: 5, count: 200_000)))
        var chunkSent = false
        a.send(chunk, to: idB) { chunkSent = true }
        await wait { receivedByB.count >= 2 && receivedByA.count >= 1 }
        #expect(receivedByB == [move, chunk])
        #expect(receivedByA == [.clipboardText("from B")])
        #expect(chunkSent)

        b.stop()
        await wait { !a.isConnected(idB) }
        #expect(!a.isConnected(idB))
        a.stop()
    }

    @Test func wrongKeyNeverConnects() async throws {
        let (a, b) = makePair(secretA: key, secretB: "QRSTUVWXYZ234567")
        var messages = 0
        a.onMessage = { _, _ in messages += 1 }
        a.start()
        await wait { a.listeningPort != nil }
        let port = try #require(a.listeningPort)
        let host = "127.0.0.1:\(port)"
        b.manualHosts = [host]
        b.start()
        await wait { b.hostStatus[host] == .invalidKey }
        #expect(b.hostStatus[host] == .invalidKey)
        #expect(!a.isConnected(idB))
        #expect(!b.isConnected(idA))
        #expect(a.status[idB] == .invalidKey)
        #expect(messages == 0)
        a.stop()
        b.stop()
    }

    @Test func unauthenticatedGarbageIsDropped() async throws {
        let (a, _) = makePair(secretA: key, secretB: key)
        a.start()
        await wait { a.listeningPort != nil }
        let port = try #require(a.listeningPort)
        // A raw client that sends a sealed-looking frame instead of a hello.
        let client = try RawClient(port: port)
        client.send(MWBFrame(kind: .sealed, payload: Data(repeating: 1, count: 64)).encoded())
        await wait { client.isClosed }
        #expect(client.isClosed)
        #expect(a.connectedIDs.isEmpty)
        client.close()
        a.stop()
    }
}

/// A plain TCP client for poking at the listener.
private final class RawClient: @unchecked Sendable {
    private let fd: Int32
    private var closed = false

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard r == 0 else { throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 0, tv_usec: 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ data: Data) {
        data.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, data.count, 0) }
    }

    /// True once the server has closed the connection (reads return 0).
    var isClosed: Bool {
        if closed { return true }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buffer, buffer.count, 0)
        if n == 0 { closed = true }
        return closed
    }

    func close() { Darwin.close(fd) }
}
