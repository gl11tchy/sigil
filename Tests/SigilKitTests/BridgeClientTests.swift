import Darwin
import Foundation
import Testing

@testable import SigilKit

struct BridgeClientTests {
    @Test func roundTrip() throws {
        let expected = BridgeResponse(
            ok: true,
            tabs: [
                BridgeTab(
                    tabID: "t1", title: "One", directory: "/tmp", status: "idle", isSelf: true)
            ],
            note: "ok"
        )
        try withThrowawayServer { conn in
            _ = try? readLineData(conn)
            if let data = try? BridgeFraming.frame(expected) {
                try? writeAll(conn, data)
            }
        } body: { url in
            let client = BridgeClient(socketURL: url)
            let response = try client.send(
                BridgeRequest(method: .listTabs, from: BridgePeer(tabID: "t1")),
                timeout: 3
            )
            #expect(response == expected)
        }
    }

    @Test func serverCloseWithoutAnswerIsMalformedResponse() throws {
        try withThrowawayServer { conn in
            _ = try? readLineData(conn)
        } body: { url in
            let client = BridgeClient(socketURL: url)
            #expect(throws: BridgeClient.Error.malformedResponse) {
                try client.send(
                    BridgeRequest(method: .listTabs, from: BridgePeer(tabID: "t1")),
                    timeout: 3
                )
            }
        }
    }

    @Test func missingSocketIsUnreachable() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        #expect(url.path.count < 100)
        let client = BridgeClient(socketURL: url)
        #expect(throws: BridgeClient.Error.unreachable) {
            try client.send(
                BridgeRequest(method: .listTabs, from: BridgePeer()),
                timeout: 0.5
            )
        }
    }

    @Test func responseSplitAcrossTwoWritesIsAssembled() throws {
        let expected = BridgeResponse(ok: true, answer: "split-across-writes")
        let payload = try BridgeFraming.frame(expected)
        #expect(payload.count > 2)
        let mid = payload.count / 2
        try withThrowawayServer { conn in
            _ = try? readLineData(conn)
            try? writeAll(conn, payload.prefix(mid))
            usleep(50_000)
            try? writeAll(conn, payload.suffix(from: payload.startIndex + mid))
        } body: { url in
            let client = BridgeClient(socketURL: url)
            let response = try client.send(
                BridgeRequest(
                    method: .askTab, from: BridgePeer(tabID: "t1"), target: "other",
                    text: "q"),
                timeout: 3
            )
            #expect(response == expected)
        }
    }
}

private func withThrowawayServer(
    handle: @escaping @Sendable (Int32) -> Void,
    body: (URL) throws -> Void
) throws {
    let url = throwawaySocketURL()
    #expect(url.path.count < 100)
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw BridgeClient.Error.unreachable }

    let listen = ListenBox(fd: fd)
    defer {
        listen.close()
        unlink(url.path)
    }
    try bindUnix(fd, path: url.path)
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    _ = Darwin.setsockopt(
        fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard Darwin.listen(fd, 4) == 0 else { throw BridgeClient.Error.unreachable }

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        defer { group.leave() }
        guard let conn = acceptOnce(fd) else { return }
        defer { Darwin.close(conn) }
        handle(conn)
    }
    defer {
        listen.close()
        group.wait()
    }
    try body(url)
}

private final class ListenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(fd: Int32) { self.fd = fd }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        fd = -1
    }
}

private func throwawaySocketURL() -> URL {
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    if candidate.path.count < 100 { return candidate }
    return URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")
}

private func bindUnix(_ fd: Int32, path: String) throws {
    unlink(path)
    var addr = sockaddr_un()
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = path.utf8.count
    guard pathBytes > 0, pathBytes < maxPath else {
        throw BridgeClient.Error.unreachable
    }
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
        let raw = UnsafeMutableRawPointer(tuplePointer)
        path.withCString { cString in
            raw.copyMemory(from: cString, byteCount: pathBytes + 1)
        }
    }
    let rc = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { throw BridgeClient.Error.unreachable }
}

private func acceptOnce(_ listenFD: Int32) -> Int32? {
    var addr = sockaddr_un()
    var length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let conn = withUnsafeMutablePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.accept(listenFD, sockaddrPointer, &length)
        }
    }
    return conn >= 0 ? conn : nil
}

private func readLineData(_ fd: Int32) throws -> Data {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4_096)
    while true {
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n > 0 {
            buffer.append(contentsOf: chunk.prefix(n))
            let lines = try BridgeFraming.drainLines(from: &buffer)
            if let first = lines.first { return first }
            continue
        }
        if n == 0 { throw BridgeClient.Error.malformedResponse }
        if errno == EINTR { continue }
        throw BridgeClient.Error.malformedResponse
    }
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
        var offset = 0
        let total = rawBuffer.count
        while offset < total {
            let n = Darwin.write(fd, base + offset, total - offset)
            if n > 0 {
                offset += n
                continue
            }
            if n == 0 { throw BridgeClient.Error.unreachable }
            if errno == EINTR { continue }
            throw BridgeClient.Error.unreachable
        }
    }
}
