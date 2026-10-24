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
            PaletteAction(id: "reveal", title: "Show in Finder", symbol: "folder", shortcut: ActionKeys.secondary) {
                Launch.reveal(url)
                return .dismiss
            },
        ]
        if !isApp {
            list.append(PaletteAction(id: "openwith", title: "Open With…", symbol: "arrow.up.forward.app",
                                      shortcut: ActionKeys.openWith) { .push(openWithPage(url)) })
        }
        list += [
            PaletteAction(id: "copypath", title: "Copy Path", symbol: "doc.on.doc", shortcut: ActionKeys.copyPath) {
                Launch.copy(url.path)
                HUD.show("Path copied", symbol: "doc.on.doc")
                return .dismiss
            },
            PaletteAction(id: "copyfile", title: isFolder ? "Copy Folder" : isApp ? "Copy App" : "Copy File",
                          symbol: "doc.on.clipboard", shortcut: ActionKeys.copy) {
                Launch.copyFiles([url])
                HUD.show("Copied “\(url.lastPathComponent)”", symbol: "doc.on.clipboard")
                return .dismiss
            },
            PaletteAction(id: "copyname", title: "Copy Name", symbol: "textformat") {
                Launch.copy(isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
                return .dismiss
            },
            PaletteAction(id: "quicklook", title: "Quick Look", symbol: "eye", shortcut: ActionKeys.quickLook) {
                Launch.quickLook(url)
                return .stay
            },
        ]
        if isFolder {
            list.append(PaletteAction(id: "terminal", title: "Open in \(terminal.title)", symbol: "terminal",
                                      shortcut: ActionKeys.terminal) {
                Launch.openTerminal(at: url, app: terminal)
                return .dismiss
            })
        } else {
            list.append(PaletteAction(id: "terminalhere", title: "Open Enclosing Folder in \(terminal.title)", symbol: "terminal",
                                      shortcut: ActionKeys.terminal) {
                Launch.openTerminal(at: url.deletingLastPathComponent(), app: terminal)
                return .dismiss
            })
        }
        if isApp {
            list.append(PaletteAction(id: "contents", title: "Show Package Contents", symbol: "shippingbox") {
                Launch.reveal(url.appendingPathComponent("Contents"))
                return .dismiss
            })
            if let bid = Bundle(url: url)?.bundleIdentifier {
                list.append(PaletteAction(id: "copybid", title: "Copy Bundle Identifier", symbol: "number") {
                    Launch.copy(bid)
                    HUD.show(bid, symbol: "doc.on.doc")
                    return .dismiss
                })
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                    list.append(PaletteAction(id: "hide", title: "Hide App", symbol: "eye.slash") {
                        running.hide()
                        return .dismiss
                    })
                    list.append(PaletteAction(id: "quit", title: "Quit App", symbol: "xmark.circle", shortcut: ActionKeys.quit) {
                        running.terminate()
                        return .refresh
                    })
                    list.append(PaletteAction(id: "forcequit", title: "Force Quit App", symbol: "xmark.octagon", destructive: true) {
                        .confirm(Confirmation(title: "Force quit \(running.localizedName ?? "the app")?",
                                              message: "Unsaved changes will be lost.", confirmTitle: "Force Quit") {
                            running.forceTerminate()
                            return .refresh
                        })
                    })
                }
            }
        }
        list.append(PaletteAction(id: "trash", title: "Move to Trash", symbol: "trash", shortcut: ActionKeys.trash,
                                  destructive: true) {
            .confirm(Confirmation(title: "Move “\(url.lastPathComponent)” to the Trash?",
                                  message: url.deletingLastPathComponent().path, confirmTitle: "Move to Trash") {
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
        ListPage(id: "files:openwith:\(url.path)", title: "Open “\(url.lastPathComponent)” With",
                 placeholder: "Search apps…", icon: .file(url.path)) { text in
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            let items = apps.map { app -> PaletteItem in
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                return PaletteItem(
                    id: "files:openwith:\(app.path)", title: name,
                    subtitle: app == defaultApp ? "Default app" : app.deletingLastPathComponent().path,
                    icon: .file(app.path), providerID: "files", accessory: app == defaultApp ? "Default" : nil,
                    score: app == defaultApp ? 1 : 0,
                    primary: PaletteAction(id: "open", title: "Open", symbol: "arrow.up.forward.app") {
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
                size = "\(count) items"
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
            DetailRow(label: "Kind", value: info.0, monospaced: false),
            DetailRow(label: "Size", value: info.1, monospaced: false),
            DetailRow(label: "Modified", value: info.2, monospaced: false),
            DetailRow(label: "Created", value: info.3, monospaced: false),
        ]
        if isApp, let bundle = Bundle(url: url) {
            if let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                rows.insert(DetailRow(label: "Version", value: v), at: 1)
            }
            if let bid = bundle.bundleIdentifier { rows.append(DetailRow(label: "Bundle ID", value: bid)) }
        }
        rows.append(DetailRow(label: "Where", value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                              monospaced: false))
        return ItemDetails(icon: .file(url.path), title: isApp ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                           subtitle: nil, rows: rows, previewFile: isApp ? nil : url)
    }
}
