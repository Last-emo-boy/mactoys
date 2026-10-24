import AdvancedPaste
import AppKit
import Awake
import CommandNotFound
import FancyZones
import FileLocksmith
import Foundation
import ImageResizer
import LightSwitch
import MacToysCore
import PowerDisplay

/// Per-utility subcommands. Each entry returns the process exit code.
/// Modules that ship their own argument parser (`AwakeCLI.run` …) get the remaining arguments,
/// with `--json` passed back when the user gave it.
@MainActor
enum ModuleCommands {
    typealias Handler = @MainActor ([String]) async throws -> Int32

    private static func withJSON(_ args: [String]) -> [String] { CLI.json ? args + ["--json"] : args }
    private static func files(_ args: [String]) -> [URL] {
        args.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    static let table: [String: Handler] = [
        "awake": { AwakeCLI.run(withJSON($0)) },
        "lightswitch": { LightSwitchCLI.run(withJSON($0)) },
        "powerdisplay": { PowerDisplayCLI.run(withJSON($0)) },
        "cnf": { CommandNotFound.run(withJSON($0)) },
        "paste": paste,
        "resize": resize,
        "locksmith": locksmith,
        "zones": zones,
        "peek": { args in
            CLI.open(AppCommand(module: "peek", action: "open", files: files(args)))
            return 0
        },
        "rename": { args in
            CLI.open(AppCommand(module: "powerrename", action: "open", files: files(args)))
            return 0
        },
        "colorpicker": { _ in CLI.open(AppCommand(module: "colorpicker", action: "pick")); return 0 },
        "ocr": { args in
            CLI.open(AppCommand(module: "textextractor", action: "capture",
                                parameters: args.first.map { ["mode": $0] } ?? [:]))
            return 0
        },
        "workspace": { args in
            guard let name = args.first else { throw CLIError("usage: mactoys workspace <name>", code: 64) }
            CLI.open(AppCommand(module: "workspaces", action: "launch", parameters: ["name": name]))
            return 0
        },
        "palette": { args in
            CLI.open(AppCommand(module: "cmdpal", action: "show",
                                parameters: args.isEmpty ? [:] : ["query": args.joined(separator: " ")]))
            return 0
        },
    ]

    static let help = """
      awake [status|off|on|for <h:m>|until <time>] …
                                     Keep the Mac awake (see `mactoys awake --help`)
      lightswitch [status|light|dark|toggle|schedule …]
                                     Switch appearance (see `mactoys lightswitch --help`)
      powerdisplay [list|get|set|up|down|profiles|apply-profile] …
                                     Control displays over DDC/CI (see `mactoys powerdisplay --help`)
      paste <action> [file] [--out <file>]
                                     Advanced Paste transform of a file, stdin or the clipboard;
                                     actions: plain-text, markdown, json, image-to-text, …
      resize <files…> [--preset <name|index>]
                                     Resize images with an Image Resizer preset
      locksmith <paths…>             List processes using files or folders
      zones [layout]                 Print FancyZones layout geometry for the main display
      peek <files…>                  Preview files in Peek
      rename <files…>                Open PowerRename with these files
      colorpicker                    Pick a color from the screen
      ocr [lines|table|singleLine]   Copy text from a screen region
      workspace <name>               Launch a saved workspace
      palette [query]                Open Command Palette
      cnf <command>                  Suggest the Homebrew formula providing a command
    """

    // MARK: Advanced Paste

    /// `mactoys paste json data.csv` · `pbpaste | mactoys paste markdown` · `mactoys paste plain-text` (clipboard)
    static func paste(_ args: [String]) async throws -> Int32 {
        var rest = args
        var outPath: String?
        if let i = rest.firstIndex(of: "--out"), i + 1 < rest.count {
            outPath = rest[i + 1]
            rest.removeSubrange(i...i + 1)
        }
        guard let name = rest.first else {
            let names = AdvancedPasteTransforms.Action.builtIns.map(\.name).joined(separator: ", ")
            throw CLIError("usage: mactoys paste <action> [file] [--out <file>]\nactions: \(names)", code: 64)
        }
        guard let action = AdvancedPasteTransforms.Action(name: name) else {
            throw CLIError("unknown action '\(name)'", code: 64)
        }
        let input: AdvancedPasteTransforms.Input
        if let path = rest.dropFirst().first {
            input = try AdvancedPasteTransforms.Input(contentsOf: URL(fileURLWithPath: path))
        } else if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            // Piped HTML (`curl … | mactoys paste markdown`) is converted as HTML, not as literal text.
            let looksLikeHTML = text.range(of: #"<(html|body|p|div|h[1-6]|ul|ol|table|a|b|strong|em|br|span)[\s>/]"#,
                                           options: [.regularExpression, .caseInsensitive]) != nil
            input = AdvancedPasteTransforms.Input(text: text, html: looksLikeHTML ? text : nil)
        } else {
            input = AdvancedPasteTransforms.Input(pasteboard: .general)
        }
        let output = try await AdvancedPasteTransforms.apply(action, to: input)
        switch output {
        case .text(let text):
            if let outPath {
                try Data(text.utf8).write(to: URL(fileURLWithPath: outPath))
            } else {
                print(text)
            }
        case .file(let url):
            if let outPath {
                let dest = URL(fileURLWithPath: outPath)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                print(dest.path)
            } else {
                print(url.path)
            }
        }
        return 0
    }

    // MARK: Image Resizer

    static func resize(_ args: [String]) throws -> Int32 {
        var rest = args
        let settings = SettingsStore.shared.load("imageresizer", default: ImageResizerSettings())
        var preset = settings.selectedPreset
        if let i = rest.firstIndex(of: "--preset"), i + 1 < rest.count {
            let key = rest[i + 1]
            rest.removeSubrange(i...i + 1)
            if let n = Int(key), settings.presets.indices.contains(n) {
                preset = settings.presets[n]
            } else if let p = settings.presets.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                preset = p
            } else {
                let names = settings.presets.enumerated().map { "\($0.offset) \($0.element.name)" }.joined(separator: ", ")
                throw CLIError("unknown preset '\(key)'. Presets: \(names)", code: 64)
            }
        }
        let urls = files(rest)
        guard !urls.isEmpty else { throw CLIError("usage: mactoys resize <files…> [--preset <name|index>]", code: 64) }
        do {
            let written = try ImageResizerEngine.resize(urls: urls, preset: preset, options: settings.options)
            if CLI.json { CLI.emit(written.map(\.path)) } else { written.forEach { print($0.path) } }
            return 0
        } catch let e as ImageResizerEngine.BatchError {
            e.outputs.forEach { print($0.path) }
            throw CLIError(e.errorDescription ?? "resize failed")
        }
    }

    // MARK: File Locksmith

    static func locksmith(_ args: [String]) throws -> Int32 {
        let urls = files(args)
        guard !urls.isEmpty else { throw CLIError("usage: mactoys locksmith <paths…>", code: 64) }
        let report = FileLocksmithScanner.scanReport(paths: urls)
        if CLI.json {
            let data = try JSONEncoder().encode(report.processes)
            print(String(decoding: data, as: UTF8.self))
        } else if report.processes.isEmpty {
            print("No process is using \(urls.count == 1 ? urls[0].path : "these paths").")
        } else {
            for p in report.processes {
                print("\(p.pid)\t\(p.user)\t\(p.name)")
                for f in p.files.prefix(20) { print("\t\t\(f.path)") }
                if p.files.count > 20 { print("\t\t… \(p.files.count - 20) more") }
            }
        }
        if report.inaccessible > 0 && !CLI.json {
            FileHandle.standardError.write(Data("\(report.inaccessible) processes of other users were not checked (open MacToys › File Locksmith › Restart as Administrator).\n".utf8))
        }
        return report.processes.isEmpty ? 1 : 0
    }

    // MARK: FancyZones

    static func zones(_ args: [String]) throws -> Int32 {
        let library = SettingsStore.shared.load(LayoutLibrary.storageID, default: LayoutLibrary()).normalized()
        let settings = SettingsStore.shared.load("fancyzones", default: FancyZonesSettings())
        guard let screen = NSScreen.main else { throw CLIError("no display") }
        let layout: ZoneLayout
        if let key = args.first {
            guard let found = library.resolve(key) else {
                throw CLIError("unknown layout '\(key)'. Layouts: \(library.all.map(\.name).joined(separator: ", "))", code: 64)
            }
            layout = found
        } else {
            // Same key FancyZones uses for a single display (stable vendor/model/serial id).
            layout = library.layout(forDisplay: screen.stableID, vertical: screen.frame.height > screen.frame.width,
                                    defaultHorizontal: settings.defaultHorizontalLayout,
                                    defaultVertical: settings.defaultVerticalLayout)
        }
        let rects = ZoneGeometry.zones(for: layout, in: screen.axVisibleFrame, spacing: CGFloat(layout.effectiveSpacing))
        if CLI.json {
            CLI.emit(rects.enumerated().map { i, r in
                ["zone": i + 1, "x": Int(r.minX), "y": Int(r.minY), "width": Int(r.width), "height": Int(r.height)]
            })
        } else {
            print("\(layout.name) on \(screen.localizedName)")
            print(ZoneGeometry.preview(layout))
            for (i, r) in rects.enumerated() {
                print("  \(i + 1): x \(Int(r.minX)) y \(Int(r.minY)) · \(Int(r.width)) × \(Int(r.height))")
            }
        }
        return 0
    }
}
