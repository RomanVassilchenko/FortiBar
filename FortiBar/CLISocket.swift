import Foundation
import Darwin
import os

/// Unified log, not stdout: the executable doubles as the `fortibar` CLI.
nonisolated private let log = Logger(subsystem: "com.romanvassilchenko.FortiBar", category: "cli-socket")

// MARK: - Wire format

/// CLI → app commands travel over a Unix domain socket in the user's private Application
/// Support folder (directory 0700, socket 0600), and the server also checks the peer's uid.
/// Unlike distributed notifications, which any process in the login session (sandboxed apps
/// included) can post and observe, only processes of this user can reach it.
///
/// One newline-terminated JSON request per connection, one JSON response line back:
///
///     → {"action":"connect","server":"office-1"}
///     ← {"ok":true}  or  {"error":"…","ok":false}
//
// Everything here is nonisolated (the target defaults to MainActor): the server runs on its own
// queues and only the request handler is called on the main queue.
extension CLIProtocol {
    nonisolated struct Request: Codable, Equatable {
        var action: Action
        var server: String?
    }

    nonisolated struct Response: Codable, Equatable {
        var ok: Bool
        var error: String?

        static let success = Response(ok: true, error: nil)
        static func failure(_ message: String) -> Response { Response(ok: false, error: message) }
    }

    /// Upper bound for one request or response line (they are a few dozen bytes in practice).
    nonisolated static let maxMessageSize = 64 * 1024

    /// Compact JSON followed by "\n".
    nonisolated static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    nonisolated static func decodeLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static var socketPath: String {
        socketPath(in: ConfigManager.configPath.deletingLastPathComponent())
    }

    /// `cli.sock` next to config.json and state.json.
    ///
    /// sockaddr_un holds at most 103 path bytes. A home folder long enough to exceed that
    /// falls back to the per-user temporary directory (`confstr(_CS_DARWIN_USER_TEMP_DIR)`,
    /// /var/folders/…/T/), which macOS creates owned by the user with mode 0700, so the socket
    /// stays unreachable for other users. Both sides compute the same path. Not the default
    /// because the system may clean that folder; a relative path or a symlink would need a
    /// process-wide chdir or a shared, attacker-writable location such as /tmp.
    nonisolated static func socketPath(in directory: URL) -> String {
        let primary = directory.appendingPathComponent("cli.sock").path
        if primary.utf8.count < UnixSocket.maxPathLength { return primary }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return primary }
        let fallback = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent("com.romanvassilchenko.FortiBar.cli.sock").path
        return fallback.utf8.count < UnixSocket.maxPathLength ? fallback : primary
    }
}

// MARK: - POSIX helpers

nonisolated enum UnixSocket {
    /// Size of sockaddr_un.sun_path (104), including the terminating NUL.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < maxPathLength, !bytes.contains(0) else { return nil }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func withSockaddr<R>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// A new stream socket, close-on-exec and without SIGPIPE on writes to a closed peer.
    static func makeSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fd }
        prepare(fd)
        return fd
    }

    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setBlocking(_ fd: Int32, _ blocking: Bool) {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return }
        _ = fcntl(fd, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK)
    }

    static func setTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        let whole = max(0, seconds.rounded(.down))
        var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1_000_000))
        if tv.tv_sec == 0 && tv.tv_usec == 0 { tv.tv_usec = 1000 }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid = uid_t()
        var gid = gid_t()
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    struct Errno: Error, Equatable {
        let code: Int32
    }

    /// Connects to `path`; returns the descriptor or the errno of the failure.
    static func connect(to path: String) -> Result<Int32, Errno> {
        guard var address = address(path) else { return .failure(Errno(code: ENAMETOOLONG)) }
        let fd = makeSocket()
        guard fd >= 0 else { return .failure(Errno(code: errno)) }
        let result = withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let error = errno
            close(fd)
            return .failure(Errno(code: error))
        }
        return .success(fd)
    }

    enum ReadError: Error, Equatable {
        case timeout, tooLarge, closed, io(Int32)
    }

    /// Reads up to the first "\n" (excluded) or EOF. Every recv is bounded by SO_RCVTIMEO;
    /// `deadline` also stops a peer that trickles bytes in just under that timeout.
    static func readLine(_ fd: Int32, maxSize: Int, deadline: Date) -> Result<Data, ReadError> {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                data.append(contentsOf: chunk[0..<count])
                if let newline = data.firstIndex(of: 0x0A) {
                    let line = data[data.startIndex..<newline]
                    return line.count <= maxSize ? .success(Data(line)) : .failure(.tooLarge)
                }
                if data.count > maxSize { return .failure(.tooLarge) }
                if Date() >= deadline { return .failure(.timeout) }
            } else if count == 0 {
                return data.isEmpty ? .failure(.closed) : .success(data)
            } else {
                switch errno {
                case EINTR: continue
                case EAGAIN, EWOULDBLOCK: return .failure(.timeout)
                case let error: return .failure(.io(error))
                }
            }
        }
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = send(fd, base + offset, raw.count - offset, 0)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

// MARK: - Server (app side)

/// Listens on the CLI socket and hands each request to `handler` on `handlerQueue`
/// (the main queue in the app).
nonisolated final class CLISocketServer: @unchecked Sendable {
    /// Called on `handlerQueue`
    typealias Handler = @Sendable (CLIProtocol.Request) -> CLIProtocol.Response

    enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case insecureDirectory(String)
        case alreadyListening(String)
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let path): return "socket path too long: \(path)"
            case .insecureDirectory(let path): return "\(path) is not a private directory of this user"
            case .alreadyListening(let path): return "another process is listening on \(path)"
            case .system(let call, let error): return "\(call): \(String(cString: strerror(error)))"
            }
        }
    }

    let path: String
    private let handler: Handler
    private let handlerQueue: DispatchQueue
    private let timeout: TimeInterval
    private let maxRequestSize: Int
    private let queue = DispatchQueue(label: "com.romanvassilchenko.FortiBar.cli-socket")
    private let connections = DispatchQueue(label: "com.romanvassilchenko.FortiBar.cli-connection",
                                            qos: .userInitiated, attributes: .concurrent)
    private var source: DispatchSourceRead?
    /// Identity of the socket file this instance bound, so stop() never unlinks someone else's
    private var boundFile: (device: dev_t, inode: ino_t)?

    init(path: String,
         handlerQueue: DispatchQueue = .main,
         timeout: TimeInterval = 5,
         maxRequestSize: Int = CLIProtocol.maxMessageSize,
         handler: @escaping Handler) {
        self.path = path
        self.handlerQueue = handlerQueue
        self.timeout = timeout
        self.maxRequestSize = maxRequestSize
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        guard source == nil else { return }
        guard var address = UnixSocket.address(path) else { throw StartError.pathTooLong(path) }
        try securePrivateDirectory()
        try removeStaleSocket()

        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        let bound = UnixSocket.withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw error == EADDRINUSE ? StartError.alreadyListening(path) : StartError.system("bind", error)
        }
        var info = stat()
        if lstat(path, &info) == 0 { boundFile = (info.st_dev, info.st_ino) }
        // The 0700 directory already keeps others out; this covers the fallback location too
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            unlinkOwnSocket()
            throw StartError.system("listen", error)
        }
        UnixSocket.setBlocking(fd, false)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// Stops listening and removes the socket file, if this instance created it.
    func stop() {
        source?.cancel()
        source = nil
        unlinkOwnSocket()
    }

    private func unlinkOwnSocket() {
        guard let bound = boundFile else { return }
        boundFile = nil
        var info = stat()
        if lstat(path, &info) == 0, info.st_dev == bound.device, info.st_ino == bound.inode {
            unlink(path)
        }
    }

    /// Creates the socket's directory as 0700, or tightens it to 0700 when it is ours.
    private func securePrivateDirectory() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard stat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
            throw StartError.insecureDirectory(directory)
        }
        if info.st_mode & 0o077 != 0 {
            guard chmod(directory, 0o700) == 0 else { throw StartError.insecureDirectory(directory) }
        }
    }

    /// A socket file left by a crashed instance: remove it unless something still accepts on it.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR { throw StartError.alreadyListening(path) }
        if (info.st_mode & S_IFMT) == S_IFSOCK, case .success(let fd) = UnixSocket.connect(to: path) {
            close(fd)
            throw StartError.alreadyListening(path)
        }
        guard unlink(path) == 0 || errno == ENOENT else { throw StartError.system("unlink", errno) }
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN: drained
            }
            UnixSocket.prepare(fd)
            // Accepted sockets inherit O_NONBLOCK; reads below rely on SO_RCVTIMEO instead
            UnixSocket.setBlocking(fd, true)
            guard UnixSocket.peerUID(fd) == getuid() else {
                log.error("Rejected a CLI connection from another user")
                close(fd)
                continue
            }
            UnixSocket.setTimeout(fd, timeout)
            connections.async { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        let request: CLIProtocol.Request
        switch UnixSocket.readLine(fd, maxSize: maxRequestSize, deadline: Date().addingTimeInterval(timeout)) {
        case .success(let line):
            guard let decoded = try? CLIProtocol.decodeLine(CLIProtocol.Request.self, from: line) else {
                return respond(fd, .failure("invalid request"))
            }
            request = decoded
        case .failure(.tooLarge):
            return respond(fd, .failure("request too large"))
        case .failure:
            close(fd)  // silent, slow or vanished client
            return
        }

        handlerQueue.async { [handler, connections] in
            let response = handler(request)
            connections.async { CLISocketServer.write(response, to: fd) }
        }
    }

    private func respond(_ fd: Int32, _ response: CLIProtocol.Response) {
        CLISocketServer.write(response, to: fd)
    }

    private static func write(_ response: CLIProtocol.Response, to fd: Int32) {
        if let data = try? CLIProtocol.encodeLine(response) {
            UnixSocket.writeAll(fd, data)
        }
        close(fd)
    }
}

// MARK: - Client (CLI side)

nonisolated enum CLISocketClient {
    enum Failure: Error, Equatable {
        /// Nobody listens (app not running or still starting): worth a retry
        case unavailable
        case failed(String)
    }

    static func send(_ request: CLIProtocol.Request, path: String,
                     timeout: TimeInterval = 10) -> Result<CLIProtocol.Response, Failure> {
        let fd: Int32
        switch UnixSocket.connect(to: path) {
        case .success(let descriptor):
            fd = descriptor
        case .failure(let error) where error.code == ENOENT || error.code == ECONNREFUSED:
            return .failure(.unavailable)
        case .failure(let error):
            return .failure(.failed("cannot connect to \(path): \(String(cString: strerror(error.code)))"))
        }
        defer { close(fd) }

        // The directory is private, but refuse a socket another user managed to put there anyway
        guard UnixSocket.peerUID(fd) == getuid() else {
            return .failure(.failed("\(path) belongs to another user"))
        }
        UnixSocket.setTimeout(fd, timeout)
        guard let data = try? CLIProtocol.encodeLine(request), UnixSocket.writeAll(fd, data) else {
            return .failure(.failed("could not send the command to FortiBar"))
        }
        switch UnixSocket.readLine(fd, maxSize: CLIProtocol.maxMessageSize, deadline: Date().addingTimeInterval(timeout)) {
        case .success(let line):
            guard let response = try? CLIProtocol.decodeLine(CLIProtocol.Response.self, from: line) else {
                return .failure(.failed("invalid response from FortiBar"))
            }
            return .success(response)
        case .failure(.timeout):
            return .failure(.failed("FortiBar did not answer"))
        case .failure:
            return .failure(.failed("FortiBar closed the connection without an answer"))
        }
    }
}
