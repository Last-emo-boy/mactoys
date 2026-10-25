import AppKit
import PreviewKit
import Quartz
import SwiftUI
import WebKit

/// A PreviewKit page. JavaScript is off; links open in the default browser, `#anchors` scroll.
struct PeekWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.allowsMagnification = true
        view.setAccessibilityLabel(String(localized: "Preview", comment: "Accessibility label: the area showing the file's contents"))
        context.coordinator.load(html, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html, into: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded: String?

        func load(_ html: String, into view: WKWebView) {
            guard html != loaded else { return }
            loaded = html
            view.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            if url.fragment != nil, url.scheme == "about" || url.absoluteString.hasPrefix("about:blank") { return .allow }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            return .cancel
        }
    }
}

/// macOS's own previewer for everything PreviewKit doesn't render.
struct PeekQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.shouldCloseWithWindow = false
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

/// A rendered bitmap centered on a dark, checkered or light canvas.
struct PeekCanvas: View {
    let image: CGImage
    let style: PeekContent.CanvasStyle

    var body: some View {
        ZStack {
            switch style {
            case .dark: Color(red: 0.07, green: 0.07, blue: 0.08)
            case .light: Color.white
            case .checkerboard: Checkerboard()
            }
            Image(decorative: image, scale: 2)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: CGFloat(image.width) / 2, maxHeight: CGFloat(image.height) / 2)
                .padding(style == .dark ? 0 : 24)
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.17)))
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.22)))
                    x += 2 * s
                }
                y += s
                row += 1
            }
        }
    }
}

/// Folder summary with live counts while the scan runs.
struct PeekFolderView: View {
    let url: URL
    @State private var summary = FolderSummary()

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 96, height: 96)
            Text(url.lastPathComponent).font(.system(size: 17, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            VStack(spacing: 6) {
                HStack(spacing: 18) {
                    stat(summary.files, Text("Files", comment: "Folder summary: label under the number of files"))
                    stat(summary.folders, Text("Folders", comment: "Folder summary: label under the number of subfolders"))
                    VStack(spacing: 2) {
                        Text(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file))
                            .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        Text("Total", comment: "Folder summary: label under the size of everything in the folder")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !summary.finished {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Counting…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else if summary.incomplete {
                    Label("Some folders couldn't be read — counts are incomplete", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(.orange)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            summary = FolderSummary()
            for await s in FolderSummary.stream(url) { summary = s }
        }
    }

    /// A count with its label underneath. The label is a heading ("Files"), not a noun agreeing with
    /// the number, so it reads right in every language without plural forms.
    private func stat(_ n: Int, _ label: Text) -> some View {
        VStack(spacing: 2) {
            Text(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal))
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
            label.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// No preview available: the file's icon and why.
struct PeekDetailsView: View {
    let url: URL?
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 96, height: 96)
                Text(url.lastPathComponent).font(.system(size: 16, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
            }
            Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
