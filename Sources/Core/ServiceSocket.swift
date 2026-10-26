import Foundation
import Darwin

// UI (PaperFlow.app) <-> background service (PaperFlowService) over a Unix domain socket.
// Replaces NSXPC + launchd, which refuses to spawn an ad hoc signed service (spawn failed, EX_CONFIG).
// Frame: 4-byte big-endian length, then a JSON `ServiceEnvelope`. Payloads are JSON `ServiceCommand` /
// `ServiceStatus` (see ServiceXPC.swift), so the transport never changes when a command is added.

public struct ServiceEnvelope: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case command, reply, error, status }
    public var id: String
    public var kind: Kind
    public var payload: Data   // base64 in the JSON; an `error` carries a UTF-8 message
    public init(id: String, kind: Kind, payload: Data) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}

public struct ServiceSocketError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ServiceSocket {
    public static let maxFrame = 16 << 20

    /// ~/Library/Application Support/LiveWallpaper/service.sock, or /tmp/lw-<uid>/service.sock when that path does
    /// not fit in sockaddr_un.sun_path (104 bytes including the terminator).
    public static let path: String = {
        let preferred = AppPaths.supportDirectory.appendingPathComponent("service.sock").path
        if preferred.utf8.count < 104 {
            if !FileManager.default.fileExists(atPath: AppPaths.supportDirectory.path) {
                try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
            }
            return preferred
        }
        let folder = "/tmp/lw-\(getuid())"
        mkdir(folder, 0o700)
        // Another user could have planted the folder: only use one we own.
        var info = stat()
        if lstat(folder, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR { chmod(folder, 0o700) }
        return folder + "/service.sock"
    }()

    /// True when a service accepts connections on `path` right now.
    public static func isServing(at path: String = path) -> Bool {
        guard let fd = try? connect(to: path, timeout: 1) else { return false }
        Darwin.close(fd)
        return true
    }

    // MARK: Plumbing shared by server and client

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw posixError("socket") }
        configure(fd)
        return fd
    }

    /// No SIGPIPE on a dead peer, and a stuck peer cannot block a writer forever.
    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Non-blocking connect bounded by `timeout`; returns a blocking socket.
    static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        guard var address = address(path) else { throw ServiceSocketError("The service socket path is too long.") }
        let fd = try makeSocket()
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else {
                let error = posixError("connect")
                Darwin.close(fd)
                throw error
            }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            var soError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard poll(&poller, 1, Int32(timeout * 1000)) == 1,
                  getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &length) == 0, soError == 0 else {
                Darwin.close(fd)
                throw ServiceSocketError("Timed out connecting to the wallpaper service.")
            }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    static func write(_ envelope: ServiceEnvelope, to fd: Int32) -> Bool {
        guard let body = try? JSONEncoder().encode(envelope), body.count <= maxFrame else { return false }
        var frame = Data(capacity: 4 + body.count)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    /// Blocks until a whole frame arrives. nil on EOF, a read error, an oversize or undecodable frame.
    static func read(from fd: Int32) -> ServiceEnvelope? {
        guard let header = readExactly(4, from: fd) else { return nil }
        let length = header.reduce(0) { Int($0) << 8 | Int($1) }
        guard length > 0, length <= maxFrame, let body = readExactly(length, from: fd) else { return nil }
        return try? JSONDecoder().decode(ServiceEnvelope.self, from: body)
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < count {
                let got = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if got < 0 && errno == EINTR { continue }
                guard got > 0 else { return false }
                offset += got
            }
            return true
        }
        return ok ? data : nil
    }

    static func posixError(_ call: String) -> ServiceSocketError {
        ServiceSocketError("\(call): \(String(cString: strerror(errno)))")
    }
}

// MARK: - Server (service side)

/// Listens on `ServiceSocket.path`. One thread accepts, one thread per connection reads; commands run in `handler`
/// and are answered with a `reply` or `error` carrying the command's id.
public final class ServiceSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Result<Data, ServiceSocketError>

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        private let lock = NSLock()
        private var open = true
        init(fd: Int32) { self.fd = fd }
        func send(_ envelope: ServiceEnvelope) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return open && ServiceSocket.write(envelope, to: fd)
        }
        /// Wakes the reader; only the reader closes the fd, so the number is never reused under it.
        func close() {
            lock.lock(); defer { lock.unlock() }
            guard open else { return }
            open = false
            shutdown(fd, SHUT_RDWR)
        }
    }

    private let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var connections: [Int32: Connection] = [:]
    private var listener: Int32 = -1

    public init(path: String = ServiceSocket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// The caller has checked that no live service answers on `path`; a leftover socket file is removed.
    public func start() throws {
        guard var address = ServiceSocket.address(path) else { throw ServiceSocketError("Socket path too long: \(path)") }
        let fd = try ServiceSocket.makeSocket()
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = ServiceSocket.posixError("bind/listen \(path)")
            Darwin.close(fd)
            throw error
        }
        listener = fd
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "ServiceSocketServer.accept"
        thread.start()
    }

    /// Closes the listener and removes the socket file (connected clients see EOF when the process exits).
    public func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        let open = Array(connections.values)
        connections = [:]
        lock.unlock()
        guard fd >= 0 else { return }
        Darwin.close(fd)
        unlink(path)
        open.forEach { $0.close() }
    }

    public func broadcast(status: Data) {
        lock.lock()
        let targets = Array(connections.values)
        lock.unlock()
        let envelope = ServiceEnvelope(id: UUID().uuidString, kind: .status, payload: status)
        for connection in targets where !connection.send(envelope) { drop(connection) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return   // listener closed
            }
            ServiceSocket.configure(fd)
            // Only processes of this user may drive the service (the socket file is 0600 as well).
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(fd)
                continue
            }
            let connection = Connection(fd: fd)
            lock.lock()
            connections[fd] = connection
            lock.unlock()
            let reader = Thread { [self] in readLoop(connection) }
            reader.name = "ServiceSocketServer.connection"
            reader.start()
        }
    }

    private func readLoop(_ connection: Connection) {
        while let envelope = ServiceSocket.read(from: connection.fd) {
            guard envelope.kind == .command else { continue }
            let handler = handler
            Task { [self] in
                let reply: ServiceEnvelope
                switch await handler(envelope.payload) {
                case .success(let data): reply = ServiceEnvelope(id: envelope.id, kind: .reply, payload: data)
                case .failure(let error): reply = ServiceEnvelope(id: envelope.id, kind: .error, payload: Data(error.message.utf8))
                }
                if !connection.send(reply) { drop(connection) }
            }
        }
        drop(connection)
        Darwin.close(connection.fd)
    }

    private func drop(_ connection: Connection) {
        lock.lock()
        if connections[connection.fd] === connection { connections[connection.fd] = nil }
        lock.unlock()
        connection.close()
    }
}

// MARK: - Client (UI side)

/// One connection to the service. Replies are matched to commands by id; pushes go to `onStatus`, a lost
/// connection to `onDisconnect` (not called after `close()`). Callbacks run on a private queue.
public final class ServiceSocketClient: @unchecked Sendable {
    public static let replyTimeout: TimeInterval = 10

    private let onStatus: @Sendable (Data) -> Void
    private let onDisconnect: @Sendable () -> Void
    private let queue = DispatchQueue(label: "ServiceSocketClient")
    // Guarded by `queue`.
    private var fd: Int32 = -1
    private var closedByUser = false
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]

    public init(onStatus: @escaping @Sendable (Data) -> Void, onDisconnect: @escaping @Sendable () -> Void) {
        self.onStatus = onStatus
        self.onDisconnect = onDisconnect
    }

    /// Blocking; call it off the main thread.
    public func connect(path: String = ServiceSocket.path, timeout: TimeInterval = 2) throws {
        let fd = try ServiceSocket.connect(to: path, timeout: timeout)
        queue.sync { self.fd = fd }
        let reader = Thread { [self] in readLoop(fd) }
        reader.name = "ServiceSocketClient.reader"
        reader.start()
    }

    public func send(command: Data) async throws -> Data {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard fd >= 0, !closedByUser else {
                    return continuation.resume(throwing: ServiceSocketError("Not connected to the wallpaper service."))
                }
                pending[id] = continuation
                guard ServiceSocket.write(ServiceEnvelope(id: id, kind: .command, payload: command), to: fd) else {
                    pending[id] = nil
                    return continuation.resume(throwing: ServiceSocketError("The wallpaper service connection broke."))
                }
                queue.asyncAfter(deadline: .now() + Self.replyTimeout) { [self] in
                    pending.removeValue(forKey: id)?.resume(throwing: ServiceSocketError("The wallpaper service didn’t answer in time."))
                }
            }
        }
    }

    /// Wakes the reader, which closes the socket and fails pending commands.
    public func close() {
        queue.sync {
            closedByUser = true
            if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        }
    }

    private func readLoop(_ socket: Int32) {
        while let envelope = ServiceSocket.read(from: socket) {
            queue.async { [self] in
                switch envelope.kind {
                case .reply: pending.removeValue(forKey: envelope.id)?.resume(returning: envelope.payload)
                case .error:
                    let message = String(decoding: envelope.payload, as: UTF8.self)
                    pending.removeValue(forKey: envelope.id)?.resume(throwing: ServiceSocketError(message))
                case .status: onStatus(envelope.payload)
                case .command: break
                }
            }
        }
        queue.async { [self] in
            Darwin.close(socket)
            fd = -1
            let failed = pending
            pending = [:]
            failed.values.forEach { $0.resume(throwing: ServiceSocketError("The wallpaper service connection closed.")) }
            if !closedByUser { onDisconnect() }
        }
    }
}
