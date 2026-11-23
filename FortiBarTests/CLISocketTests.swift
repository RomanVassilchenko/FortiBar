import Foundation
import Darwin
import Testing
@testable import FortiBar

struct CLIWireFormatTests {
    @Test func requestRoundTrips() throws {
        let request = CLIProtocol.Request(action: .disconnectAll, server: nil)
        let line = try CLIProtocol.encodeLine(request)
        #expect(String(decoding: line, as: UTF8.self) == "{\"action\":\"disconnect-all\"}\n")
        #expect(try CLIProtocol.decodeLine(CLIProtocol.Request.self, from: line.dropLast()) == request)

        let connect = CLIProtocol.Request(action: .connect, server: "office/1")
        let encoded = try CLIProtocol.encodeLine(connect)
        #expect(String(decoding: encoded, as: UTF8.self) == "{\"action\":\"connect\",\"server\":\"office/1\"}\n")
        #expect(try CLIProtocol.decodeLine(CLIProtocol.Request.self, from: encoded) == connect)
    }

    @Test func responsesEncodeAsDocumented() throws {
        #expect(String(decoding: try CLIProtocol.encodeLine(CLIProtocol.Response.success), as: UTF8.self) == "{\"ok\":true}\n")
        let failure = CLIProtocol.Response.failure("unknown server id \"x\"")
        let line = try CLIProtocol.encodeLine(failure)
        #expect(String(decoding: line, as: UTF8.self) == "{\"error\":\"unknown server id \\\"x\\\"\",\"ok\":false}\n")
        #expect(try CLIProtocol.decodeLine(CLIProtocol.Response.self, from: line) == failure)
    }

    @Test func rejectsUnknownActionsAndGarbage() {
        #expect(throws: (any Error).self) {
            try CLIProtocol.decodeLine(CLIProtocol.Request.self, from: Data("{\"action\":\"format-disk\"}".utf8))
        }
        #expect(throws: (any Error).self) {
            try CLIProtocol.decodeLine(CLIProtocol.Request.self, from: Data("connect office".utf8))
        }
    }

    @Test func socketPathFitsSockaddr() {
        let short = URL(fileURLWithPath: "/Users/me/Library/Application Support/FortiBar")
        #expect(CLIProtocol.socketPath(in: short) == short.path + "/cli.sock")

        let long = URL(fileURLWithPath: "/Users/" + String(repeating: "x", count: 120) + "/Library/Application Support/FortiBar")
        let fallback = CLIProtocol.socketPath(in: long)
        #expect(fallback.utf8.count < UnixSocket.maxPathLength)
        #expect(UnixSocket.address(fallback) != nil)
        #expect(UnixSocket.address(long.path + "/cli.sock") == nil)
    }
}

/// Server and client over a real socket in a temporary directory (never the app's folder).
struct CLISocketLoopbackTests {
    private func makeDirectory() throws -> URL {
        // Short name: sockaddr_un paths are limited to 103 bytes
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fb-" + UUID().uuidString.prefix(8), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeServer(at path: String, timeout: TimeInterval = 5,
                            handler: @escaping CLISocketServer.Handler) -> CLISocketServer {
        CLISocketServer(path: path, handlerQueue: DispatchQueue(label: "test.handler"),
                        timeout: timeout, handler: handler)
    }

    @Test func requestReachesHandlerAndResponseComesBack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cli.sock").path

        let received = Locked<[CLIProtocol.Request]>([])
        let server = makeServer(at: path) { request in
            received.mutate { $0.append(request) }
            return request.server == "known" ? .success : .failure("unknown server id")
        }
        try server.start()
        defer { server.stop() }

        let ok = CLISocketClient.send(.init(action: .connect, server: "known"), path: path, timeout: 2)
        #expect(ok == .success(.success))
        let refused = CLISocketClient.send(.init(action: .connect, server: "nope"), path: path, timeout: 2)
        #expect(refused == .success(.failure("unknown server id")))
        #expect(received.value.map(\.server) == ["known", "nope"])

        // Private directory and socket
        var info = stat()
        #expect(stat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && info.st_mode & 0o777 == 0o600)
    }

    @Test func invalidAndOversizedRequestsAreRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cli.sock").path
        let server = makeServer(at: path) { _ in
            Issue.record("handler must not run")
            return .success
        }
        try server.start()
        defer { server.stop() }

        #expect(rawExchange(path, Data("hello\n".utf8)) == "{\"error\":\"invalid request\",\"ok\":false}\n")
        let huge = Data(repeating: 0x61, count: CLIProtocol.maxMessageSize + 10)
        #expect(rawExchange(path, huge) == "{\"error\":\"request too large\",\"ok\":false}\n")
    }

    @Test func silentClientIsDisconnected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cli.sock").path
        let server = makeServer(at: path, timeout: 0.3) { _ in .success }
        try server.start()
        defer { server.stop() }

        guard case .success(let fd) = UnixSocket.connect(to: path) else {
            Issue.record("could not connect")
            return
        }
        defer { close(fd) }
        UnixSocket.setTimeout(fd, 3)
        let started = Date()
        // The server gives up on the request and closes: we read EOF well before our own timeout
        #expect(UnixSocket.readLine(fd, maxSize: 1024, deadline: Date().addingTimeInterval(3)) == .failure(.closed))
        #expect(Date().timeIntervalSince(started) < 2)

        // ...and keeps serving others
        #expect(CLISocketClient.send(.init(action: .reloadConfig), path: path, timeout: 2) == .success(.success))
    }

    @Test func staleSocketIsReplacedButALiveOneIsNot() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cli.sock").path

        // A crashed instance leaves a socket file that nobody listens on
        var address = try #require(UnixSocket.address(path))
        let stale = UnixSocket.makeSocket()
        #expect(UnixSocket.withSockaddr(&address) { bind(stale, $0, $1) } == 0)
        close(stale)
        #expect(CLISocketClient.send(.init(action: .reloadConfig), path: path, timeout: 1) == .failure(.unavailable))

        let first = makeServer(at: path) { _ in .success }
        try first.start()

        // A second instance must neither take over nor delete the live socket
        let second = makeServer(at: path) { _ in .failure("second") }
        #expect(throws: CLISocketServer.StartError.self) { try second.start() }
        second.stop()
        #expect(CLISocketClient.send(.init(action: .reloadConfig), path: path, timeout: 2) == .success(.success))

        first.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(CLISocketClient.send(.init(action: .reloadConfig), path: path, timeout: 1) == .failure(.unavailable))
    }

    /// Sends raw bytes and returns everything the server answers.
    private func rawExchange(_ path: String, _ data: Data) -> String? {
        guard case .success(let fd) = UnixSocket.connect(to: path) else { return nil }
        defer { close(fd) }
        UnixSocket.setTimeout(fd, 3)
        _ = UnixSocket.writeAll(fd, data)
        guard case .success(let line) = UnixSocket.readLine(fd, maxSize: 1024, deadline: Date().addingTimeInterval(3)) else {
            return nil
        }
        return String(decoding: line, as: UTF8.self) + "\n"
    }
}

nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
