import CryptoKit
import Foundation

/// UUIDs, hashes and encodings: `uuid`, `uuidv7`, `uuidv5 ns:URL https://example.com`, `md5 abc`,
/// `sha256 abc`, `hash abc`, `base64 abc`, `base64d YWJj`, `url a b`, `urld a+b`, `esc:data …`,
/// `uesc:data …`, `esc:hex z`, `uesc:hex %7A`.
enum ValueGenerator {
    struct Output: Equatable {
        let title: String
        let value: String
    }

    enum Failure: Error, Equatable {
        case missingInput(String)
        case invalid(String)
    }

    static let namespaces: [String: UUID] = [
        "dns": UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!,
        "url": UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!,
        "oid": UUID(uuidString: "6ba7b812-9dad-11d1-80b4-00c04fd430c8")!,
        "x500": UUID(uuidString: "6ba7b814-9dad-11d1-80b4-00c04fd430c8")!,
    ]

    /// Every command word, for help text and global matching.
    static let commands = ["uuid", "guid", "uuidv1", "uuidv3", "uuidv4", "uuidv5", "uuidv7", "md5", "sha1", "sha256",
                           "sha384", "sha512", "hash", "base64", "base64d", "url", "urld", "esc:data", "uesc:data",
                           "esc:hex", "uesc:hex"]

    /// nil when the first word is not a generator command.
    static func generate(_ text: String, now: Date = Date()) -> Result<[Output], Failure>? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let space = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
        let command = trimmed[..<space].lowercased()
        let argument = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)

        if let version = uuidVersion(command) {
            switch version {
            case 3, 5:
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return .failure(.missingInput("namespace and name, e.g. ns:DNS example.com")) }
                guard let ns = namespace(parts[0]) else { return .failure(.invalid("Unknown namespace “\(parts[0])”")) }
                let id = nameBased(version: version, namespace: ns, name: parts[1])
                return .success([Output(title: "UUID v\(version)", value: id.uuidString.lowercased())])
            default:
                let count = min(max(Int(argument) ?? 1, 1), 20)
                return .success((0..<count).map { _ in
                    Output(title: "UUID v\(version)", value: uuid(version: version, now: now).uuidString.lowercased())
                })
            }
        }

        switch command {
        case "md5", "sha1", "sha256", "sha384", "sha512":
            guard !argument.isEmpty else { return .failure(.missingInput("text to hash")) }
            return .success([Output(title: command.uppercased(), value: hash(command, argument))])
        case "hash":
            guard !argument.isEmpty else { return .failure(.missingInput("text to hash")) }
            return .success(["md5", "sha1", "sha256", "sha512"].map { Output(title: $0.uppercased(), value: hash($0, argument)) })
        case "base64":
            guard !argument.isEmpty else { return .failure(.missingInput("text to encode")) }
            return .success([Output(title: "Base64", value: Data(argument.utf8).base64EncodedString())])
        case "base64d":
            guard !argument.isEmpty else { return .failure(.missingInput("Base64 to decode")) }
            guard let s = base64Decode(argument) else { return .failure(.invalid("Not valid Base64 text")) }
            return .success([Output(title: "Decoded Base64", value: s)])
        case "url":
            guard !argument.isEmpty else { return .failure(.missingInput("text to encode")) }
            return .success([Output(title: "URL encoded", value: formEncode(argument))])
        case "urld":
            guard !argument.isEmpty else { return .failure(.missingInput("text to decode")) }
            guard let s = argument.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else {
                return .failure(.invalid("Not valid URL encoding"))
            }
            return .success([Output(title: "URL decoded", value: s)])
        case "esc:data":
            guard !argument.isEmpty else { return .failure(.missingInput("text to escape")) }
            return .success([Output(title: "Escaped data string", value: escapeData(argument))])
        case "uesc:data":
            guard let s = argument.removingPercentEncoding, !argument.isEmpty else { return .failure(.invalid("Not a valid escaped string")) }
            return .success([Output(title: "Unescaped data string", value: s)])
        case "esc:hex":
            guard let c = argument.unicodeScalars.first else { return .failure(.missingInput("a character")) }
            let hex = String(c).utf8.map { String(format: "%%%02X", $0) }.joined()
            return .success([Output(title: "Escaped hex character", value: hex)])
        case "uesc:hex":
            guard argument.hasPrefix("%"), let s = argument.removingPercentEncoding, let first = s.first else {
                return .failure(.invalid("Expected a %XX sequence"))
            }
            return .success([Output(title: "Unescaped hex character", value: String(first))])
        default:
            return nil
        }
    }

    /// `uuid`, `guid`, `uuidv7`, `guid7`, `uuid4` → version number.
    static func uuidVersion(_ command: String) -> Int? {
        var c = command
        guard c.hasPrefix("uuid") || c.hasPrefix("guid") else { return nil }
        c.removeFirst(4)
        if c.hasPrefix("v") { c.removeFirst() }
        if c.isEmpty { return 4 }
        guard let v = Int(c), [1, 3, 4, 5, 7].contains(v) else { return nil }
        return v
    }

    static func namespace(_ s: String) -> UUID? {
        let lower = s.lowercased()
        if lower.hasPrefix("ns:") { return namespaces[String(lower.dropFirst(3))] }
        return UUID(uuidString: s)
    }

    static func uuid(version: Int, now: Date = Date()) -> UUID {
        var rng = SystemRandomNumberGenerator()
        var b = (0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) }
        switch version {
        case 7:
            let ms = UInt64(max(now.timeIntervalSince1970, 0) * 1000)
            for i in 0..<6 { b[i] = UInt8(truncatingIfNeeded: ms >> (8 * (5 - i))) }
            b[6] = 0x70 | (b[6] & 0x0F)
        case 1:
            // 100 ns intervals since 1582-10-15, random node with the multicast bit set (RFC 9562 §6.10).
            let ts = UInt64((max(now.timeIntervalSince1970, 0) + 12_219_292_800) * 10_000_000)
            let low = UInt32(truncatingIfNeeded: ts), mid = UInt16(truncatingIfNeeded: ts >> 32)
            let high = UInt16(truncatingIfNeeded: ts >> 48) & 0x0FFF
            for i in 0..<4 { b[i] = UInt8(truncatingIfNeeded: low >> (8 * (3 - i))) }
            b[4] = UInt8(mid >> 8); b[5] = UInt8(truncatingIfNeeded: mid)
            b[6] = 0x10 | UInt8(high >> 8); b[7] = UInt8(truncatingIfNeeded: high)
            b[10] |= 0x01
        default:
            b[6] = 0x40 | (b[6] & 0x0F)
        }
        b[8] = 0x80 | (b[8] & 0x3F)
        return makeUUID(b)
    }

    /// Version 3 (MD5) or 5 (SHA-1) name-based UUID.
    static func nameBased(version: Int, namespace: UUID, name: String) -> UUID {
        let ns = withUnsafeBytes(of: namespace.uuid) { Array($0) }
        let data = Data(ns + Array(name.utf8))
        var b: [UInt8] = version == 3 ? Array(Insecure.MD5.hash(data: data)) : Array(Insecure.SHA1.hash(data: data))
        b = Array(b.prefix(16))
        b[6] = UInt8(version << 4) | (b[6] & 0x0F)
        b[8] = 0x80 | (b[8] & 0x3F)
        return makeUUID(b)
    }

    private static func makeUUID(_ b: [UInt8]) -> UUID {
        UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func hash(_ algorithm: String, _ text: String) -> String {
        let data = Data(text.utf8)
        let bytes: [UInt8]
        switch algorithm {
        case "md5": bytes = Array(Insecure.MD5.hash(data: data))
        case "sha1": bytes = Array(Insecure.SHA1.hash(data: data))
        case "sha384": bytes = Array(SHA384.hash(data: data))
        case "sha512": bytes = Array(SHA512.hash(data: data))
        default: bytes = Array(SHA256.hash(data: data))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func base64Decode(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8) ?? data.map { String(format: "%02x", $0) }.joined()
    }

    private static let asciiAlphanumerics = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    /// `application/x-www-form-urlencoded` style: spaces become `+`.
    static func formEncode(_ s: String) -> String {
        var allowed = asciiAlphanumerics
        allowed.insert(charactersIn: "-._~ ")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
    }

    /// RFC 3986 data string: everything but unreserved characters is escaped.
    static func escapeData(_ s: String) -> String {
        var allowed = asciiAlphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
