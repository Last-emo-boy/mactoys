import CryptoKit
import Foundation
import Security

/// The shared security key every machine of a group uses.
enum SecurityKey {
    /// No 0/O or 1/I, so a key read off another screen is typed correctly.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    static let length = 16
    static let minimumLength = 16

    /// A new random key: 16 symbols of a 32-symbol alphabet (80 bits).
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// Uppercases and drops spaces and dashes; nil unless at least 16 letters and digits remain.
    static func normalize(_ input: String) -> String? {
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count >= minimumLength, cleaned.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            return nil
        }
        return cleaned
    }

    /// `ABCD-EFGH-JKLM-NPQR`.
    static func formatted(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 4).map { i -> String in
            let start = key.index(key.startIndex, offsetBy: i)
            let end = key.index(start, offsetBy: min(4, key.count - i))
            return String(key[start..<end])
        }.joined(separator: "-")
    }
}

enum MWBCryptoError: Error, Equatable {
    case authenticationFailed
    case replayed
    case malformed
}

/// AES-GCM for one connection. Each direction has its own key, derived with HKDF-SHA256 from
/// the security key and both peers' hello nonces, so keys are fresh per connection and a frame
/// can't be reflected back to its sender. Nonces are a strictly increasing 64-bit counter; the
/// receiver rejects any counter it has already seen.
struct SessionCrypto {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var lastReceived: UInt64?

    init(secret: String, initiatorNonce: Data, responderNonce: Data, isInitiator: Bool) {
        let ikm = SymmetricKey(data: Data(secret.utf8))
        let salt = initiatorNonce + responderNonce
        let i2r = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("mactoys-mwb v1 initiator to responder".utf8), outputByteCount: 32)
        let r2i = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                         info: Data("mactoys-mwb v1 responder to initiator".utf8), outputByteCount: 32)
        sendKey = isInitiator ? i2r : r2i
        receiveKey = isInitiator ? r2i : i2r
    }

    /// Payload of a sealed frame: `[u64 counter][ciphertext][tag]`.
    mutating func seal(_ plaintext: Data) throws -> Data {
        let counter = sendCounter
        sendCounter += 1
        var counterBytes = BinaryWriter()
        counterBytes.u64(counter)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + counterBytes.data)
        let aad = MWBFrame.header(.sealed) + counterBytes.data
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        return counterBytes.data + box.ciphertext + box.tag
    }

    mutating func open(_ payload: Data) throws -> Data {
        guard payload.count >= 8 + 16 else { throw MWBCryptoError.malformed }
        let counterData = payload.prefix(8)
        var reader = BinaryReader(Data(counterData))
        let counter = try reader.u64()
        if let last = lastReceived, counter <= last { throw MWBCryptoError.replayed }
        let body = payload.dropFirst(8)
        let ciphertext = body.dropLast(16)
        let tag = body.suffix(16)
        do {
            let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + counterData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(box, using: receiveKey, authenticating: MWBFrame.header(.sealed) + counterData)
            lastReceived = counter
            return plain
        } catch {
            throw MWBCryptoError.authenticationFailed
        }
    }
}

/// Why a connection ended or failed to authenticate.
enum MWBFailure: Error, Equatable {
    /// The peer doesn't have the same security key (or tampered with the stream).
    case invalidKey
    case protocolError(String)
    case incompatibleVersion
    /// Connected to this Mac itself.
    case selfConnection
    case timeout
    case closedByPeer
    case notSameSubnet
    /// Another connection to the same machine is kept instead.
    case duplicate
    case network(String)
}

/// The authentication handshake, without I/O: feed it frames, send what it returns.
///
/// Both sides send `hello` (plaintext: protocol version, machine id, name, a fresh 32-byte nonce).
/// After the peer's hello each side derives `SessionCrypto` and sends a sealed `authProof`
/// holding SHA-256 of both hellos. A peer without the key can't produce a proof that opens, and
/// a proof that opens but hashes a different pair of hellos means the hellos were tampered with.
struct Handshake {
    enum Role: Equatable { case initiator, responder }

    enum State: Equatable {
        case awaitingHello
        case awaitingProof
        case established
        case failed(MWBFailure)
    }

    let role: Role
    let local: MWBHello
    private let secret: String
    private(set) var state: State = .awaitingHello
    private(set) var peer: MWBHello?
    private(set) var crypto: SessionCrypto?
    private var expectedProof = Data()

    init(role: Role, local: MWBHello, secret: String) {
        self.role = role
        self.local = local
        self.secret = secret
    }

    /// A fresh hello for this machine.
    static func hello(machineID: UUID, name: String, listenPort: UInt16) -> MWBHello {
        var nonce = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return MWBHello(machineID: machineID, name: name, nonce: Data(nonce), listenPort: listenPort)
    }

    /// The frame to send as soon as the connection is up.
    func start() -> MWBFrame {
        MWBFrame(kind: .plain, payload: MWBMessage.hello(local).encoded())
    }

    /// Handles one frame during the handshake; returns frames to send.
    mutating func receive(_ frame: MWBFrame) -> [MWBFrame] {
        switch state {
        case .awaitingHello:
            guard frame.kind == .plain, case .hello(let hello)? = try? MWBMessage.decode(frame.payload) else {
                state = .failed(.protocolError("expected hello"))
                return []
            }
            guard hello.protocolVersion == local.protocolVersion else { state = .failed(.incompatibleVersion); return [] }
            guard hello.machineID != local.machineID else { state = .failed(.selfConnection); return [] }
            peer = hello
            let initiatorHello = role == .initiator ? local : hello
            let responderHello = role == .initiator ? hello : local
            var crypto = SessionCrypto(secret: secret, initiatorNonce: initiatorHello.nonce,
                                       responderNonce: responderHello.nonce, isInitiator: role == .initiator)
            let transcript = MWBMessage.hello(initiatorHello).encoded() + MWBMessage.hello(responderHello).encoded()
            expectedProof = Data(SHA256.hash(data: transcript))
            do {
                let sealed = try crypto.seal(MWBMessage.authProof(expectedProof).encoded())
                self.crypto = crypto
                state = .awaitingProof
                return [MWBFrame(kind: .sealed, payload: sealed)]
            } catch {
                state = .failed(.protocolError("seal failed"))
                return []
            }
        case .awaitingProof:
            guard frame.kind == .sealed, var crypto else {
                state = .failed(.protocolError("expected proof"))
                return []
            }
            do {
                let plain = try crypto.open(frame.payload)
                guard case .authProof(let proof) = try MWBMessage.decode(plain), proof == expectedProof else {
                    state = .failed(.invalidKey)
                    return []
                }
                self.crypto = crypto
                state = .established
            } catch {
                state = .failed(.invalidKey)
            }
            return []
        case .established, .failed:
            return []
        }
    }
}
