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

    /// Owns the listen fd and DispatchSource. Sendable so `deinit` can stop it.
    private let listenBox = ListenBox()

    public init(socketURL: URL = BridgePaths.defaultSocket) {
        self.socketURL = socketURL
    }

    deinit {
        listenBox.stop()
    }

    /// Throws if the path cannot be bound. Safe to call twice (second is a no-op).
    public func start() throws {
        if isListening { return }
        try listenBox.bindAndListen(at: socketURL) { [weak self] clientFD in
            Task.detached { [weak self] in
                guard let self else {
                    Darwin.close(clientFD)
                    return
                }
                await self.serve(clientFD: clientFD)
            }
        }
        isListening = true
    }

    public func stop() {
        listenBox.stop()
        isListening = false
    }

    nonisolated private func serve(clientFD: Int32) async {
        defer { Darwin.close(clientFD) }
        let frame: Data
        do {
            frame = try await Self.readFrame(from: clientFD)
        } catch {
            return
        }
        let response = await processFrame(frame)
        guard let data = try? BridgeFraming.frame(response) else { return }
        try? await Self.writeFully(data, to: clientFD)
    }

    private func processFrame(_ frame: Data) async -> BridgeResponse {
        let request: BridgeRequest
        do {
            request = try BridgeFraming.decode(BridgeRequest.self, from: frame)
        } catch {
            return .failure("undecodable request")
        }
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
            guard let target = request.target else {
                return .failure("send_to_tab requires a target")
            }
            return delegate.bridgeSend(
                from: request.from, to: target, message: request.text ?? "")
        case .askTab:
            guard let target = request.target else {
                return .failure("ask_tab requires a target")
            }
            let timeout = request.timeoutSeconds ?? BridgeLimits.defaultAskSeconds
            return await delegate.bridgeAsk(
                from: request.from, to: target, question: request.text ?? "", timeout: timeout)
        case .replyTo:
            guard let requestID = request.requestID else {
                return .failure("reply_to requires a requestID")
            }
            return delegate.bridgeReply(
                from: request.from, requestID: requestID, answer: request.text ?? "")
        }
    }

    nonisolated private static func readFrame(from fd: Int32) async throws -> Data {
        var buffer = Data()
        while true {
            if Task.isCancelled { throw CancellationError() }
            try await waitReady(fd: fd, events: Int16(POLLIN))
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

    nonisolated private static func writeFully(_ data: Data, to fd: Int32) async throws {
        var offset = 0
        while offset < data.count {
            if Task.isCancelled { throw CancellationError() }
            try await waitReady(fd: fd, events: Int16(POLLOUT))
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

    nonisolated private static func waitReady(fd: Int32, events: Int16) async throws {
        while true {
            if Task.isCancelled { throw CancellationError() }
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
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum SocketIOError: Error {
    case eof
    case posix(Int32)
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
            try UnixSocket.bind(fd, path: path)
            guard chmod(path, 0o600) == 0 else {
                throw BridgeServer.Error.failed(operation: "chmod", errno: errno)
            }
            guard Darwin.listen(fd, 32) == 0 else {
                throw BridgeServer.Error.failed(operation: "listen", errno: errno)
            }
            setNonBlocking(fd)
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
            setNonBlocking(client)
            onAccept(client)
        }
    }
}

private enum UnixSocket {
    static let pathLimit = 104

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

    static func isAccepting(at path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard let addr = try? address(path: path) else { return false }
        var mutable = addr
        let rc = withUnsafePointer(to: &mutable) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
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

private func setNonBlocking(_ fd: Int32) {
    let flags = Darwin.fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
