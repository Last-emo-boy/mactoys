import AppKit
import MacToysCore
import SwiftUI
import UniformTypeIdentifiers

struct PlistSettings: Codable, Equatable {
    var newDocumentFormat: PlistFormat = .xml
    /// After writing the Dock's (Finder's…) domain, offer to relaunch it so the change shows.
    var offerRelaunch = true
    var recentFiles: [String] = []
}

/// The macOS counterpart of Registry Preview: views and edits property lists (XML, binary, JSON),
/// compares them with disk, writes them into defaults domains and browses existing domains.
@MainActor
public final class PlistPreviewModule: ToyModule {
    public let info = ModuleInfo(
        id: "plistpreview", name: "Plist Preview",
        summary: "Inspect, edit and compare property lists and defaults domains.",
        symbol: "list.bullet.indent", tint: .brown, category: .advanced,
        permissions: [], enabledByDefault: true,
        keywords: ["plist", "property list", "defaults", "preferences", "registry", "json", "xml"])

    let settings = Persisted("plistpreview", default: PlistSettings())
    private let log = Log.for("plistpreview")
    private var controllers: [PlistWindowController] = []
    private var browser: NSWindow?

    public init() {}

    public func start() {}

    public func stop() {
        for c in controllers { c.window.close() }
        controllers.removeAll()
        browser?.close()
        settings.flush()
    }

    // MARK: - Documents

    func newDocument() {
        let doc = PlistDocument.untitled()
        doc.format = settings.value.newDocumentFormat
        show(doc)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .json, .xmlPropertyList, .binaryPropertyList, .data]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose property lists or JSON files")
        NSApp.activate()
        if panel.runModal() == .OK { open(panel.urls) }
    }

    /// Opens files in windows; an untitled, unedited `replacing` document is reused for the first one.
    func open(_ urls: [URL], replacing: PlistDocument? = nil) {
        for (i, url) in urls.enumerated() {
            if let existing = controllers.first(where: { $0.doc.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                existing.window.makeKeyAndOrderFront(nil)
                continue
            }
            do {
                let doc = try PlistDocument.open(url)
                if i == 0, let replacing, replacing.fileURL == nil, replacing.domain == nil, !replacing.isDirty,
                   let c = controllers.first(where: { $0.doc === replacing }) {
                    c.replace(with: doc)
                } else {
                    show(doc)
                }
                settings.update {
                    $0.recentFiles.removeAll { $0 == url.path }
                    $0.recentFiles.insert(url.path, at: 0)
                    if $0.recentFiles.count > 10 { $0.recentFiles.removeLast($0.recentFiles.count - 10) }
                }
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn't open \(url.lastPathComponent)", comment: "The placeholder is a file name")
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
                log.error("open \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func openDomain(_ domain: String, root: PlistNode) {
        let doc = PlistDocument(root: root.copyWithNewIDs(), domain: domain)
        show(doc)
    }

    private func show(_ doc: PlistDocument) {
        let c = PlistWindowController(doc: doc, module: self)
        controllers.append(c)
        c.window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func closed(_ controller: PlistWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func save(_ doc: PlistDocument) {
        guard doc.fileURL != nil else { saveAs(doc); return }
        do { try doc.save() } catch { doc.message = .init(kind: .error, text: error.localizedDescription) }
    }

    func saveAs(_ doc: PlistDocument) {
        let panel = NSSavePanel()
        let format = doc.format == .openStep ? .xml : doc.format
        panel.allowedContentTypes = format == .json ? [.json] : [.propertyList]
        panel.nameFieldStringValue = doc.fileURL?.lastPathComponent ?? (doc.domain.map { "\($0).plist" } ?? PlistDocument.untitledName)
        panel.canCreateDirectories = true
        let window = controllers.first { $0.doc === doc }?.window
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try doc.write(to: url, format: url.pathExtension.lowercased() == "json" ? .json : format) }
            catch { doc.message = .init(kind: .error, text: error.localizedDescription) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// After `defaults import` into the Dock's or Finder's domain, offers to relaunch it.
    func offerRelaunch(for domain: String) {
        guard settings.value.offerRelaunch, let process = DefaultsDomains.relaunchTarget(for: domain) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Relaunch \(process) to apply the change?", comment: "The placeholder is an app such as Dock or Finder")
        alert.informativeText = String(localized: "\(process) reads its preferences when it starts.",
                                       comment: "The placeholder is an app such as Dock or Finder")
        alert.addButton(withTitle: String(localized: "Relaunch \(process)", comment: "Button; the placeholder is an app such as Dock or Finder"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        if alert.runModal() == .alertFirstButtonReturn { Shell.run("/usr/bin/killall", [process]) }
    }

    func showDefaultsBrowser() {
        if browser == nil {
            let controller = NSHostingController(rootView: DefaultsBrowserView(module: self))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: controller)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbar = NSToolbar(identifier: "defaults")
            w.toolbarStyle = .unified
            w.title = String(localized: "Defaults Domains")
            w.setContentSize(NSSize(width: 900, height: 560))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacToysDefaultsBrowser")
            if w.frame.origin == .zero { w.center() }
            browser = w
        }
        NSApp.activate()
        browser?.makeKeyAndOrderFront(nil)
    }

    // MARK: - ToyModule

    public func settingsView() -> AnyView { AnyView(PlistSettingsView(module: self)) }

    public var quickActions: [QuickAction] {
        [QuickAction(id: "plistpreview.open", title: "Plist Preview", symbol: "list.bullet.indent", tint: .brown,
                     perform: { [weak self] in self?.showOpenPanel() })]
    }

    /// `mactoys://plistpreview/<action>`: `open` (with `file=` parameters, else an open panel), `new`,
    /// `defaults` (domain browser; `domain=` opens one as a document), `settings`.
    /// `.plist` files opened with MacToys arrive as `open` with files.
    public func handle(_ command: AppCommand) -> Bool {
        switch command.action {
        case "open", "show":
            if command.files.isEmpty { showOpenPanel() } else { open(command.files) }
        case "new":
            newDocument()
        case "defaults", "domains":
            if let domain = command.parameters["domain"], !domain.isEmpty {
                do { openDomain(domain, root: try DefaultsDomains.export(domain)) } catch { return false }
            } else {
                showDefaultsBrowser()
            }
        case "settings":
            ModuleRegistry.shared.showSettings?(info.id)
        default:
            return false
        }
        return true
    }

    public var previewScenes: [PreviewScene] {
        [PreviewScene("window", size: CGSize(width: 820, height: 520), wallpaper: false) { AnyView(PlistDocumentView.preview()) }]
    }
}

/// One document window; asks before closing with unsaved edits.
@MainActor
final class PlistWindowController: NSObject, NSWindowDelegate {
    private(set) var doc: PlistDocument
    let window: NSWindow
    private let context = PlistWindowContext()
    private weak var module: PlistPreviewModule?

    init(doc: PlistDocument, module: PlistPreviewModule) {
        self.doc = doc
        self.module = module
        let controller = NSHostingController(rootView: PlistDocumentView(doc: doc, context: context))
        controller.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentViewController: controller)
        super.init()
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "plist")
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 820, height: 560))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacToysPlistPreview")
        context.window = window
        context.module = module
        context.update(doc)
    }

    func replace(with newDoc: PlistDocument) {
        doc = newDoc
        (window.contentViewController as? NSHostingController<PlistDocumentView>)?.rootView = PlistDocumentView(doc: newDoc, context: context)
        context.update(newDoc)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard doc.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to \(doc.displayName)?", comment: "The placeholder is a document name")
        alert.informativeText = String(localized: "Your changes will be lost if you don't save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if doc.fileURL == nil { module?.saveAs(doc); return false }
            do { try doc.save(); return true } catch {
                doc.message = .init(kind: .error, text: error.localizedDescription)
                return false
            }
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        module?.closed(self)
    }
}

struct PlistSettingsView: View {
    let module: PlistPreviewModule
    @Bindable var s: Persisted<PlistSettings>
    @State private var defaultApp: String = ""

    init(module: PlistPreviewModule) {
        self.module = module
        self.s = module.settings
    }

    var body: some View {
        SettingsPage(module: module) {
            HeroCard(tint: .brown) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Property lists, JSON and defaults domains").font(.system(size: 14, weight: .semibold))
                        Text("Drop a .plist on the window, or open one from Finder with MacToys.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Browse Defaults…") { module.showDefaultsBrowser() }
                    Button("New") { module.newDocument() }
                    Button("Open…") { module.showOpenPanel() }.buttonStyle(.borderedProminent)
                }
            }
        } content: {
            Section("Files") {
                LabeledContent {
                    Button("Make MacToys the Default") { makeDefault() }
                        .disabled(defaultApp == "MacToys")
                } label: {
                    RowLabel(title: Text("Default app for property lists"),
                             subtitle: defaultApp.isEmpty ? Text("Checking…") : Text("Currently \(defaultApp)", comment: "The placeholder is an app name"))
                }
                Picker(selection: $s.value.newDocumentFormat) {
                    Text(PlistFormat.xml.title).tag(PlistFormat.xml)
                    Text(PlistFormat.binary.title).tag(PlistFormat.binary)
                    Text(PlistFormat.json.title).tag(PlistFormat.json)
                } label: {
                    RowLabel("Format for new documents", subtitle: "Opened files are always saved in their own format.")
                }
                if !s.value.recentFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        RowLabel("Recent files")
                        ForEach(s.value.recentFiles, id: \.self) { path in
                            Button(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                                module.open([URL(fileURLWithPath: path)])
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 12, design: .monospaced))
                        }
                        Button("Clear") { s.value.recentFiles = [] }.controlSize(.small)
                    }
                }
            }

            Section("Defaults") {
                Toggle(isOn: $s.value.offerRelaunch) {
                    RowLabel("Offer to relaunch the Dock, Finder or SystemUIServer",
                             subtitle: "They only read their preferences at launch, so a written domain shows after a relaunch.")
                }
                Text("Write to defaults always asks first: it replaces the whole domain (defaults import). Browsing domains is read-only until you open one as a document.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: refreshDefaultApp)
    }

    private func refreshDefaultApp() {
        if let url = NSWorkspace.shared.urlForApplication(toOpen: .propertyList) {
            defaultApp = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else {
            defaultApp = String(localized: "none", comment: "No app opens property lists by default")
        }
    }

    private func makeDefault() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .propertyList) { error in
            DispatchQueue.main.async {
                if let error { Log.for("plistpreview").error("default app: \(error.localizedDescription, privacy: .public)") }
                MainActor.assumeIsolated { refreshDefaultApp() }
            }
        }
    }
}
