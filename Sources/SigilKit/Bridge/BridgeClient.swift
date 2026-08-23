import Darwin
import Foundation

/// One-shot client for the Sigil tab-messaging unix socket.
///
/// Framing matches `BridgeFraming`: one request, one newline-delimited
/// response, then the connection closes. Blocking — call off the main thread.
public struct BridgeClient: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unreachable
        case timedOut
        case malformedResponse
    }

    private let socketURL: URL

    public init(socketURL: URL = BridgePaths.configuredSocket) {
        self.socketURL = socketURL
    }

    /// Sends one request and returns one response. The timeout is a total
    /// deadline for connect, write, and read; intermittent bytes do not reset it.
    /// Cancellation is checked while waiting, so cancelling the enclosing task
    /// closes the socket promptly and lets the app cancel a pending ask.
    public func send(_ request: BridgeRequest, timeout: Double) throws -> BridgeResponse {
        let frame = try BridgeFraming.frame(request)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.unreachable }
        defer { Darwin.close(fd) }

        var nosig: Int32 = 1
        _ = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        setNonBlocking(fd)

        let deadline = SocketDeadline(timeout: timeout)
        try connectUnix(fd, path: socketURL.path, deadline: deadline)
        try writeAll(fd, frame, deadline: deadline)
        return try readResponse(fd, deadline: deadline)
    }
}

private struct SocketDeadline: Sendable {
    let uptimeNanoseconds: UInt64

    init(timeout: Double) {
        let seconds = timeout.isFinite ? min(max(timeout, 0.001), 3_600) : 15
        let interval = UInt64((seconds * 1_000_000_000).rounded(.up))
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds &+ interval
    }

    var expired: Bool { DispatchTime.now().uptimeNanoseconds >= uptimeNanoseconds }

    /// A short poll interval makes Swift task cancellation prompt while the
    /// absolute deadline still bounds the entire request.
    var pollMilliseconds: Int32 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else { return 0 }
        let remaining = uptimeNanoseconds - now
        let roundedUp = (remaining + 999_999) / 1_000_000
        return Int32(min(max(roundedUp, 1), 50))
    }
}

private func connectUnix(_ fd: Int32, path: String, deadline: SocketDeadline) throws {
    var addr = sockaddr_un()
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = path.utf8.count
    guard pathBytes > 0, pathBytes < maxPath else { throw BridgeClient.Error.unreachable }

    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
        let raw = UnsafeMutableRawPointer(tuplePointer)
        path.withCString { cString in
            raw.copyMemory(from: cString, byteCount: pathBytes + 1)
        }
    }

    while true {
        try checkCancellationAndDeadline(deadline)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return }
        let code = errno
        if code == EINTR { continue }
        guard code == EINPROGRESS || code == EALREADY || code == EAGAIN else {
            throw BridgeClient.Error.unreachable
        }
        try waitReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
            socketError == 0
        else {
            throw BridgeClient.Error.unreachable
        }
        return
    }
}

private func writeAll(_ fd: Int32, _ data: Data, deadline: SocketDeadline) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            throw BridgeClient.Error.malformedResponse
        }
        var offset = 0
        while offset < rawBuffer.count {
            try checkCancellationAndDeadline(deadline)
            try waitReady(fd: fd, events: Int16(POLLOUT), deadline: deadline)
            let count = Darwin.write(fd, base + offset, rawBuffer.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                throw BridgeClient.Error.unreachable
            }
        }
    }
}

private func readResponse(_ fd: Int32, deadline: SocketDeadline) throws -> BridgeResponse {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4_096)
    while true {
        try checkCancellationAndDeadline(deadline)
        try waitReady(fd: fd, events: Int16(POLLIN), deadline: deadline)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk.prefix(count))
            do {
                let lines = try BridgeFraming.drainLines(from: &buffer)
                if let first = lines.first {
                    return try BridgeFraming.decode(BridgeResponse.self, from: first)
                }
            } catch {
                throw BridgeClient.Error.malformedResponse
            }
        } else if count == 0 {
            throw BridgeClient.Error.malformedResponse
        } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            continue
        } else {
            throw BridgeClient.Error.malformedResponse
        }
    }
}

private func waitReady(fd: Int32, events: Int16, deadline: SocketDeadline) throws {
    while true {
        try checkCancellationAndDeadline(deadline)
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = Darwin.poll(&descriptor, 1, deadline.pollMilliseconds)
        if result > 0 {
            if descriptor.revents & events != 0 { return }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                if events == Int16(POLLIN) { return }
                throw BridgeClient.Error.unreachable
            }
        } else if result == 0 {
            continue
        } else if errno != EINTR {
            throw BridgeClient.Error.unreachable
        }
    }
}

private func checkCancellationAndDeadline(_ deadline: SocketDeadline) throws {
    if Task.isCancelled { throw CancellationError() }
    if deadline.expired { throw BridgeClient.Error.timedOut }
}

private func setNonBlocking(_ fd: Int32) {
    let flags = Darwin.fcntl(fd, F_GETFL)
    if flags >= 0 {
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }
}
