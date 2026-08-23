import Foundation
import XCTest

@testable import SigilKit

@MainActor
final class BridgeIntegrationTests: XCTestCase {
    private let peer = BridgePeer(tabID: "tab-self", sessionID: "sess-self")

    func testListTabsMarksCallerAndNamesBothTabs() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        let tabs = [
            BridgeTab(
                tabID: "tab-self", title: "Self", directory: "/tmp/self", status: "working",
                isSelf: true),
            BridgeTab(
                tabID: "tab-other", title: "Other", directory: "/tmp/other", status: "idle",
                isSelf: false),
        ]
        env.delegate.tabs = tabs

        let outcome = try await callTool(env, "list_tabs", [:])

        XCTAssertEqual(env.delegate.listedPeers, [peer])
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(
            outcome.text,
            "tab-self  Self  /tmp/self  working  (you)\ntab-other  Other  /tmp/other  idle")
        XCTAssertTrue(outcome.text.contains("Self"))
        XCTAssertTrue(outcome.text.contains("Other"))
        XCTAssertTrue(outcome.text.contains("(you)"))
    }

    func testSendToTabDeliversExactMessage() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        env.delegate.sendResponse = BridgeResponse(ok: true, note: "to Other")

        let outcome = try await callTool(
            env, "send_to_tab", ["tab": "tab-other", "message": "hello there"])

        XCTAssertEqual(env.delegate.sent, [
            .init(peer: peer, target: "tab-other", message: "hello there")
        ])
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "Delivered.\nto Other")
    }

    func testAskTabReturnsAnswerText() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        env.delegate.askResponse = BridgeResponse(ok: true, answer: "because", requestID: "q-1")

        let outcome = try await callTool(
            env, "ask_tab",
            ["tab": "tab-other", "question": "why?", "timeout_seconds": 30])

        XCTAssertEqual(env.delegate.asked, [
            .init(peer: peer, target: "tab-other", question: "why?", timeout: 30)
        ])
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "because")
    }

    func testReplyToDeliversExactAnswer() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        env.delegate.replyResponse = BridgeResponse(ok: true, note: "accepted")

        let outcome = try await callTool(
            env, "reply_to", ["request_id": "req-9", "answer": "the answer"])

        XCTAssertEqual(env.delegate.replies, [
            .init(peer: peer, requestID: "req-9", answer: "the answer")
        ])
        XCTAssertFalse(outcome.isError)
        XCTAssertEqual(outcome.text, "Replied.\naccepted")
    }

    func testAskTabDelayedAnswerContainsTheAnswer() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        env.delegate.askSleep = .milliseconds(120)
        env.delegate.askResponse = BridgeResponse(ok: true, answer: "after-a-pause")

        let outcome = try await callTool(
            env, "ask_tab",
            ["tab": "tab-other", "question": "slow?", "timeout_seconds": 30])

        XCTAssertEqual(env.delegate.asked, [
            .init(peer: peer, target: "tab-other", question: "slow?", timeout: 30)
        ])
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.contains("after-a-pause"), outcome.text)
    }

    func testAskTabTimeoutResponseIsError() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        env.delegate.askResponse = BridgeResponse(ok: true, answer: nil)

        let outcome = try await callTool(
            env, "ask_tab",
            ["tab": "tab-other", "question": "anyone there?", "timeout_seconds": 30])

        XCTAssertEqual(env.delegate.asked, [
            .init(peer: peer, target: "tab-other", question: "anyone there?", timeout: 30)
        ])
        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.lowercased().contains("not answer"), outcome.text)
        XCTAssertTrue(outcome.text.contains("30"), outcome.text)
    }

    func testStoppedServerReturnsUnreachableText() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        env.server.stop()

        let outcome = try await callTool(env, "list_tabs", [:])

        XCTAssertEqual(env.delegate.listedPeers, [])
        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, MCPStdioService.unreachableText)
    }

    func testLongMessageSurvivesRoundTrip() async throws {
        let env = try TestEnv(peer: peer)
        defer { env.tearDown() }
        let message = String(repeating: "m", count: BridgeLimits.maxMessageCharacters + 250)

        let outcome = try await callTool(
            env, "send_to_tab", ["tab": "tab-other", "message": message])

        let received = try XCTUnwrap(env.delegate.sent.first?.message)
        XCTAssertFalse(received.isEmpty)
        let prefixCount = min(received.count, message.count, BridgeLimits.maxMessageCharacters)
        XCTAssertGreaterThan(prefixCount, 0)
        XCTAssertEqual(String(received.prefix(prefixCount)), String(message.prefix(prefixCount)))
        XCTAssertFalse(outcome.isError)
        XCTAssertTrue(outcome.text.hasPrefix("Delivered."))
    }

    // MARK: - Helpers

    private func callTool(
        _ env: TestEnv,
        _ name: String,
        _ arguments: [String: Any],
        timeout: TimeInterval = 8
    ) async throws -> (text: String, isError: Bool) {
        let finished = expectation(description: "\(name) round trip")
        let box = ResultBox<(text: String, isError: Bool)>()
        let service = env.service
        let line = toolCall(name, arguments)
        Task.detached {
            do {
                try box.succeed(parseToolOutcome(service.handleLine(line)))
            } catch {
                box.fail(error)
            }
            await MainActor.run { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: timeout)
        return try box.value()
    }
}

@MainActor
private final class TestEnv {
    let socketURL: URL
    let server: BridgeServer
    let delegate: RecordingDelegate
    let service: MCPStdioService

    init(peer: BridgePeer) throws {
        let short = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
        socketURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(short).s")
        XCTAssertLessThan(
            socketURL.path.count, 100, "unix bind path is \(socketURL.path.count) chars")
        delegate = RecordingDelegate()
        server = BridgeServer(socketURL: socketURL)
        server.delegate = delegate
        try server.start()
        let client = BridgeClient(socketURL: socketURL)
        service = MCPStdioService(peer: peer) { request in
            try client.send(request, timeout: socketTimeout(for: request))
        }
    }

    func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: socketURL)
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

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func succeed(_ value: T) {
        lock.lock()
        result = .success(value)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        result = .failure(error)
        lock.unlock()
    }

    func value() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw ToolParseError.timedOut
        }
    }
}

private enum ToolParseError: Error {
    case missingLine
    case malformed
    case timedOut
}

private func toolCall(_ name: String, _ arguments: [String: Any]) -> String {
    let object: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

private func parseToolOutcome(_ line: String?) throws -> (text: String, isError: Bool) {
    guard let line else { throw ToolParseError.missingLine }
    let raw = try JSONSerialization.jsonObject(with: Data(line.utf8))
    guard let object = raw as? [String: Any],
        let result = object["result"] as? [String: Any],
        let content = result["content"] as? [Any],
        let first = content.first as? [String: Any],
        let text = first["text"] as? String,
        first["type"] as? String == "text"
    else { throw ToolParseError.malformed }
    if let flag = result["isError"] as? Bool {
        return (text, flag)
    }
    if let number = result["isError"] as? NSNumber {
        return (text, number.boolValue)
    }
    throw ToolParseError.malformed
}

private func socketTimeout(for request: BridgeRequest) -> Double {
    switch request.method {
    case .askTab:
        return BridgeLimits.clampedAskSeconds(request.timeoutSeconds) + 30
    case .listTabs, .sendToTab, .replyTo:
        return 15
    }
}
