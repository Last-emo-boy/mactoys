import AppKit
import MacToysCore
import PreviewKit
import SwiftUI

/// State of the Peek window, driven by `PeekController`.
@MainActor
@Observable
final class PeekModel {
    var items = PeekItems([])
    var content: PeekContent = .loading
    var fields: [PeekField] = []
    /// "Photos" for "Open with Photos".
    var defaultApp: String?
    var pinned = false
    var showDetails = true
    /// Draw stand-in window buttons (offscreen scenes have no real title bar).
    var drawsWindowButtons = false

    @ObservationIgnored var onPrevious: () -> Void = {}
    @ObservationIgnored var onNext: () -> Void = {}
    @ObservationIgnored var onOpen: () -> Void = {}
    @ObservationIgnored var onTogglePin: () -> Void = {}
}

/// Design 07: title "name — 3 of 6", previous/next, "Open with …", content, metadata footer.
struct PeekView: View {
    @Bindable var model: PeekModel
    static let headerHeight: CGFloat = 52
    static let footerHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showDetails && !model.fields.isEmpty {
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.drawsWindowButtons {
                HStack(spacing: 8) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)],
                            id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
                }
                .padding(.trailing, 14)
            } else {
                Color.clear.frame(width: 70, height: 1)       // room for the window buttons
            }
            Text(model.items.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.items.current?.path ?? "")
            Spacer(minLength: 12)
            Button(action: model.onTogglePin) {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(model.pinned ? Color.accentColor : .secondary)
            .help(model.pinned ? "Unpin: fit the window to each file" : "Pin the window's position and size")
            if model.items.count > 1 {
                HStack(spacing: 6) {
                    Button(action: model.onPrevious) { Image(systemName: "chevron.left").frame(width: 14, height: 14) }
                        .help("Previous (←)")
                    Button(action: model.onNext) { Image(systemName: "chevron.right").frame(width: 14, height: 14) }
                        .help("Next (→)")
                }
                .buttonStyle(.bordered)
            }
            if model.items.current != nil {
                Button(action: model.onOpen) {
                    Text(model.defaultApp.map { "Open with \($0)" } ?? "Open").lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .help("Open with the default app (⌘↩)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.headerHeight)
        .focusable(false)
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .html(let html):
            PeekWebView(html: html)
        case .image(let image, let style):
            PeekCanvas(image: image, style: style)
        case .quickLook(let url):
            PeekQuickLookView(url: url).id(url)
        case .folder(let url):
            PeekFolderView(url: url)
        case .details(let message):
            PeekDetailsView(url: model.items.current, message: message)
        case .empty:
            PeekDetailsView(url: nil, message: "No more files to preview.")
        }
    }

    private var footer: some View {
        HStack(spacing: 18) {
            ForEach(model.fields, id: \.self) { field in
                HStack(spacing: 5) {
                    Text(field.label).foregroundStyle(.secondary)
                    Text(field.value).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 14)
        .frame(height: Self.footerHeight)
    }
}
