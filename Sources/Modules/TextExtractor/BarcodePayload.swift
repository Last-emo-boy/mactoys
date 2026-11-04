import Foundation

/// A QR code or barcode found in a capture.
public struct Barcode: Codable, Equatable, Hashable, Sendable {
    /// Vision's symbology name without the prefix, e.g. `QR`, `EAN13`, `Code128`.
    public var symbology: String
    public var payload: String

    public init(symbology: String, payload: String) {
        self.symbology = symbology
        self.payload = payload
    }

    public var content: BarcodeContent { BarcodeContent(payload: payload, symbology: symbology) }

    /// What copying the code puts on the clipboard: a Wi-Fi password rather than the `WIFI:` string,
    /// the address of a `mailto:`, the number of a `tel:`; contacts and events keep their full text.
    public var copyText: String {
        switch content {
        case .wifi(let network, let password, _, _): password ?? network
        case .contact, .event: payload
        default: content.primaryText ?? payload
        }
    }

    /// Matrix codes (QR, Aztec, Data Matrix, PDF417) as opposed to 1-D product and inventory codes.
    public var isMatrix: Bool { Self.isMatrix(symbology) }

    static func isMatrix(_ symbology: String) -> Bool {
        ["QR", "MicroQR", "Aztec", "DataMatrix", "PDF417", "MicroPDF417"].contains(symbology)
    }
}

/// What a barcode's payload means, so the card can offer the right action: open a link, write an
/// email, show a Wi-Fi password. Only web links count as links: other URL schemes found in a code
/// (custom app schemes, `file:`) are shown and copied as text, never opened.
public enum BarcodeContent: Equatable, Sendable {
    case link(URL)
    case email(address: String, subject: String?)
    case phone(String)
    case message(number: String, body: String?)
    case wifi(network: String, password: String?, security: String?, hidden: Bool)
    case location(latitude: Double, longitude: Double)
    case contact(name: String?)
    case event(title: String?)
    case product(String)
    case text(String)

    public init(payload raw: String, symbology: String = "QR") {
        let payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = payload.lowercased()
        if let url = Self.webLink(payload) {
            self = .link(url)
        } else if lower.hasPrefix("mailto:") {
            let rest = String(payload.dropFirst(7))
            let parts = rest.split(separator: "?", maxSplits: 1)
            let address = String(parts.first ?? "").removingPercentEncoding ?? String(parts.first ?? "")
            let subject = parts.count > 1 ? URLComponents(string: "x:?" + parts[1])?.queryItems?
                .first { $0.name.lowercased() == "subject" }?.value : nil
            self = .email(address: address, subject: subject)
        } else if lower.hasPrefix("matmsg:") {
            let fields = Self.fields(String(payload.dropFirst(7)))
            self = .email(address: fields["TO"] ?? "", subject: fields["SUB"])
        } else if lower.hasPrefix("tel:") {
            self = .phone(String(payload.dropFirst(4)))
        } else if lower.hasPrefix("smsto:") || lower.hasPrefix("sms:") {
            let rest = payload.drop { $0 != ":" }.dropFirst()
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            let number = parts.first?.split(separator: "?").first.map(String.init) ?? ""
            self = .message(number: number, body: parts.count > 1 ? parts[1] : nil)
        } else if lower.hasPrefix("wifi:") {
            let f = Self.fields(String(payload.dropFirst(5)))
            let security = f["T"].flatMap { $0.isEmpty || $0.lowercased() == "nopass" ? nil : $0 }
            self = .wifi(network: f["S"] ?? "", password: f["P"].flatMap { $0.isEmpty ? nil : $0 }, security: security,
                         hidden: f["H"]?.lowercased() == "true")
        } else if lower.hasPrefix("geo:"), let coords = Self.coordinates(String(payload.dropFirst(4))) {
            self = .location(latitude: coords.0, longitude: coords.1)
        } else if lower.hasPrefix("begin:vcard") {
            self = .contact(name: Self.line("FN", in: payload) ?? Self.line("N", in: payload)?
                .split(separator: ";").reversed().filter { !$0.isEmpty }.joined(separator: " "))
        } else if lower.hasPrefix("mecard:") {
            let name = Self.fields(String(payload.dropFirst(7)))["N"]
            self = .contact(name: name.map { $0.split(separator: ",").reversed().joined(separator: " ") })
        } else if lower.hasPrefix("begin:vevent") || lower.hasPrefix("begin:vcalendar") {
            self = .event(title: Self.line("SUMMARY", in: payload))
        } else if Self.productSymbologies.contains(symbology) || (payload.count >= 8 && payload.count <= 14
                    && payload.allSatisfy(\.isASCII) && payload.allSatisfy(\.isNumber) && !Barcode.isMatrix(symbology)) {
            self = .product(payload)
        } else {
            self = .text(payload)
        }
    }

    static let productSymbologies: Set<String> = ["EAN8", "EAN13", "UPCE", "ITF14", "GS1DataBar", "GS1DataBarExpanded", "GS1DataBarLimited"]

    /// `http(s)://…` or a bare `www.` host.
    static func webLink(_ s: String) -> URL? {
        guard !s.contains(where: \.isWhitespace) else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            // QR codes in alphanumeric mode are upper case: HTTPS://EXAMPLE.COM/A.
            let scheme = lower.hasPrefix("https") ? "https" : "http"
            let rest = s.drop { $0 != ":" }
            guard let url = URL(string: scheme + rest), url.host()?.isEmpty == false else { return nil }
            return url
        }
        if lower.hasPrefix("www."), lower.contains(".") {
            return URL(string: "https://" + s).flatMap { $0.host()?.isEmpty == false ? $0 : nil }
        }
        return nil
    }

    /// `K:value;K:value;;` with `\;`, `\,`, `\:` and `\\` escapes (Wi-Fi, MECARD, MATMSG).
    static func fields(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var key: String?
        var current = ""
        var escaped = false
        for c in s {
            if escaped { current.append(c); escaped = false; continue }
            switch c {
            case "\\": escaped = true
            case ":" where key == nil:
                key = current.uppercased()
                current = ""
            case ";":
                if let key, out[key] == nil { out[key] = current }
                key = nil
                current = ""
            default: current.append(c)
            }
        }
        if let key, out[key] == nil { out[key] = current }
        return out
    }

    /// `37.78,-122.4` with optional `,altitude`, `;u=…` or `?q=…` after it.
    static func coordinates(_ s: String) -> (Double, Double)? {
        let head = s.split(whereSeparator: { $0 == ";" || $0 == "?" }).first.map(String.init) ?? s
        let parts = head.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count >= 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return (parts[0], parts[1])
    }

    /// The value of a `KEY:` or `KEY;params:` line in a vCard or iCalendar text.
    static func line(_ key: String, in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].split(separator: ";").first.map { $0.uppercased() } ?? ""
            if name == key {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// The text a "Copy" action copies: the link, the address, the password when there is one.
    public var primaryText: String? {
        switch self {
        case .link(let url): url.absoluteString
        case .email(let address, _): address
        case .phone(let n): n
        case .message(let n, _): n
        case .wifi(_, let password, _, _): password
        case .location(let lat, let lon): "\(lat), \(lon)"
        case .contact(let name): name
        case .event(let title): title
        case .product(let code): code
        case .text(let t): t
        }
    }

    /// A URL that opens the content in the app made for it (browser, Mail, Messages, FaceTime, Maps).
    public var openURL: URL? {
        switch self {
        case .link(let url): return url
        case .email(let address, let subject):
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = address
            if let subject { c.queryItems = [URLQueryItem(name: "subject", value: subject)] }
            return address.isEmpty ? nil : c.url
        case .phone(let n):
            let digits = n.filter { $0.isNumber || $0 == "+" }
            return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
        case .message(let n, _):
            let digits = n.filter { $0.isNumber || $0 == "+" }
            return digits.isEmpty ? nil : URL(string: "sms:\(digits)")
        case .location(let lat, let lon):
            return URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(lat),\(lon)")
        default:
            return nil
        }
    }
}
