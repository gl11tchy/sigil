import Darwin
import Foundation
import XCTest

@testable import SigilKit

final class UnixSocketTests: XCTestCase {
    func testProbeAgainstLiveAcceptingSocketReturnsTruePromptly() throws {
        try withUnixListener(backlog: 8) { path, _ in
            let start = ContinuousClock.now
            let live = UnixSocket.isAccepting(at: path)
            let elapsed = ContinuousClock.now - start

            XCTAssertTrue(live)
            XCTAssertLessThan(elapsed, probeBound)
        }
    }

    func testProbeAgainstStaleOrMissingSocketReturnsFalsePromptly() throws {
        let missing = uniqueSocketPath()
        let missingStart = ContinuousClock.now
        let missingLive = UnixSocket.isAccepting(at: missing)
        let missingElapsed = ContinuousClock.now - missingStart
        XCTAssertFalse(missingLive)
        XCTAssertLessThan(missingElapsed, probeBound)

        let stale = uniqueSocketPath()
        let bindFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(bindFD, 0)
        do {
            try UnixSocket.bind(bindFD, path: stale)
        } catch {
            Darwin.close(bindFD)
            throw error
        }
        Darwin.close(bindFD)
        defer { Darwin.unlink(stale) }

        let staleStart = ContinuousClock.now
        let staleLive = UnixSocket.isAccepting(at: stale)
        let staleElapsed = ContinuousClock.now - staleStart
        XCTAssertFalse(staleLive)
        XCTAssertLessThan(staleElapsed, probeBound)
    }

    func testStaleProbeIsTrueOnlyForAClosedSocket() throws {
        let stale = uniqueSocketPath()
        let bindFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(bindFD, 0)
        do {
            try UnixSocket.bind(bindFD, path: stale)
        } catch {
            Darwin.close(bindFD)
            throw error
        }
        Darwin.close(bindFD)
        defer { Darwin.unlink(stale) }
        XCTAssertTrue(UnixSocket.isStaleSocket(at: stale))

        XCTAssertFalse(UnixSocket.isStaleSocket(at: uniqueSocketPath()))

        try withUnixListener(backlog: 8) { path, _ in
            let start = ContinuousClock.now
            XCTAssertFalse(UnixSocket.isStaleSocket(at: path))
            XCTAssertLessThan(ContinuousClock.now - start, probeBound)
        }

        try withUnixListener(backlog: 1) { path, _ in
            let held = try fillListenQueue(at: path)
            XCTAssertFalse(held.isEmpty, "listen backlog 1 should queue at least one connect")
            defer {
                for fd in held { Darwin.close(fd) }
            }
            let start = ContinuousClock.now
            XCTAssertFalse(UnixSocket.isStaleSocket(at: path))
            XCTAssertLessThan(ContinuousClock.now - start, probeBound)
        }
    }

    func testProbeAgainstNonAcceptingListenerDoesNotExceedTimeout() throws {
        try withUnixListener(backlog: 1) { path, _ in
            let held = try fillListenQueue(at: path)
            XCTAssertFalse(held.isEmpty, "listen backlog 1 should queue at least one connect")
            defer {
                for fd in held { Darwin.close(fd) }
            }

            let start = ContinuousClock.now
            let live = UnixSocket.isAccepting(at: path)
            let elapsed = ContinuousClock.now - start

            XCTAssertFalse(live)
            XCTAssertLessThan(
                elapsed,
                Duration.milliseconds(Int(UnixSocket.acceptProbeMilliseconds) + 200)
            )
        }
    }
}

private var probeBound: Duration {
    Duration.milliseconds(Int(UnixSocket.acceptProbeMilliseconds))
}

private func uniqueSocketPath() -> String {
    let short = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(short).s")
    XCTAssertLessThan(url.path.count, UnixSocket.pathLimit)
    return url.path
}

private func withUnixListener(
    backlog: Int32, _ body: (String, Int32) throws -> Void
) throws {
    let path = uniqueSocketPath()
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0)
    defer {
        Darwin.close(fd)
        Darwin.unlink(path)
    }
    try UnixSocket.bind(fd, path: path)
    let listenRC = Darwin.listen(fd, backlog)
    XCTAssertEqual(listenRC, 0, "listen failed errno=\(errno)")
    guard listenRC == 0 else { return }
    try body(path, fd)
}

private func fillListenQueue(at path: String) throws -> [Int32] {
    var addr = try UnixSocket.address(path: path)
    var held: [Int32] = []
    for _ in 0..<64 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { break }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 {
            held.append(fd)
        } else {
            Darwin.close(fd)
            break
        }
    }
    return held
}
