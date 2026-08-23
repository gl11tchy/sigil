import Darwin
import Foundation
import XCTest

@testable import SigilKit

@MainActor
final class BridgeServerTests: XCTestCase {
    private let peer = BridgePeer(tabID: "tab-1", sessionID: "sess-1")

    func testRoundTripListTabs() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        let tabs = [
            BridgeTab(
                tabID: "tab-1", title: "One", directory: "/tmp/a", status: "idle", isSelf: true),
            BridgeTab(
                tabID: "tab-2", title: "Two", directory: "/tmp/b", status: "working", isSelf: false),
        ]
        env.delegate.tabs = tabs

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))

        XCTAssertEqual(env.delegate.listedPeers, [peer])
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.tabs, tabs)
        XCTAssertNil(response.error)
    }

    func testRoundTripSendToTab() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        env.delegate.sendResponse = BridgeResponse(ok: true, note: "delivered")

        let response = try await env.roundTrip(
            BridgeRequest(method: .sendToTab, from: peer, target: "tab-2", text: "hello there")
        )

        XCTAssertEqual(env.delegate.sent, [
            .init(peer: peer, target: "tab-2", message: "hello there")
        ])
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.note, "delivered")
    }

    func testRoundTripAskTab() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        env.delegate.askResponse = BridgeResponse(ok: true, answer: "because", requestID: "q-1")

        let response = try await env.roundTrip(
            BridgeRequest(
                method: .askTab, from: peer, target: "tab-2", text: "why?", timeoutSeconds: 42)
        )

        XCTAssertEqual(env.delegate.asked, [
            .init(peer: peer, target: "tab-2", question: "why?", timeout: 42)
        ])
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.answer, "because")
        XCTAssertEqual(response.requestID, "q-1")
    }

    func testRoundTripReplyTo() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        env.delegate.replyResponse = BridgeResponse(ok: true, note: "accepted")

        let response = try await env.roundTrip(
            BridgeRequest(method: .replyTo, from: peer, text: "the answer", requestID: "req-9")
        )

        XCTAssertEqual(env.delegate.replies, [
            .init(peer: peer, requestID: "req-9", answer: "the answer")
        ])
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.note, "accepted")
    }

    func testSlowAskDoesNotBlockListTabs() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        env.delegate.askSleep = .seconds(1)
        env.delegate.tabs = [
            BridgeTab(
                tabID: "tab-1", title: "One", directory: "/tmp", status: "idle", isSelf: true)
        ]

        let socketURL = env.socketURL
        let askRequest = BridgeRequest(
            method: .askTab, from: peer, target: "tab-2", text: "slow?", timeoutSeconds: 30)
        let askTask = Task.detached {
            try RawBridgeClient.roundTrip(askRequest, at: socketURL)
        }

        let reachedAsk = await waitUntil { env.delegate.asked.count == 1 }
        XCTAssertTrue(reachedAsk, "ask should reach the delegate before list_tabs is sent")

        let listStart = ContinuousClock.now
        let list = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        let listElapsed = ContinuousClock.now - listStart

        XCTAssertEqual(list.ok, true)
        XCTAssertEqual(list.tabs, env.delegate.tabs)
        XCTAssertLessThan(listElapsed, Duration.milliseconds(400))

        let ask = try await askTask.value
        XCTAssertEqual(ask.ok, true)
        XCTAssertEqual(env.delegate.asked.count, 1)
        XCTAssertEqual(env.delegate.listedPeers, [peer])
    }

    func testVersionMismatch() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }

        let response = try await env.roundTrip(
            BridgeRequest(version: 99, method: .listTabs, from: peer)
        )

        XCTAssertEqual(response.ok, false)
        let error = try XCTUnwrap(response.error)
        XCTAssertTrue(error.contains("99"), error)
        XCTAssertTrue(error.lowercased().contains("version"), error)
        XCTAssertEqual(env.delegate.listedPeers, [])
    }

    func testAnonymousPeer() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }

        let response = try await env.roundTrip(
            BridgeRequest(method: .listTabs, from: BridgePeer())
        )

        XCTAssertEqual(response.ok, false)
        XCTAssertNotNil(response.error)
        XCTAssertEqual(env.delegate.listedPeers, [])
    }

    func testGarbageFrameLeavesServerAlive() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }

        let garbage = try await env.roundTrip(raw: Data("{{{not json\n".utf8))
        XCTAssertEqual(garbage.ok, false)
        XCTAssertNotNil(garbage.error)

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(env.delegate.listedPeers, [peer])
    }

    func testOversizedFrameClosesWithoutResponse() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        let socketURL = env.socketURL

        try await Task.detached {
            let fd = try RawBridgeClient.connect(to: socketURL)
            defer { Darwin.close(fd) }
            let blob = Data(repeating: 0x41, count: BridgeLimits.maxFrameBytes + 64)
            _ = try? RawBridgeClient.writeAll(blob, to: fd)
            let line = try? RawBridgeClient.readLine(from: fd)
            XCTAssertTrue(
                line == nil || line?.isEmpty == true,
                "oversized frame must close with no response")
        }.value

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(env.delegate.listedPeers, [peer])
    }

    func testStartThrowsWhenSocketAlreadyInUse() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }

        let other = BridgeServer(socketURL: env.socketURL)
        XCTAssertThrowsError(try other.start()) { error in
            XCTAssertEqual(error as? BridgeServer.Error, .alreadyInUse)
        }
        XCTAssertFalse(other.isListening)
        XCTAssertTrue(env.server.isListening)

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        XCTAssertEqual(response.ok, true)
    }

    func testStartReplacesStaleSocket() async throws {
        let env = try TestEnv(start: false)
        defer { env.tearDown() }
        try plantStaleUnixSocket(at: env.socketURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.socketURL.path))

        XCTAssertNoThrow(try env.server.start())
        XCTAssertTrue(env.server.isListening)

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        XCTAssertEqual(response.ok, true)
    }

    func testStopUnlinksAndStartAgainWorks() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.socketURL.path))

        env.server.stop()
        XCTAssertFalse(env.server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.socketURL.path))

        try env.server.start()
        XCTAssertTrue(env.server.isListening)

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(env.delegate.listedPeers, [peer])
    }

    func testSplitWritesAssembleOneFrame() async throws {
        let env = try TestEnv()
        defer { env.tearDown() }
        let socketURL = env.socketURL
        let request = BridgeRequest(method: .listTabs, from: peer)

        let response = try await Task.detached {
            let fd = try RawBridgeClient.connect(to: socketURL)
            defer { Darwin.close(fd) }
            let frame = try BridgeFraming.frame(request)
            let mid = max(1, frame.count / 2)
            try RawBridgeClient.writeAll(frame.prefix(mid), to: fd)
            try await Task.sleep(for: .milliseconds(50))
            try RawBridgeClient.writeAll(frame.suffix(from: mid), to: fd)
            return try RawBridgeClient.readResponse(from: fd)
        }.value

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(env.delegate.listedPeers, [peer])
    }

    func testNoDelegate() async throws {
        let env = try TestEnv(attachDelegate: false)
        defer { env.tearDown() }

        let response = try await env.roundTrip(BridgeRequest(method: .listTabs, from: peer))
        XCTAssertEqual(response.ok, false)
        let error = try XCTUnwrap(response.error)
        XCTAssertTrue(error.lowercased().contains("not ready"), error)
    }
}

@MainActor
private final class TestEnv {
    let socketURL: URL
    let server: BridgeServer
    let delegate: RecordingDelegate

    init(start: Bool = true, attachDelegate: Bool = true) throws {
        let short = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        socketURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(short).s")
        XCTAssertLessThan(
            socketURL.path.count, 100, "unix bind path is \(socketURL.path.count) chars")
        delegate = RecordingDelegate()
        server = BridgeServer(socketURL: socketURL)
        if attachDelegate {
            server.delegate = delegate
        }
        if start {
            try server.start()
        }
    }

    func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: socketURL)
    }

    func roundTrip(_ request: BridgeRequest) async throws -> BridgeResponse {
        let url = socketURL
        return try await Task.detached {
            try RawBridgeClient.roundTrip(request, at: url)
        }.value
    }

    func roundTrip(raw: Data) async throws -> BridgeResponse {
        let url = socketURL
        return try await Task.detached {
            try RawBridgeClient.roundTrip(raw: raw, at: url)
        }.value
    }
}

@MainActor
private final class RecordingDelegate: BridgeServerDelegate {
    struct SendCall: Equatable {
        var peer: BridgePeer
        var target: String
        var message: String
    }

    struct AskCall: Equatable {
        var peer: BridgePeer
        var target: String
        var question: String
        var timeout: Double
    }

    struct ReplyCall: Equatable {
        var peer: BridgePeer
        var requestID: String
        var answer: String
    }

    var listedPeers: [BridgePeer] = []
    var sent: [SendCall] = []
    var asked: [AskCall] = []
    var replies: [ReplyCall] = []

    var tabs: [BridgeTab] = []
    var sendResponse = BridgeResponse(ok: true)
    var askResponse = BridgeResponse(ok: true, answer: "pong")
    var replyResponse = BridgeResponse(ok: true)
    var askSleep: Duration = .zero

    func bridgeListTabs(asking peer: BridgePeer) -> [BridgeTab] {
        listedPeers.append(peer)
        return tabs
    }

    func bridgeSend(from peer: BridgePeer, to target: String, message: String) -> BridgeResponse {
        sent.append(.init(peer: peer, target: target, message: message))
        return sendResponse
    }

    func bridgeAsk(
        from peer: BridgePeer, to target: String, question: String, timeout: Double
    ) async -> BridgeResponse {
        asked.append(.init(peer: peer, target: target, question: question, timeout: timeout))
        if askSleep > .zero {
            try? await Task.sleep(for: askSleep)
        }
        return askResponse
    }

    func bridgeReply(from peer: BridgePeer, requestID: String, answer: String) -> BridgeResponse {
        replies.append(.init(peer: peer, requestID: requestID, answer: answer))
        return replyResponse
    }
}

private enum RawBridgeClient {
    enum Error: Swift.Error {
        case connectFailed(Int32)
        case writeFailed
        case timeout
        case eof
    }

    static func roundTrip(_ request: BridgeRequest, at url: URL) throws -> BridgeResponse {
        try roundTrip(raw: try BridgeFraming.frame(request), at: url)
    }

    static func roundTrip(raw: Data, at url: URL) throws -> BridgeResponse {
        let fd = try connect(to: url)
        defer { Darwin.close(fd) }
        try writeAll(raw, to: fd)
        return try readResponse(from: fd)
    }

    static func connect(to url: URL) throws -> Int32 {
        var last = Error.connectFailed(0)
        for _ in 0..<40 {
            do {
                return try connectOnce(to: url)
            } catch let error as Error {
                last = error
                usleep(10_000)
            }
        }
        throw last
    }

    static func connectOnce(to url: URL) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.connectFailed(errno) }
        var yes: Int32 = 1
        _ = withUnsafePointer(to: &yes) {
            Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = Darwin.setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = Darwin.setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = unixAddress(path: url.path)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let code = errno
            Darwin.close(fd)
            throw Error.connectFailed(code)
        }
        return fd
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, data.count - offset)
            }
            if n > 0 {
                offset += Int(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                throw Error.writeFailed
            }
        }
    }

    static func readLine(from fd: Int32) throws -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0A {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    return buffer
                }
                buffer.append(byte)
            } else if n == 0 {
                return buffer.isEmpty ? nil : buffer
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw Error.timeout
            } else {
                throw Error.eof
            }
        }
    }

    static func readResponse(from fd: Int32) throws -> BridgeResponse {
        guard let line = try readLine(from: fd), !line.isEmpty else { throw Error.eof }
        return try BridgeFraming.decode(BridgeResponse.self, from: line)
    }
}

private func unixAddress(path: String) -> sockaddr_un {
    path.withCString { cString in
        let length = Int(strlen(cString))
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

private func plantStaleUnixSocket(at url: URL) throws {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer { Darwin.close(fd) }
    var addr = unixAddress(path: url.path)
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    XCTAssertEqual(rc, 0, "stale bind failed errno=\(errno)")
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
