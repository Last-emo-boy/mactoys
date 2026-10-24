import Foundation

/// Runs a command-line tool without blocking, and terminates it when the calling task is cancelled
/// (a newer keystroke) or a timeout passes.
enum AsyncProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let duration: TimeInterval
        let timedOut: Bool
        var ok: Bool { status == 0 && !timedOut }
        /// stdout, or stderr when stdout is empty.
        var text: String {
            let o = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return o.isEmpty ? stderr.trimmingCharacters(in: .whitespacesAndNewlines) : o
        }
    }

    /// The user's login PATH plus Homebrew locations, so scripts find `brew`, `node`, `python3`.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin"]
        let path = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        env["PATH"] = (extra.filter { !path.contains($0) } + path).joined(separator: ":")
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        return env
    }()

    private final class Box: @unchecked Sendable {
        let process = Process()
        let lock = NSLock()
        var timedOut = false
        var out = Data()
        var err = Data()
    }

    static func run(_ executable: String, _ arguments: [String] = [], currentDirectory: URL? = nil,
                    environment extraEnv: [String: String] = [:], timeout: TimeInterval = 30) async -> Output {
        let box = Box()
        let start = Date()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Output, Never>) in
                let p = box.process
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.environment = environment.merging(extraEnv) { $1 }
                p.currentDirectoryURL = currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                // Read both pipes concurrently so a chatty tool can't fill one and deadlock.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    box.lock.lock(); box.out = d; box.lock.unlock()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    let d = err.fileHandleForReading.readDataToEndOfFile()
                    box.lock.lock(); box.err = d; box.lock.unlock()
                    group.leave()
                }
                p.terminationHandler = { proc in
                    group.notify(queue: .global()) {
                        box.lock.lock()
                        let result = Output(status: proc.terminationStatus,
                                            stdout: String(decoding: box.out, as: UTF8.self),
                                            stderr: String(decoding: box.err, as: UTF8.self),
                                            duration: Date().timeIntervalSince(start), timedOut: box.timedOut)
                        box.lock.unlock()
                        cont.resume(returning: result)
                    }
                }
                do {
                    try p.run()
                } catch {
                    try? out.fileHandleForWriting.close()
                    try? err.fileHandleForWriting.close()
                    p.terminationHandler = nil
                    cont.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription,
                                                  duration: 0, timedOut: false))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard p.isRunning else { return }
                    box.lock.lock()
                    box.timedOut = true
                    box.lock.unlock()
                    p.terminate()
                }
            }
        } onCancel: {
            if box.process.isRunning { box.process.terminate() }
        }
    }

    /// `/bin/zsh -lc <command>`.
    static func shell(_ command: String, timeout: TimeInterval = 30, currentDirectory: URL? = nil) async -> Output {
        await run("/bin/zsh", ["-lc", command], currentDirectory: currentDirectory, timeout: timeout)
    }
}
