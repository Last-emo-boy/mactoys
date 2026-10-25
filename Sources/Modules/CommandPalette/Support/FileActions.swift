import AppKit
import MacToysCore

/// The actions every file, folder and app result offers.
@MainActor
enum FileActions {
    /// Secondary actions for a file system item (the primary "Open" is the caller's).
    static func actions(for url: URL, terminal: TerminalApp) -> [PaletteAction] {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isApp = url.pathExtension == "app"
        let isFolder = isDir.boolValue && !isApp
        var list: [PaletteAction] = [
            PaletteAction(id: "reveal", title: Labels.showInFinder, symbol: "folder", shortcut: ActionKeys.secondary) {
                Launch.reveal(url)
                return .dismiss
            },
        ]
        if !isApp {
            list.append(PaletteAction(id: "openwith", title: String(localized: "Open With…", comment: "Action: choose an app to open the file with"),
                                      symbol: "arrow.up.forward.app",
                                      shortcut: ActionKeys.openWith) { .push(openWithPage(url)) })
        }
        list += [
            PaletteAction(id: "copypath", title: Labels.copyPath, symbol: "doc.on.doc", shortcut: ActionKeys.copyPath) {
                Launch.copy(url.path)
                HUD.show("Path copied", symbol: "doc.on.doc")
                return .dismiss
            },
            PaletteAction(id: "copyfile",
                          title: isFolder ? String(localized: "Copy Folder") : isApp ? String(localized: "Copy App") : String(localized: "Copy File"),
                          symbol: "doc.on.clipboard", shortcut: ActionKeys.copy) {
                Launch.copyFiles([url])
                HUD.show("Copied “\(url.lastPathComponent)”", symbol: "doc.on.clipboard")
                return .dismiss
            },
            PaletteAction(id: "copyname", title: String(localized: "Copy Name"), symbol: "textformat") {
                Launch.copy(isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
                return .dismiss
            },
            PaletteAction(id: "quicklook", title: String(localized: "Quick Look", comment: "Action: preview the file with Quick Look; use the name macOS shows"),
                          symbol: "eye", shortcut: ActionKeys.quickLook) {
                Launch.quickLook(url)
                return .stay
            },
        ]
        if isFolder {
            list.append(PaletteAction(id: "terminal", title: Labels.openIn(terminal.title), symbol: "terminal",
                                      shortcut: ActionKeys.terminal) {
                Launch.openTerminal(at: url, app: terminal)
                return .dismiss
            })
        } else {
            list.append(PaletteAction(id: "terminalhere",
                                      title: String(localized: "Open Folder in \(terminal.title)", comment: "Action; %@ is a terminal app such as Terminal"),
                                      symbol: "terminal",
                                      shortcut: ActionKeys.terminal) {
                Launch.openTerminal(at: url.deletingLastPathComponent(), app: terminal)
                return .dismiss
            })
        }
        if isApp {
            list.append(PaletteAction(id: "contents", title: String(localized: "Show Package Contents", comment: "Action; use the name Finder shows"),
                                      symbol: "shippingbox") {
                Launch.reveal(url.appendingPathComponent("Contents"))
                return .dismiss
            })
            if let bid = Bundle(url: url)?.bundleIdentifier {
                list.append(PaletteAction(id: "copybid", title: String(localized: "Copy Bundle Identifier"), symbol: "number") {
                    Launch.copy(bid)
                    HUD.show(bid, symbol: "doc.on.doc")
                    return .dismiss
                })
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                    list.append(PaletteAction(id: "hide", title: String(localized: "Hide App"), symbol: "eye.slash") {
                        running.hide()
                        return .dismiss
                    })
                    list.append(PaletteAction(id: "quit", title: String(localized: "Quit App"), symbol: "xmark.circle", shortcut: ActionKeys.quit) {
                        running.terminate()
                        return .refresh
                    })
                    list.append(PaletteAction(id: "forcequit", title: String(localized: "Force Quit App"), symbol: "xmark.octagon", destructive: true) {
                        let question = running.localizedName.map {
                            String(localized: "Force quit \($0)?", comment: "Confirmation prompt; %@ is an app name")
                        } ?? String(localized: "Force quit the app?")
                        return .confirm(Confirmation(title: question, message: String(localized: "Unsaved changes will be lost."),
                                                     confirmTitle: String(localized: "Force Quit", comment: "Confirmation button: force the app to quit")) {
                            running.forceTerminate()
                            return .refresh
                        })
                    })
                }
            }
        }
        list.append(PaletteAction(id: "trash", title: String(localized: "Move to Trash"), symbol: "trash", shortcut: ActionKeys.trash,
                                  destructive: true) {
            .confirm(Confirmation(title: String(localized: "Move “\(url.lastPathComponent)” to the Trash?", comment: "Confirmation prompt; %@ is a file name"),
                                  message: url.deletingLastPathComponent().path, confirmTitle: String(localized: "Move to Trash")) {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    HUD.show("Moved to Trash", symbol: "trash")
                } catch {
                    HUD.show(error.localizedDescription, symbol: "exclamationmark.triangle")
                }
                return .refresh
            })
        })
        return list
    }

    /// A page listing the apps that can open a file.
    static func openWithPage(_ url: URL) -> ListPage {
        ListPage(id: "files:openwith:\(url.path)", title: String(localized: "Open “\(url.lastPathComponent)” With", comment: "Page title; %@ is a file name"),
                 placeholder: String(localized: "Search apps…"), icon: .file(url.path)) { text in
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            let items = apps.map { app -> PaletteItem in
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                return PaletteItem(
                    id: "files:openwith:\(app.path)", title: name,
                    subtitle: app == defaultApp ? String(localized: "Default app") : app.deletingLastPathComponent().path,
                    icon: .file(app.path), providerID: "files",
                    accessory: app == defaultApp ? String(localized: "Default", comment: "Result row label: the default app for the file") : nil,
                    score: app == defaultApp ? 1 : 0,
                    primary: PaletteAction(id: "open", title: Labels.open, symbol: "arrow.up.forward.app") {
                        Launch.open(url, withApplicationAt: app)
                        return .dismiss
                    },
                    isPinnable: false)
            }
            let filtered = fuzzyFilter(items, text)
            return text.isEmpty ? filtered.sorted { $0.score > $1.score } : filtered
        }
    }

    /// Detail pane for a file: thumbnail, kind, size, dates.
    static func details(for url: URL) async -> ItemDetails {
        let info = await background { () -> (String, String, String, String) in
            let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .totalFileSizeKey,
                                                           .contentModificationDateKey, .creationDateKey, .isDirectoryKey])
            let kind = values?.localizedTypeDescription ?? ""
            let size: String
            if values?.isDirectory == true && url.pathExtension != "app" {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
                size = String(localized: "\(count) items", comment: "How many items: results on a page, or entries in a folder")
            } else {
                size = ByteCountFormatter.string(fromByteCount: Int64(values?.totalFileSize ?? values?.fileSize ?? 0),
                                                 countStyle: .file)
            }
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let modified = values?.contentModificationDate.map { f.string(from: $0) } ?? "—"
            let created = values?.creationDate.map { f.string(from: $0) } ?? "—"
            return (kind, size, modified, created)
        }
        let isApp = url.pathExtension == "app"
        var rows = [
            DetailRow(label: Labels.kind, value: info.0, monospaced: false),
            DetailRow(label: Labels.size, value: info.1, monospaced: false),
            DetailRow(label: String(localized: "Modified", comment: "Detail row: when the file was last changed"), value: info.2, monospaced: false),
            DetailRow(label: String(localized: "Created", comment: "Detail row: when the file was created"), value: info.3, monospaced: false),
        ]
        if isApp, let bundle = Bundle(url: url) {
            if let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                rows.insert(DetailRow(label: String(localized: "Version", comment: "Detail row: the app's version"), value: v), at: 1)
            }
            if let bid = bundle.bundleIdentifier { rows.append(DetailRow(label: String(localized: "Bundle ID"), value: bid)) }
        }
        rows.append(DetailRow(label: Labels.location, value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                              monospaced: false))
        return ItemDetails(icon: .file(url.path), title: isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                           subtitle: nil, rows: rows, previewFile: isApp ? nil : url)
    }
}
