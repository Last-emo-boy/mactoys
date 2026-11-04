import Darwin
import Foundation
import MacToysCore

/// Unix-domain socket plumbing shared by the helper (server) and MacToys (client).
enum UnixSocket {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case system(String, Int32)
        case pathTooLong
        case closed
        case tooLong

        var description: String {
            switch self {
            case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
            case .pathTooLong: "socket path too long"
            case .closed: "connection closed"
            case .tooLong: "message too long"
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw Failure.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads up to and including the first newline.
    static func readLine(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !data.contains(UInt8(ascii: "\n")) {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.system("read", errno)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > limit { throw Failure.tooLong }
        }
        guard !data.isEmpty else { throw Failure.closed }
        if let end = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[..<end] }
        return Data(data)
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure.system("write", errno)
                }
                offset += n
            }
        }
    }
}

/// The helper's listening socket. Only the console user (and root) may talk to it: the socket file is
/// theirs with mode 0600 inside a root-owned directory, and every connection's peer is checked.
final class HelperSocketServer: @unchecked Sendable {
    private let path: String
    private let ownerUID: uid_t
    private let handler: @MainActor (Data) -> Data
    private let queue = DispatchQueue(label: "com.w33d.mactoys.chargelimit.socket")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let log = Log.for("chargelimit")

    init(path: String, ownerUID: uid_t, handler: @escaping @MainActor (Data) -> Data) {
        self.path = path
        self.ownerUID = ownerUID
        self.handler = handler
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocket.Failure.system("socket", errno) }
        var addr = try UnixSocket.address(path)
        unlink(path)
        // Created 0600 root-owned, then handed to the owner: never readable by anyone else in between.
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previous)
        guard bound == 0 else { let e = errno; close(fd); throw UnixSocket.Failure.system("bind", e) }
        guard chown(path, ownerUID, gid_t.max) == 0, chmod(path, 0o600) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw UnixSocket.Failure.system("chown", e)
        }
        guard listen(fd, 8) == 0 else { let e = errno; close(fd); throw UnixSocket.Failure.system("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == ownerUID || uid == 0 else {
            log.error("Refused a helper connection from uid \(uid)")
            return
        }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        UnixSocket.setTimeouts(client, seconds: 2)
        let response: Data
        do {
            let line = try UnixSocket.readLine(client, limit: HelperProtocol.maxLineLength)
            let handler = self.handler
            response = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(line) } }
        } catch UnixSocket.Failure.tooLong {
            response = HelperResponse.failure(HelperProtocolError.tooLong.description).encoded()
        } catch {
            return
        }
        try? UnixSocket.writeAll(client, response)
    }
}

public enum HelperClientError: Error, Equatable {
    /// Nothing listens at the socket (helper not installed, not running, or disabled in Login Items).
    case notRunning
    case failed(String)
}

/// MacToys' side of the socket.
public enum HelperClient {
    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperPaths.launchDaemon) || FileManager.default.fileExists(atPath: HelperPaths.helper)
    }

    public static func send(_ request: HelperRequest, path: String = HelperPaths.socket) async throws -> HelperResponse {
        try await Task.detached(priority: .userInitiated) { try sendNow(request, path: path) }.value
    }

    /// Blocking; call off the main thread.
    static func sendNow(_ request: HelperRequest, path: String) throws -> HelperResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperClientError.failed("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: 3)
        var addr: sockaddr_un
        do { addr = try UnixSocket.address(path) } catch { throw HelperClientError.failed("\(error)") }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let e = errno
            if e == ENOENT || e == ECONNREFUSED || e == EACCES { throw HelperClientError.notRunning }
            throw HelperClientError.failed("connect: \(String(cString: strerror(e)))")
        }
        do {
            try UnixSocket.writeAll(fd, request.encoded())
            let line = try UnixSocket.readLine(fd, limit: 256 * 1024)
            return try HelperResponse.decode(line)
        } catch let e as UnixSocket.Failure {
            throw HelperClientError.failed(e.description)
        } catch {
            throw HelperClientError.failed("unreadable response")
        }
    }
}
