import Foundation
import MacToysCore

/// Per-utility subcommands. Each entry returns the process exit code.
@MainActor
enum ModuleCommands {
    typealias Handler = @MainActor ([String]) async throws -> Int32

    static let table: [String: Handler] = [
        "peek": { args in
            CLI.open(AppCommand(module: "peek", action: "open", files: args.map { URL(fileURLWithPath: $0).standardizedFileURL }))
            return 0
        },
    ]

    static let help = """
      peek <files…>                  Preview files in Peek
    """
}
