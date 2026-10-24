import Foundation

/// Decides whether bytes are text and decodes them (BOMs, UTF-8, UTF-16 without BOM, Latin-1).
public enum TextDecoding {
    /// Whether `data` looks like text: no NUL bytes in the first 8 KB (unless it is UTF-16) and mostly printable.
    public static func isText(_ data: Data) -> Bool {
        decode(data, sniffOnly: true) != nil
    }

    public static func decode(_ data: Data) -> String? {
        decode(data, sniffOnly: false)
    }

    private static func decode(_ data: Data, sniffOnly: Bool) -> String? {
        if data.isEmpty { return "" }
        let head = data.prefix(8192)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return string(data.dropFirst(3), .utf8, sniffOnly) }
        if head.starts(with: [0xFF, 0xFE, 0, 0]) { return string(data, .utf32LittleEndian, sniffOnly) }
        if head.starts(with: [0, 0, 0xFE, 0xFF]) { return string(data, .utf32BigEndian, sniffOnly) }
        if head.starts(with: [0xFF, 0xFE]) { return string(data.dropFirst(2), .utf16LittleEndian, sniffOnly) }
        if head.starts(with: [0xFE, 0xFF]) { return string(data.dropFirst(2), .utf16BigEndian, sniffOnly) }
        let zeros = head.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        if zeros > 0 {
            // UTF-16 without a BOM: ASCII-heavy text has every other byte zero.
            var evenZeros = 0, oddZeros = 0
            for (i, b) in head.enumerated() where b == 0 { if i % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 } }
            let half = head.count / 2
            if oddZeros > half * 7 / 10 && evenZeros <= half / 10 { return string(data, .utf16LittleEndian, sniffOnly) }
            if evenZeros > half * 7 / 10 && oddZeros <= half / 10 { return string(data, .utf16BigEndian, sniffOnly) }
            return nil
        }
        if let s = utf8Prefix(data, sniffOnly: sniffOnly) { return s }
        // Not UTF-8: accept Latin-1 / Windows-1252 when control characters are rare.
        let controls = head.reduce(0) { $0 + (($1 < 0x09 || ($1 > 0x0D && $1 < 0x20) || $1 == 0x7F) ? 1 : 0) }
        guard controls * 20 < head.count else { return nil }
        if sniffOnly { return "" }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    private static func string(_ data: Data, _ encoding: String.Encoding, _ sniffOnly: Bool) -> String? {
        if sniffOnly { return "" }
        return String(data: data, encoding: encoding)
    }

    /// Valid UTF-8 (a multi-byte sequence cut off at the 8 KB sniff boundary still counts).
    private static func utf8Prefix(_ data: Data, sniffOnly: Bool) -> String? {
        if !sniffOnly { return String(data: data, encoding: .utf8) }
        var head = data.prefix(8192)
        for _ in 0..<4 {
            if String(data: head, encoding: .utf8) != nil { return "" }
            guard head.count < data.count, !head.isEmpty else { return nil }
            head = head.dropLast()
        }
        return nil
    }
}
