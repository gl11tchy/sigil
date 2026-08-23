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

    /// Sends one request and returns the one response. Blocking; call off the main thread.
    public func send(_ request: BridgeRequest, timeout: Double) throws -> BridgeResponse {
        let frame = try BridgeFraming.frame(request)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.unreachable }
        defer { Darwin.close(fd) }

        var nosig: Int32 = 1
        _ = Darwin.setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        setTimeouts(fd, seconds: timeout)

        try connectUnix(fd, path: socketURL.path)
        try writeAll(fd, frame)
        return try readResponse(fd)
    }
}

private func setTimeouts(_ fd: Int32, seconds: Double) {
    let clamped = seconds.isFinite ? min(max(seconds, 0.001), 3_600) : 15
    let whole = clamped.rounded(.towardZero)
    var tv = timeval(
        tv_sec: time_t(whole),
        tv_usec: suseconds_t((clamped - whole) * 1_000_000)
    )
    let length = socklen_t(MemoryLayout<timeval>.size)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, length)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, length)
}

private func connectUnix(_ fd: Int32, path: String) throws {
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
        let rc = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return }
        let err = errno
        if err == EINTR { continue }
        throw BridgeClient.Error.unreachable
    }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            throw BridgeClient.Error.malformedResponse
        }
        var offset = 0
        let total = rawBuffer.count
        while offset < total {
            let n = Darwin.write(fd, base + offset, total - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 { throw BridgeClient.Error.unreachable }
            let err = errno
            if err == EINTR { continue }
            if err == EAGAIN || err == EWOULDBLOCK || err == ETIMEDOUT {
                throw BridgeClient.Error.timedOut
            }
            throw BridgeClient.Error.unreachable
        }
    }
}

private func readResponse(_ fd: Int32) throws -> BridgeResponse {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4_096)
    while true {
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk.prefix(n))
            if buffer.count > BridgeLimits.maxFrameBytes {
                throw BridgeClient.Error.malformedResponse
            }
            do {
                let lines = try BridgeFraming.drainLines(from: &buffer)
                if let first = lines.first {
                    return try BridgeFraming.decode(BridgeResponse.self, from: first)
                }
            } catch {
                throw BridgeClient.Error.malformedResponse
            }
            continue
        }
        if n == 0 {
            throw BridgeClient.Error.malformedResponse
        }
        let err = errno
        if err == EINTR { continue }
        if err == EAGAIN || err == EWOULDBLOCK || err == ETIMEDOUT {
            throw BridgeClient.Error.timedOut
        }
        throw BridgeClient.Error.malformedResponse
    }
}
