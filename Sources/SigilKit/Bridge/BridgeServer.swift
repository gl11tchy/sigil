import Darwin
import Foundation

/// What the app supplies to answer bridge requests. All calls arrive on the main actor.
@MainActor
public protocol BridgeServerDelegate: AnyObject {
    func bridgeListTabs(asking peer: BridgePeer) -> [BridgeTab]
    func bridgeSend(from peer: BridgePeer, to target: String, message: String) -> BridgeResponse
    /// Returns as soon as the target tab answers, or when the deadline passes.
    func bridgeAsk(
        from peer: BridgePeer, to target: String, question: String, timeout: Double
    ) async -> BridgeResponse
    func bridgeReply(from peer: BridgePeer, requestID: String, answer: String) -> BridgeResponse
}

/// Unix-domain listener for the newline-delimited JSON bridge.
///
/// Accept and socket IO run off the main actor. Delegate calls hop back to it,
/// including a long `bridgeAsk`, so other connections keep being served.
@MainActor
public final class BridgeServer {
    public enum Error: Swift.Error, Equatable, Sendable {
        case alreadyInUse
        case pathTooLong
        case failed(operation: String, errno: Int32)
    }

    public let socketURL: URL
    public weak var delegate: BridgeServerDelegate?
    public private(set) var isListening = false
    public static let maxConcurrentClients = 64

    /// Idle seconds a client may take to finish one request frame.
    /// Past this the connection is dropped with no response.
    private static let frameReadSeconds: Double = 30
    /// A connected client that stops reading cannot hold a client slot forever.
    private static let frameWriteSeconds: Double = 30

    /// Owns the listen fd and DispatchSource. Sendable so `deinit` can stop it.
    private let listenBox = ListenBox()
    private let clientPool: ClientPool
    private let frameReadDeadline: Duration
    private let frameWriteDeadline: Duration

    public init(socketURL: URL = BridgePaths.configuredSocket) {
        self.socketURL = socketURL
        self.frameReadDeadline = .seconds(Self.frameReadSeconds)
        self.frameWriteDeadline = .seconds(Self.frameWriteSeconds)
        self.clientPool = ClientPool(limit: Self.maxConcurrentClients)
    }

    /// Test seam: inject a short frame-read deadline instead of waiting 30s.
    init(
        socketURL: URL,
        frameReadDeadline: Duration,
        frameWriteDeadline: Duration = .seconds(30),
        maxConcurrentClients: Int = BridgeServer.maxConcurrentClients
    ) {
        self.socketURL = socketURL
        self.frameReadDeadline = frameReadDeadline
        self.frameWriteDeadline = frameWriteDeadline
        self.clientPool = ClientPool(limit: maxConcurrentClients)
    }

    deinit {
        listenBox.stop()
    }

    /// Throws if the path cannot be bound. Safe to call twice (second is a no-op).
    public func start() throws {
        if isListening { return }
        let readDeadline = frameReadDeadline
        let writeDeadline = frameWriteDeadline
        let clientPool = clientPool
        try listenBox.bindAndListen(at: socketURL) { [weak self] clientFD in
            guard clientPool.admit(clientFD) else {
                Darwin.close(clientFD)
                return
            }
            Task.detached { [weak self] in
                guard let self else {
                    clientPool.release(clientFD)
                    Darwin.close(clientFD)
                    return
                }
                await self.serve(
                    clientFD: clientFD,
                    frameReadDeadline: readDeadline,
                    frameWriteDeadline: writeDeadline,
                    clientPool: clientPool
                )
            }
        }
        isListening = true
    }

    public func stop() {
        listenBox.stop()
        clientPool.shutdownAll()
        isListening = false
    }

    nonisolated private func serve(
        clientFD: Int32,
        frameReadDeadline: Duration,
        frameWriteDeadline: Duration,
        clientPool: ClientPool
    ) async {
        defer {
            clientPool.release(clientFD)
            Darwin.close(clientFD)
        }
        let frame: Data
        do {
            frame = try await Self.readFrame(from: clientFD, deadline: frameReadDeadline)
        } catch {
            return
        }
        let response: BridgeResponse? = await withTaskGroup(
            of: ServeEvent.self,
            returning: BridgeResponse?.self
        ) { group in
            group.addTask { [weak self] in
                guard let self else { return .disconnected }
                return .response(await self.processFrame(frame))
            }
            group.addTask {
                await Self.waitForDisconnect(clientFD)
                return .disconnected
            }
            guard let first = await group.next() else { return nil }
            group.cancelAll()
            switch first {
            case .response(let response): return response
            case .disconnected: return nil
            }
        }
        guard let response else { return }
        guard let data = try? BridgeFraming.frame(response) else { return }
        try? await Self.writeFully(data, to: clientFD, deadline: frameWriteDeadline)
    }

    private func processFrame(_ frame: Data) async -> BridgeResponse {
        let request: BridgeRequest
        do {
            request = try BridgeFraming.decode(BridgeRequest.self, from: frame)
        } catch {
            return .failure("undecodable request")
        }
        return await processRequest(request)
    }

    /// Test seam for values JSON cannot carry (`inf` / `nan` timeouts).
    func processRequest(_ request: BridgeRequest) async -> BridgeResponse {
        if request.version != BridgeProtocol.version {
            return .failure(
                "protocol version mismatch: got \(request.version), want \(BridgeProtocol.version)"
            )
        }
        if request.from.isAnonymous {
            return .failure("this client was not launched by Sigil")
        }
        guard let delegate else {
            return .failure("the app is not ready")
        }
        switch request.method {
        case .listTabs:
            let tabs = delegate.bridgeListTabs(asking: request.from)
            return BridgeResponse(ok: true, tabs: tabs)
        case .sendToTab:
            guard let target = request.target?.nilIfBlank else {
                return .failure("target is empty")
            }
            guard let message = BridgeLimits.clampedMessage(request.text) else {
                return .failure("message is empty")
            }
            return delegate.bridgeSend(from: request.from, to: target, message: message)
        case .askTab:
            guard let target = request.target?.nilIfBlank else {
                return .failure("target is empty")
            }
            guard let question = BridgeLimits.clampedMessage(request.text) else {
                return .failure("question is empty")
            }
            let timeout = BridgeLimits.clampedAskSeconds(request.timeoutSeconds)
            return await delegate.bridgeAsk(
                from: request.from, to: target, question: question, timeout: timeout)
        case .replyTo:
            guard let requestID = request.requestID?.nilIfBlank else {
                return .failure("requestID is empty")
            }
            guard let answer = BridgeLimits.clampedMessage(request.text) else {
                return .failure("answer is empty")
            }
            return delegate.bridgeReply(
                from: request.from, requestID: requestID, answer: answer)
        }
    }

    nonisolated private static func readFrame(from fd: Int32, deadline: Duration) async throws -> Data {
        let expiry = ContinuousClock.now + deadline
        var buffer = Data()
        while true {
            if Task.isCancelled { throw CancellationError() }
            if ContinuousClock.now >= expiry { throw SocketIOError.idleTimeout }
            try await waitReady(fd: fd, events: Int16(POLLIN), until: expiry)
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            if n > 0 {
                buffer.append(contentsOf: chunk.prefix(Int(n)))
                let lines = try BridgeFraming.drainLines(from: &buffer)
                if let line = lines.first { return line }
            } else if n == 0 {
                throw SocketIOError.eof
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                continue
            } else {
                throw SocketIOError.posix(errno)
            }
        }
    }

    nonisolated private static func writeFully(
        _ data: Data, to fd: Int32, deadline: Duration
    ) async throws {
        let expiry = ContinuousClock.now + deadline
        var offset = 0
        while offset < data.count {
            if Task.isCancelled { throw CancellationError() }
            try await waitReady(fd: fd, events: Int16(POLLOUT), until: expiry)
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
            }
            if n > 0 {
                offset += Int(n)
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                continue
            } else {
                throw SocketIOError.posix(errno)
            }
        }
    }

    /// After a request has been read, a client should send no more data. A
    /// hangup, EOF, or extra frame means it no longer needs the pending result.
    nonisolated private static func waitForDisconnect(_ fd: Int32) async {
        while !Task.isCancelled {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&descriptor, 1, 0)
            if result > 0 {
                if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
                if descriptor.revents & Int16(POLLIN) != 0 {
                    var byte: UInt8 = 0
                    let count = Darwin.recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                    if count == 0 || count > 0 { return }
                    if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { return }
                }
            } else if result < 0, errno != EINTR {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    nonisolated private static func waitReady(
        fd: Int32, events: Int16, until expiry: ContinuousClock.Instant? = nil
    ) async throws {
        while true {
            if Task.isCancelled { throw CancellationError() }
            if let expiry, ContinuousClock.now >= expiry {
                throw SocketIOError.idleTimeout
            }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let rc = Darwin.poll(&pfd, 1, 0)
            if rc > 0 {
                let hangup = Int16(POLLHUP | POLLERR | POLLNVAL)
                if pfd.revents & hangup != 0, pfd.revents & events == 0 {
                    throw SocketIOError.eof
                }
                return
            }
            if rc < 0 {
                if errno == EINTR { continue }
                throw SocketIOError.posix(errno)
            }
            if let expiry {
                let remaining = expiry - ContinuousClock.now
                if remaining <= .zero { throw SocketIOError.idleTimeout }
                try await Task.sleep(for: min(remaining, Duration.milliseconds(5)))
            } else {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

private enum ServeEvent: Sendable {
    case response(BridgeResponse)
    case disconnected
}

private enum SocketIOError: Error {
    case eof
    case posix(Int32)
    case idleTimeout
}

/// Caps open clients and lets `stop()` interrupt requests already in flight.
private final class ClientPool: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var descriptors: Set<Int32> = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func admit(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard descriptors.count < limit else { return false }
        descriptors.insert(fd)
        return true
    }

    func release(_ fd: Int32) {
        lock.lock()
        descriptors.remove(fd)
        lock.unlock()
    }

    func shutdownAll() {
        lock.lock()
        // Keep the lock until every shutdown is issued. Otherwise a worker can
        // remove and close an fd, the OS can reuse its number, and this loop can
        // accidentally shut down an unrelated new descriptor.
        for fd in descriptors {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
        lock.unlock()
    }
}

/// Listen socket + accept source. `@unchecked Sendable` because every mutable
/// field is read and written under `lock`, including from the source callbacks.
private final class ListenBox: @unchecked Sendable {
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "Sigil.BridgeServer")
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var path: String?
    private var onAccept: (@Sendable (Int32) -> Void)?
    private var closed: DispatchGroup?

    func bindAndListen(at url: URL, onAccept: @escaping @Sendable (Int32) -> Void) throws {
        lock.lock()
        let already = source != nil
        lock.unlock()
        if already { return }

        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = url.path
        if FileManager.default.fileExists(atPath: path) {
            if UnixSocket.isAccepting(at: path) {
                throw BridgeServer.Error.alreadyInUse
            }
            Darwin.unlink(path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeServer.Error.failed(operation: "socket", errno: errno)
        }
        applySocketFlags(fd)

        do {
            guard setNonBlocking(fd) else {
                throw BridgeServer.Error.failed(operation: "fcntl", errno: errno)
            }
            try UnixSocket.bind(fd, path: path)
            guard chmod(path, 0o600) == 0 else {
                throw BridgeServer.Error.failed(operation: "chmod", errno: errno)
            }
            guard Darwin.listen(fd, 32) == 0 else {
                throw BridgeServer.Error.failed(operation: "listen", errno: errno)
            }
        } catch {
            Darwin.close(fd)
            Darwin.unlink(path)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending()
        }
        let closed = DispatchGroup()
        closed.enter()
        source.setCancelHandler {
            Darwin.close(fd)
            closed.leave()
        }

        lock.lock()
        self.fd = fd
        self.source = source
        self.path = path
        self.onAccept = onAccept
        self.closed = closed
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
        let source = self.source
        let path = self.path
        let closed = self.closed
        self.source = nil
        self.path = nil
        self.onAccept = nil
        self.closed = nil
        fd = -1
        lock.unlock()
        source?.cancel()
        // Wait until the captured listen fd is closed so a later start()
        // cannot reuse that number while the cancel handler still holds it.
        closed?.wait()
        if let path {
            Darwin.unlink(path)
        }
    }

    private func acceptPending() {
        lock.lock()
        let listenFD = fd
        let onAccept = self.onAccept
        lock.unlock()
        guard listenFD >= 0, let onAccept else { return }

        while true {
            let client = Darwin.accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    return
                }
                return
            }
            applySocketFlags(client)
            guard setNonBlocking(client) else {
                Darwin.close(client)
                continue
            }
            onAccept(client)
        }
    }
}

enum UnixSocket {
    static let pathLimit = 104
    static let acceptProbeMilliseconds: Int32 = 250

    static func address(path: String) throws -> sockaddr_un {
        try path.withCString { cString in
            let length = Int(strlen(cString))
            guard length < pathLimit else { throw BridgeServer.Error.pathTooLong }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            addr.sun_len = UInt8(
                MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + length + 1)
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                dest.copyMemory(from: UnsafeRawBufferPointer(start: cString, count: length + 1))
            }
            return addr
        }
    }

    static func bind(_ fd: Int32, path: String) throws {
        var addr = try address(path: path)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw BridgeServer.Error.failed(operation: "bind", errno: errno)
        }
    }

    /// Non-blocking connect with a bounded poll. Timeout means "not accepting".
    static func isAccepting(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        applySocketFlags(fd)
        guard setNonBlocking(fd) else { return false }
        guard var addr = try? address(path: path) else { return false }
        let deadline = DispatchTime.now() + .milliseconds(Int(acceptProbeMilliseconds))
        var connectErrno: Int32 = 0
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                let result = Darwin.connect(
                    fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                connectErrno = errno
                return result
            }
        }
        if rc == 0 { return true }
        let code = connectErrno
        if code != EINPROGRESS && code != EALREADY && code != EAGAIN {
            return false
        }
        return waitUntilConnected(fd: fd, deadline: deadline)
    }

    private static func waitUntilConnected(fd: Int32, deadline: DispatchTime) -> Bool {
        while true {
            let now = DispatchTime.now()
            if now >= deadline { return false }
            let remainingNs = deadline.uptimeNanoseconds - now.uptimeNanoseconds
            let remainingMs = Int32(
                min((remainingNs + 999_999) / 1_000_000, UInt64(acceptProbeMilliseconds)))
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let rc = Darwin.poll(&pfd, 1, remainingMs)
            if rc == 0 { return false }
            if rc < 0 {
                if errno == EINTR { continue }
                return false
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                return false
            }
            return socketError == 0
        }
    }
}

private func applySocketFlags(_ fd: Int32) {
    let fdFlags = Darwin.fcntl(fd, F_GETFD)
    if fdFlags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC)
    }
    var yes: Int32 = 1
    _ = withUnsafePointer(to: &yes) {
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }
}

private func setNonBlocking(_ fd: Int32) -> Bool {
    let flags = Darwin.fcntl(fd, F_GETFL)
    guard flags >= 0 else { return false }
    return Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1
}
