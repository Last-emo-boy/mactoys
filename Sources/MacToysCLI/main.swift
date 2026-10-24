import AppKit
import MacToysCore
import MacToysModules

/// `mactoys` — the command-line companion. Commands that need the running app go through
/// `mactoys://` URLs; the rest run in-process against the same module code.
@MainActor
enum CLI {
    nonisolated(unsafe) static var json = false

    static func main() async -> Int32 {
        var args = Array(CommandLine.arguments.dropFirst())
        if let i = args.firstIndex(of: "--json") { json = true; args.remove(at: i) }
        guard let command = args.first else { usage(); return 0 }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "help", "-h", "--help": usage()
            case "--version", "version": print(version)
            case "modules": try modules(rest)
            case "open": try openURL(rest)
            case "settings":
                open(AppCommand(module: "app", action: "settings", parameters: rest.first.map { ["page": $0] } ?? [:]))
            default:
                if let handler = ModuleCommands.table[command] {
                    return try await handler(rest)
                }
                fail("unknown command '\(command)'. Run `mactoys help`.")
                return 64
            }
        } catch let e as CLIError {
            fail(e.message)
            return e.code
        } catch {
            fail(error.localizedDescription)
            return 1
        }
        return 0
    }

    static var version: String {
        let plist = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: plist)
        return "mactoys \(info?["CFBundleShortVersionString"] as? String ?? "dev")"
    }

    static func usage() {
        print("""
        mactoys — command-line companion for MacToys

        Usage: mactoys <command> [arguments] [--json]

        General
          modules [list]                 List utilities and whether they are on
          modules enable|disable <id>…   Turn utilities on or off (works while MacToys is closed)
          open <module> [action] [k=v…] [files…]
                                         Send a mactoys:// request to the running app
          settings [page]                Open MacToys Settings (page = module id)

        Utilities
        \(ModuleCommands.help)
        """)
    }

    // MARK: modules

    static func modules(_ args: [String]) throws {
        let store = SettingsStore.shared
        var general = store.load("general", default: GeneralSettings())
        let catalog = ModuleCatalog.all
        let sub = args.first ?? "list"
        switch sub {
        case "list":
            let rows = catalog.map { m -> [String: Any] in
                ["id": m.id, "name": m.name, "category": m.category.title,
                 "enabled": general.enabled[m.id] ?? m.enabledByDefault]
            }
            if json { emit(rows) } else {
                for r in rows {
                    let on = (r["enabled"] as? Bool) == true ? "on " : "off"
                    print("\(on)  \((r["id"] as! String).padding(toLength: 16, withPad: " ", startingAt: 0)) \(r["name"] as! String)")
                }
            }
        case "enable", "disable":
            let ids = Array(args.dropFirst())
            guard !ids.isEmpty else { throw CLIError("usage: mactoys modules \(sub) <id>…", code: 64) }
            for id in ids {
                guard catalog.contains(where: { $0.id == id }) else { throw CLIError("unknown module '\(id)'", code: 64) }
                general.enabled[id] = (sub == "enable")
            }
            store.save(general, id: "general")
            DistributedNotificationCenter.default().postNotificationName(SettingsStore.externalChangeNotification,
                                                                         object: nil, deliverImmediately: true)
            if json { emit(["ok": true, "changed": ids]) } else { print("\(sub)d \(ids.joined(separator: ", "))") }
        default:
            throw CLIError("usage: mactoys modules [list|enable|disable]", code: 64)
        }
    }

    static func openURL(_ args: [String]) throws {
        guard let module = args.first else { throw CLIError("usage: mactoys open <module> [action] [k=v…] [files…]", code: 64) }
        var action = "open"
        var params: [String: String] = [:]
        var files: [URL] = []
        for (i, a) in args.dropFirst().enumerated() {
            if let eq = a.firstIndex(of: "="), !a.hasPrefix("/") && !a.hasPrefix(".") {
                params[String(a[..<eq])] = String(a[a.index(after: eq)...])
            } else if i == 0 && !a.contains("/") && !FileManager.default.fileExists(atPath: a) {
                action = a
            } else {
                files.append(URL(fileURLWithPath: a).standardizedFileURL)
            }
        }
        open(AppCommand(module: module, action: action, parameters: params, files: files))
    }

    // MARK: helpers

    /// Delivers a command to the running app (launching it in the background if needed).
    static func open(_ command: AppCommand) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let semaphore = DispatchSemaphore(value: 0)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Paths.bundleIdentifier) {
            NSWorkspace.shared.open([command.url], withApplicationAt: app, configuration: config) { _, error in
                if let error { fail(error.localizedDescription) }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 10)
        } else {
            NSWorkspace.shared.open(command.url)
        }
    }

    static func emit(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return }
        print(s)
    }

    nonisolated static func fail(_ message: String) {
        if json {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
            FileHandle.standardError.write(data + Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("mactoys: \(message)\n".utf8))
        }
    }
}

struct CLIError: Error {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
}

/// Module metadata without starting anything (instantiating modules is cheap; `start()` is never called).
@MainActor
enum ModuleCatalog {
    static var all: [ModuleInfo] { AllModules.make().map(\.info) }
}

exit(await CLI.main())
