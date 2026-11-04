import AppKit
import MacToysCore
import Observation
import SwiftUI
import Translation

/// Everything the user can do on the result card; the presenter carries it out.
enum CardAction {
    case copy
    case copyText(String)
    case toggleJoin
    case translate
    case setTarget(String?)
    case openLanguageSettings
    case speak(String, id: String, language: String?)
    case open(URL)
    case barcode(Barcode)
    case show(Capture)
    case clearRecent
    case startOver
    case close
    case drop([URL])
    case hover(Bool)
    /// The user did something on the card: keep it up longer.
    case engage
}

/// The state of the result card next to the selection.
@MainActor
@Observable
final class CardModel {
    enum Phase: Equatable {
        /// Reading a file or the clipboard: a title and an optional "Page 2 of 5".
        case working(String, detail: String?)
        case result
        case empty(String)
        case failed(String)
    }

    enum TranslationPhase: Equatable {
        case hidden
        case working
        case done(String)
        case sameLanguage
        case needsDownload
        case unsupported
        case failed(String)
    }

    var phase: Phase = .result
    var capture: Capture?
    /// Pieces collected on the additive clipboard (0 when it isn't in use).
    var addedCount = 0
    /// Whether the capture can switch between kept and joined lines.
    var canJoin = false
    var translation: TranslationPhase = .hidden
    var target: Locale.Language = Translator.target(nil)
    /// Set to start a translation that may download languages (shows the system's prompt).
    var downloadRequest: TranslationSession.Configuration?
    var showRecent = false
    var dropTargeted = false
    /// The id of a value just copied, for the brief "Copied" check.
    var justCopied: String?
    var targetChoices: [String] = Translator.commonTargets
    @ObservationIgnored let history: CaptureHistory
    @ObservationIgnored var onAction: (CardAction) -> Void = { _ in }

    init(history: CaptureHistory) {
        self.history = history
    }

    var recents: [Capture] { history.items.filter { $0.id != capture?.id } }

    /// The first web link in the text (for "Open Link" on text captures).
    var textLink: URL? {
        guard let text = capture?.text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).lazy.compactMap(\.url)
            .first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    func send(_ action: CardAction) { onAction(action) }

    /// Runs a translation through a session the system prepared (after a language download).
    func translate(using session: TranslationSession) async {
        guard let text = capture?.text, !text.isEmpty else { return }
        do {
            try await session.prepareTranslation()
            let response = try await session.translate(text)
            translation = .done(response.targetText)
        } catch {
            translation = .failed(error.localizedDescription)
        }
        downloadRequest = nil
    }
}

// MARK: - Card

/// The glass card that follows a capture: the text, its language, actions and recent captures.
struct ResultCard: View {
    @Bindable var model: CardModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if case .result = model.phase, let c = model.capture, !c.barcodeFirst {
                actions
                if model.translation != .hidden { TranslationSection(model: model) }
            }
            if !model.recents.isEmpty { RecentSection(model: model) }
        }
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(background)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: 1))
        .overlay { if model.dropTargeted { dropOverlay } }
        .onHover { model.send(.hover($0)) }
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            Self.loadURLs(providers) { model.send(.drop($0)) }
            return true
        }
        .animation(.smooth(duration: 0.25), value: model.phase)
        .animation(.smooth(duration: 0.25), value: model.translation)
        .animation(.smooth(duration: 0.25), value: model.showRecent)
    }

    private var background: Color {
        if reduceTransparency { return Color(nsColor: .windowBackgroundColor) }
        return scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.6) : Color.white.opacity(0.62)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CardSymbol(symbol: headerSymbol, tint: headerTint)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if model.addedCount > 1 {
                Button { model.send(.startOver) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(Text("Start Over: collect a new set of captures", comment: "Tooltip: empty the additive clipboard collection"))
                .accessibilityLabel(Text("Start Over", comment: "Card button: empty the additive clipboard collection"))
            }
            Button { model.send(.close) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(Text("Close", comment: "Tooltip: close the card"))
            .accessibilityLabel(Text("Close", comment: "Tooltip: close the card"))
        }
    }

    private var headerSymbol: String {
        switch model.phase {
        case .working: return "doc.text.viewfinder"
        case .empty: return "text.viewfinder"
        case .failed: return "exclamationmark.triangle.fill"
        case .result:
            guard let c = model.capture else { return "clock.arrow.circlepath" }
            if c.barcodeFirst, let code = c.barcodes.first { return code.isMatrix ? "qrcode" : "barcode" }
            return model.addedCount > 1 ? "text.badge.plus" : "doc.on.doc.fill"
        }
    }

    private var headerTint: Tint {
        if case .failed = model.phase { return .orange }
        if case .empty = model.phase { return .graphite }
        return .mint
    }

    private var title: String {
        switch model.phase {
        case .working(let title, _): return title
        case .empty(let message): return message
        case .failed: return String(localized: "Couldn’t read the text", comment: "Card title after an error")
        case .result:
            guard let c = model.capture else { return String(localized: "Recent Captures") }
            if c.barcodeFirst {
                if c.barcodes.count > 1 { return String(localized: "\(c.barcodes.count) codes copied", comment: "Card title: several QR codes or barcodes") }
                return c.barcodes[0].isMatrix ? String(localized: "QR code copied", comment: "Card title")
                    : String(localized: "Barcode copied", comment: "Card title")
            }
            if model.addedCount > 1 {
                return String(localized: "\(model.addedCount) captures on the clipboard", comment: "Card title: captures collected on the additive clipboard")
            }
            let lines = c.lineCount
            return lines > 1 ? String(localized: "Copied \(lines) lines", comment: "Text Extractor copied several lines of text")
                : String(localized: "Copied text", comment: "Card title")
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .working(_, let detail): return detail
        case .empty: return String(localized: "Try a larger area, or turn off language correction for codes and IDs.")
        case .failed(let message): return message
        case .result:
            guard let c = model.capture else { return nil }
            var parts: [String] = []
            if let language = LanguageDetector.name(c.language) { parts.append(language) }
            switch c.source {
            case .screen: parts.append(String(localized: "Screen", comment: "Where a capture came from"))
            case .file(let name): parts.append(name)
            case .clipboard: parts.append(String(localized: "Clipboard image", comment: "Where a capture came from"))
            }
            parts.append(c.date.formatted(date: .omitted, time: .shortened))
            return parts.joined(separator: " · ")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Recognizing text on this Mac…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(CardWell())
        case .empty, .failed:
            dropHint
        case .result:
            if let c = model.capture {
                if c.barcodeFirst {
                    VStack(spacing: 8) {
                        ForEach(c.barcodes.prefix(3), id: \.self) { BarcodeView(barcode: $0, model: model) }
                    }
                } else {
                    TextWell(text: c.text)
                    if !c.barcodes.isEmpty {
                        ForEach(c.barcodes.prefix(2), id: \.self) { BarcodeView(barcode: $0, model: model, compact: true) }
                    }
                }
            } else {
                dropHint
            }
        }
    }

    private var dropHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Tint.mint.color)
            Text("Drop an image or a PDF here to read its text.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(CardWell(dashed: true))
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(scheme == .dark ? Color(red: 0.1, green: 0.13, blue: 0.14).opacity(0.94) : Color(red: 0.93, green: 0.98, blue: 0.97).opacity(0.95))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Tint.mint.color, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                    Text("Drop to extract text").font(.system(size: 14, weight: .semibold))
                    Text("Images and PDFs").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .foregroundStyle(Tint.mint.color)
            }
            .allowsHitTesting(false)
    }

    // MARK: Actions

    private var actions: some View {
        let c = model.capture
        let isText = !(c?.barcodeFirst ?? true) && !(c?.text.isEmpty ?? true)
        let speaking = Speaker.shared.speakingID == c.map { "capture:\($0.id)" }
        return HStack(spacing: 6) {
            CardTile(title: model.justCopied == "capture" ? String(localized: "Copied", comment: "Card tile after copying")
                        : String(localized: "Copy", comment: "Card tile: copy the text again"),
                     symbol: model.justCopied == "capture" ? "checkmark" : "doc.on.doc") { model.send(.copy) }
            if isText {
                if model.canJoin {
                    let joined = c?.mode == .paragraphs || c?.mode == .singleLine
                    CardTile(title: joined ? String(localized: "Keep Lines", comment: "Card tile: undo joining lines")
                                : String(localized: "Join Lines", comment: "Card tile: join wrapped lines into paragraphs"),
                             symbol: joined ? "text.alignleft" : "text.justify.left", active: joined) { model.send(.toggleJoin) }
                }
                CardTile(title: String(localized: "Translate", comment: "Card tile"), symbol: "translate",
                         active: model.translation != .hidden) { model.send(.translate) }
                CardTile(title: speaking ? String(localized: "Stop", comment: "Card tile: stop reading aloud")
                            : String(localized: "Read Aloud", comment: "Card tile"),
                         symbol: speaking ? "stop.fill" : "speaker.wave.2", active: speaking) {
                    if let c { model.send(.speak(c.text, id: "capture:\(c.id)", language: c.language)) }
                }
                if let link = model.textLink {
                    CardTile(title: String(localized: "Open Link", comment: "Card tile"), symbol: "safari") { model.send(.open(link)) }
                }
            }
        }
    }

    /// File URLs from a drop.
    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { box.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = box.urls
            MainActor.assumeIsolated { completion(urls) }
        }
    }
}

/// Collects URLs from item providers' callbacks.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ url: URL) { lock.lock(); list.append(url); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return list }
}

// MARK: - Pieces

/// The rounded inner surface of the card.
struct CardWell: View {
    var dashed = false
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay {
                if dashed {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
    }
}

/// A tinted symbol tile, like the module icon but smaller.
struct CardSymbol: View {
    let symbol: String
    let tint: Tint
    var size: CGFloat = 30
    var body: some View {
        ModuleIcon(symbol: symbol, tint: tint, size: size)
    }
}

/// The captured text, selectable, scrolling when it's long.
struct TextWell: View {
    let text: String
    var body: some View {
        ScrollView(.vertical) {
            Text(verbatim: text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: 168)
        .fixedSize(horizontal: false, vertical: true)
        .background(CardWell())
    }
}

/// An action: symbol over a short label, sized to share the row.
struct CardTile: View {
    let title: String
    let symbol: String
    var active = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 18)
                    .contentTransition(.symbolEffect(.replace))
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(active ? Tint.mint.color : Color.primary.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Tint.mint.color.opacity(0.16) : Color.primary.opacity(hovering ? 0.1 : 0.055)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// A small capsule button inside the card.
struct CardPill: View {
    let title: Text
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            title
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? AnyShapeStyle(Tint.mint.color.gradient) : AnyShapeStyle(Color.primary.opacity(0.08))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One QR code or barcode: what it holds and the action that fits.
struct BarcodeView: View {
    let barcode: Barcode
    let model: CardModel
    var compact = false

    var body: some View {
        let content = barcode.content
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: Self.symbol(content))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Tint.mint.color.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(verbatim: Self.kind(content)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                        Text(verbatim: Self.symbologyName(barcode.symbology))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Text(verbatim: Self.headline(content))
                        .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if let detail = Self.detail(content) {
                        Text(verbatim: detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            if case .wifi(_, let password, let security, _) = content {
                WifiRows(password: password, security: security, model: model)
            }
            if !compact {
                HStack(spacing: 6) {
                    let copied = model.justCopied == barcode.copyText
                    CardTile(title: copied ? String(localized: "Copied", comment: "Card tile after copying") : Self.copyTitle(content),
                             symbol: copied ? "checkmark" : "doc.on.doc") {
                        model.send(.copyText(barcode.copyText))
                    }
                    if case .wifi(let network, _, _, _) = content, !network.isEmpty {
                        CardTile(title: model.justCopied == network ? String(localized: "Copied", comment: "Card tile after copying")
                                    : String(localized: "Copy Network Name", comment: "Card tile: copy a Wi-Fi network's name"),
                                 symbol: model.justCopied == network ? "checkmark" : "wifi") { model.send(.copyText(network)) }
                    }
                    if let action = Self.primaryAction(content) {
                        CardTile(title: action.title, symbol: action.symbol) { model.send(.barcode(barcode)) }
                    }
                    if let other = model.capture?.text, !other.isEmpty {
                        CardTile(title: String(localized: "Copy Text", comment: "Card tile: copy the text found next to a QR code"),
                                 symbol: "text.alignleft") { model.send(.copyText(other)) }
                    }
                }
            } else if let action = Self.primaryAction(content) {
                Button { model.send(.barcode(barcode)) } label: {
                    Label(action.title, systemImage: action.symbol).font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tint.mint.color)
            }
        }
        .padding(10)
        .background(CardWell())
    }

    static func copyTitle(_ c: BarcodeContent) -> String {
        switch c {
        case .wifi(_, let password, _, _) where password != nil:
            String(localized: "Copy Password", comment: "Card tile: copy a Wi-Fi password")
        case .link: String(localized: "Copy Link", comment: "Card tile")
        default: String(localized: "Copy", comment: "Card tile: copy the text again")
        }
    }

    static func symbol(_ c: BarcodeContent) -> String {
        switch c {
        case .link: "link"
        case .email: "envelope.fill"
        case .phone: "phone.fill"
        case .message: "message.fill"
        case .wifi: "wifi"
        case .location: "mappin.and.ellipse"
        case .contact: "person.crop.circle.fill"
        case .event: "calendar"
        case .product: "barcode"
        case .text: "text.alignleft"
        }
    }

    static func kind(_ c: BarcodeContent) -> String {
        switch c {
        case .link: String(localized: "Link", comment: "Kind of QR code content")
        case .email: String(localized: "Email", comment: "Kind of QR code content")
        case .phone: String(localized: "Phone number", comment: "Kind of QR code content")
        case .message: String(localized: "Text message", comment: "Kind of QR code content: an SMS")
        case .wifi: String(localized: "Wi-Fi network", comment: "Kind of QR code content")
        case .location: String(localized: "Location", comment: "Kind of QR code content")
        case .contact: String(localized: "Contact", comment: "Kind of QR code content: a business card")
        case .event: String(localized: "Event", comment: "Kind of QR code content: a calendar event")
        case .product: String(localized: "Product code", comment: "Kind of barcode content: EAN or UPC number")
        case .text: String(localized: "Text", comment: "Kind of QR code content: plain text")
        }
    }

    /// The bold line: the host of a link, the network name, the address.
    static func headline(_ c: BarcodeContent) -> String {
        switch c {
        case .link(let url): (url.host() ?? url.absoluteString).replacingOccurrences(of: "www.", with: "", options: .anchored)
        case .email(let address, _): address
        case .phone(let n): n
        case .message(let n, _): n
        case .wifi(let network, _, _, _): network
        case .location(let lat, let lon): "\(lat.formatted(.number.precision(.fractionLength(0...5)))), \(lon.formatted(.number.precision(.fractionLength(0...5))))"
        case .contact(let name): name ?? String(localized: "Unnamed contact")
        case .event(let title): title ?? String(localized: "Untitled event")
        case .product(let code): code
        case .text(let t): t
        }
    }

    static func detail(_ c: BarcodeContent) -> String? {
        switch c {
        case .link(let url):
            let s = url.absoluteString
            return s.count > 160 ? String(s.prefix(160)) + "…" : s
        case .email(_, let subject): return subject
        case .message(_, let body): return body
        default: return nil
        }
    }

    static func primaryAction(_ c: BarcodeContent) -> (title: String, symbol: String)? {
        switch c {
        case .link: (String(localized: "Open Link", comment: "Card tile"), "safari")
        case .email: (String(localized: "New Email", comment: "Card tile: write an email to the address in a QR code"), "square.and.pencil")
        case .phone: (String(localized: "Call", comment: "Card tile: call the number in a QR code"), "phone")
        case .message: (String(localized: "Message", comment: "Card tile: write a text message to the number in a QR code"), "message")
        case .location: (String(localized: "Show in Maps", comment: "Card tile"), "map")
        case .contact: (String(localized: "Add to Contacts", comment: "Card tile"), "person.crop.circle.badge.plus")
        case .event: (String(localized: "Add to Calendar", comment: "Card tile"), "calendar.badge.plus")
        case .wifi, .product, .text: nil
        }
    }

    /// "EAN-13", "Code 128", "QR".
    static func symbologyName(_ s: String) -> String {
        switch s {
        case "EAN13": "EAN-13"
        case "EAN8": "EAN-8"
        case "UPCE": "UPC-E"
        case "ITF14": "ITF-14"
        case "Code128": "Code 128"
        case "Code39", "Code39Checksum", "Code39FullASCII", "Code39FullASCIIChecksum": "Code 39"
        case "Code93", "Code93i": "Code 93"
        case "DataMatrix": "Data Matrix"
        case "MicroQR": "Micro QR"
        case "I2of5", "I2of5Checksum": "ITF"
        default: s
        }
    }
}

/// Password and security rows of a Wi-Fi code.
private struct WifiRows: View {
    let password: String?
    let security: String?
    let model: CardModel
    @State private var reveal = false

    var body: some View {
        VStack(spacing: 0) {
            row(Text("Password", comment: "Wi-Fi QR code: the network password")) {
                if let password {
                    Text(verbatim: reveal ? password : String(repeating: "•", count: min(password.count, 14)))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(reveal ? Text("Hide password") : Text("Show password"))
                } else {
                    Text("None", comment: "Wi-Fi QR code: an open network has no password").foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.5)
            row(Text("Security", comment: "Wi-Fi QR code: WPA, WEP or none")) {
                Text(verbatim: security ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func row<V: View>(_ label: Text, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 8) {
            label.foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }
}

/// Source → target language, the translation, copy and read aloud.
struct TranslationSection: View {
    @Bindable var model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "translate").foregroundStyle(Tint.mint.color)
                if let source = LanguageDetector.name(model.capture?.language) {
                    Text(verbatim: source).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                Menu {
                    Button { model.send(.setTarget(nil)) } label: {
                        Text("This Mac’s language (\(Translator.name(Translator.target(nil))))",
                             comment: "Translation target menu item; %@ is a language")
                    }
                    Divider()
                    ForEach(model.targetChoices, id: \.self) { code in
                        Button { model.send(.setTarget(code)) } label: {
                            Text(verbatim: Translator.name(Locale.Language(identifier: code)))
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: Translator.name(model.target)).fontWeight(.semibold)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer(minLength: 4)
                if case .done(let text) = model.translation {
                    let id = "translation:\(model.capture?.id.uuidString ?? "")"
                    let speaking = Speaker.shared.speakingID == id
                    Button { model.send(.speak(text, id: id, language: model.target.minimalIdentifier)) } label: {
                        Image(systemName: speaking ? "stop.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .help(speaking ? Text("Stop", comment: "Card tile: stop reading aloud") : Text("Read the translation aloud"))
                    Button { model.send(.copyText(text)) } label: {
                        Image(systemName: model.justCopied == text ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help(Text("Copy the translation"))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.primary.opacity(0.85))
            translationBody
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tint.mint.color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tint.mint.color.opacity(0.22)))
        .translationTask(model.downloadRequest) { session in
            await model.translate(using: session)
        }
    }

    @ViewBuilder private var translationBody: some View {
        switch model.translation {
        case .hidden:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating on this Mac…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .done(let text):
            ScrollView(.vertical) {
                Text(verbatim: text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
        case .sameLanguage:
            note(Text("The text is already in \(Translator.name(model.target)). Pick another language above.",
                      comment: "%@ is a language"))
        case .needsDownload:
            VStack(alignment: .leading, spacing: 8) {
                note(Text("\(Translator.name(model.target)) needs to be downloaded once for on-device translation.",
                          comment: "%@ is a language"))
                HStack(spacing: 8) {
                    CardPill(title: Text("Download and Translate"), prominent: true) {
                        model.downloadRequest = .init(source: model.capture?.language.map { Locale.Language(identifier: $0) },
                                                      target: model.target)
                    }
                    CardPill(title: Text("Language Settings…")) { model.send(.openLanguageSettings) }
                }
            }
        case .unsupported:
            note(Text("Translating into \(Translator.name(model.target)) isn’t available for this text.", comment: "%@ is a language"))
        case .failed(let message):
            note(Text(verbatim: message))
        }
    }

    private func note(_ text: Text) -> some View {
        text.font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The recent captures: collapsed to one line, a click copies one again.
struct RecentSection: View {
    @Bindable var model: CardModel
    static let visible = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { model.showRecent.toggle(); model.send(.engage) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(model.showRecent ? 90 : 0))
                        Text("Recent", comment: "Section heading: recent captures").font(.system(size: 11.5, weight: .semibold))
                        Text(model.recents.count, format: .number).font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if model.showRecent {
                    Button { model.send(.clearRecent) } label: { Text("Clear", comment: "Button: forget the recent captures") }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            if model.showRecent {
                VStack(spacing: 1) {
                    ForEach(model.recents.prefix(Self.visible)) { RecentRow(capture: $0, model: model) }
                }
            }
        }
    }
}

private struct RecentRow: View {
    let capture: Capture
    let model: CardModel
    @State private var hovering = false

    var body: some View {
        Button { model.send(.show(capture)) } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(verbatim: preview)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(capture.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text("Copy again", comment: "Tooltip on a recent capture"))
    }

    private var symbol: String {
        if capture.barcodeFirst, let code = capture.barcodes.first { return code.isMatrix ? "qrcode" : "barcode" }
        switch capture.source {
        case .screen: return "text.viewfinder"
        case .file: return "doc.text"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    private var preview: String {
        capture.copiedText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ↵ ")
    }
}
