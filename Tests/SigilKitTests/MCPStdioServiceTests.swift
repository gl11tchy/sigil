import Darwin
import Foundation
import Testing

@testable import SigilKit

struct MCPStdioServiceTests {
    private let peer = BridgePeer(tabID: "self-tab", sessionID: "self-session")

    @Test func initializeReplyShape() throws {
        let (service, recorder) = makeService()
        let line = try #require(
            service.handleLine(Self.initializeLine))
        let object = try parseObject(line)
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect((object["id"] as? NSNumber)?.intValue == 1)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == MCPStdioService.protocolVersion)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        let tools = try #require(capabilities["tools"] as? [String: Any])
        #expect(tools.isEmpty)
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "sigil")
        #expect(info["version"] as? String == "1")
        #expect(recorder.requests.isEmpty)
    }

    @Test func initializedNotificationProducesNoLine() {
        let (service, recorder) = makeService()
        #expect(
            service.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(recorder.requests.isEmpty)
    }

    @Test func toolsListReturnsExactlyFourTools() throws {
        let (service, _) = makeService()
        let tools = try listedTools(service)
        #expect(Set(tools.keys) == ["list_tabs", "send_to_tab", "ask_tab", "reply_to"])
        #expect(tools.count == 4)
    }

    @Test func queuedToolDescriptionsDiscloseUserApproval() throws {
        let (service, _) = makeService()
        let tools = try listedTools(service)

        for name in ["send_to_tab", "ask_tab"] {
            let description = try #require(tools[name]?["description"] as? String)
            #expect(description.localizedCaseInsensitiveContains("user must approve"))
        }
    }

    @Test(arguments: ["list_tabs", "send_to_tab", "ask_tab", "reply_to"])
    func schemaRequiredMatchesHandlerReads(tool: String) throws {
        let (service, recorder) = makeService { request in
            switch request.method {
            case .listTabs: return BridgeResponse(ok: true, tabs: [])
            case .askTab: return BridgeResponse(ok: true, answer: "ok")
            case .sendToTab, .replyTo: return BridgeResponse(ok: true)
            }
        }
        let catalog = try listedTools(service)
        let schema = try #require(catalog[tool]?["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["properties"] as? [String: Any] != nil)
        #expect(schema["required"] != nil)
        let required = ((schema["required"] as? [Any]) ?? []).compactMap { $0 as? String }

        let fixture = try #require(Self.argumentFixtures[tool])
        var onlyRequired: [String: Any] = [:]
        for key in required {
            onlyRequired[key] = fixture[key] ?? ""
        }
        recorder.reset()
        let happy = try toolOutcome(service.handleLine(Self.toolCall(tool, onlyRequired)))
        #expect(!happy.isError)
        #expect(recorder.requests.count == 1)

        for key in required {
            recorder.reset()
            var omitted = onlyRequired
            omitted.removeValue(forKey: key)
            let outcome = try toolOutcome(service.handleLine(Self.toolCall(tool, omitted)))
            #expect(outcome.isError)
            #expect(outcome.text.contains(key))
            #expect(recorder.requests.isEmpty)
        }
    }

    @Test(arguments: [
        ToolHappyPath(
            name: "list_tabs", argumentsJSON: "{}", method: .listTabs,
            target: nil, text: nil, requestID: nil, timeoutSeconds: nil),
        ToolHappyPath(
            name: "send_to_tab",
            argumentsJSON: #"{"tab":"other","message":"hello"}"#,
            method: .sendToTab, target: "other", text: "hello", requestID: nil,
            timeoutSeconds: nil),
        ToolHappyPath(
            name: "ask_tab",
            argumentsJSON: #"{"tab":"other","question":"why?","timeout_seconds":1}"#,
            method: .askTab, target: "other", text: "why?", requestID: nil,
            timeoutSeconds: BridgeLimits.minAskSeconds),
        ToolHappyPath(
            name: "reply_to",
            argumentsJSON: #"{"request_id":"req-1","answer":"because"}"#,
            method: .replyTo, target: nil, text: "because", requestID: "req-1",
            timeoutSeconds: nil),
    ])
    func happyPathSendsExactBridgeRequest(path: ToolHappyPath) throws {
        let (service, recorder) = makeService { request in
            switch request.method {
            case .listTabs:
                return BridgeResponse(ok: true, tabs: [])
            case .askTab:
                return BridgeResponse(ok: true, answer: "42")
            case .sendToTab, .replyTo:
                return BridgeResponse(ok: true)
            }
        }
        let arguments = try parseObject(path.argumentsJSON)
        let outcome = try toolOutcome(service.handleLine(Self.toolCall(path.name, arguments)))
        #expect(!outcome.isError)
        let received = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(
            received
                == BridgeRequest(
                    version: BridgeProtocol.version,
                    method: path.method,
                    from: peer,
                    target: path.target,
                    text: path.text,
                    requestID: path.requestID,
                    timeoutSeconds: path.timeoutSeconds
                ))
    }

    @Test func listTabsFormatsEachTabAndMarksSelf() throws {
        let tabs = [
            BridgeTab(
                tabID: "aaa", title: "Alpha", directory: "/tmp/a", status: "idle", isSelf: true),
            BridgeTab(
                tabID: "bbb", title: "Beta", directory: "/tmp/b", status: "working", isSelf: false),
        ]
        let (service, _) = makeService { _ in BridgeResponse(ok: true, tabs: tabs) }
        let outcome = try toolOutcome(service.handleLine(Self.toolCall("list_tabs", [:])))
        #expect(!outcome.isError)
        let lines = outcome.text.split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "aaa  Alpha  /tmp/a  idle  (you)")
        #expect(lines[1] == "bbb  Beta  /tmp/b  working")
        #expect(!lines[1].contains("(you)"))
    }

    @Test func listTabsEmptyReadsAsNoOtherTabs() throws {
        let (service, _) = makeService { _ in BridgeResponse(ok: true, tabs: []) }
        let outcome = try toolOutcome(service.handleLine(Self.toolCall("list_tabs", [:])))
        #expect(!outcome.isError)
        #expect(outcome.text == "No other tabs are open.")
    }

    @Test func listTabsFlattensUntrustedMetadata() throws {
        let tabs = [
            BridgeTab(
                tabID: "aaa\nforged-id",
                title: "Alpha\r\nforged-title",
                directory: "/tmp/a\tforged-directory",
                status: "idle\u{0007}forged-status",
                isSelf: false)
        ]
        let (service, _) = makeService { _ in BridgeResponse(ok: true, tabs: tabs) }
        let outcome = try toolOutcome(service.handleLine(Self.toolCall("list_tabs", [:])))
        #expect(outcome.text.split(separator: "\n").count == 1)
        #expect(outcome.text.contains("aaa forged-id"))
        #expect(outcome.text.contains("Alpha forged-title"))
        #expect(outcome.text.contains("/tmp/a forged-directory"))
        #expect(outcome.text.contains("idle forged-status"))
    }

    @Test func askTabWithoutAnswerIsATimeoutSentence() throws {
        let (service, _) = makeService { _ in BridgeResponse(ok: true, answer: nil) }
        let outcome = try toolOutcome(
            service.handleLine(
                Self.toolCall("ask_tab", ["tab": "other", "question": "why?"])))
        #expect(outcome.isError)
        #expect(outcome.text.contains("300"))
        #expect(outcome.text.lowercased().contains("not answer"))
    }

    @Test func toolMessageIsByteLimitedBeforeSocketTransport() throws {
        let (service, recorder) = makeService { _ in BridgeResponse(ok: true) }
        let oneGrapheme = "a" + String(repeating: "\u{0301}", count: 9_000)
        let outcome = try toolOutcome(
            service.handleLine(
                Self.toolCall("send_to_tab", ["tab": "other", "message": oneGrapheme])
            ))
        #expect(!outcome.isError)
        let sent = try #require(recorder.requests.first?.text)
        #expect(sent.utf8.count <= BridgeLimits.maxMessageBytes)
        #expect(sent.contains("truncated by Sigil"))
    }

    @Test(arguments: [
        (Optional<Double>.none, BridgeLimits.defaultAskSeconds),
        (Optional(1.0), BridgeLimits.minAskSeconds),
        (Optional(60.0), 60.0),
        (Optional(BridgeLimits.maxAskSeconds), BridgeLimits.maxAskSeconds),
        (Optional(BridgeLimits.maxAskSeconds + 1), BridgeLimits.maxAskSeconds),
        (Optional(-5.0), BridgeLimits.minAskSeconds),
    ])
    func askTabClampsTimeoutOnTheBridgeRequest(requested: Double?, expected: Double) throws {
        let (service, recorder) = makeService { _ in
            BridgeResponse(ok: true, answer: "ok")
        }
        var arguments: [String: Any] = ["tab": "other", "question": "why?"]
        if let requested {
            arguments["timeout_seconds"] = requested
        }
        _ = service.handleLine(Self.toolCall("ask_tab", arguments))
        let received = try #require(recorder.requests.first)
        #expect(received.timeoutSeconds == expected)
        #expect(received.timeoutSeconds == BridgeLimits.clampedAskSeconds(requested))
    }

    @Test(arguments: [
        ("send_to_tab", "tab", ["tab": "  ", "message": "hello"]),
        ("send_to_tab", "message", ["tab": "other", "message": ""]),
        ("ask_tab", "tab", ["tab": "\n", "question": "why?"]),
        ("ask_tab", "question", ["tab": "other", "question": "   "]),
        ("reply_to", "request_id", ["request_id": " ", "answer": "yes"]),
        ("reply_to", "answer", ["request_id": "r1", "answer": "\t"]),
    ])
    func blankRequiredArgumentIsAnErrorAndDoesNotSend(
        tool: String, argument: String, arguments: [String: String]
    ) throws {
        let (service, recorder) = makeService()
        var anyArguments: [String: Any] = [:]
        for (key, value) in arguments { anyArguments[key] = value }
        let outcome = try toolOutcome(service.handleLine(Self.toolCall(tool, anyArguments)))
        #expect(outcome.isError)
        #expect(outcome.text.contains(argument))
        #expect(recorder.requests.isEmpty)
    }

    @Test func bridgeFailureBecomesToolErrorAndAppendsNote() throws {
        let (service, _) = makeService { _ in
            BridgeResponse(ok: false, error: "no such tab", note: "tried Beta")
        }
        let outcome = try toolOutcome(
            service.handleLine(
                Self.toolCall("send_to_tab", ["tab": "Beta", "message": "hi"])))
        #expect(outcome.isError)
        #expect(outcome.text.contains("no such tab"))
        #expect(outcome.text.contains("tried Beta"))
    }

    @Test func missingErrorTextFallsBackWhenNotOk() throws {
        let (service, _) = makeService { _ in BridgeResponse(ok: false, error: nil) }
        let outcome = try toolOutcome(service.handleLine(Self.toolCall("list_tabs", [:])))
        #expect(outcome.isError)
        #expect(outcome.text == "Sigil bridge error")
    }

    @Test func transportErrorUsesUnreachableTextAndStillServesTheNextRequest() throws {
        let recorder = Recorder()
        let service = MCPStdioService(peer: peer) { request in
            recorder.append(request)
            if recorder.requests.count == 1 {
                throw BridgeClient.Error.unreachable
            }
            return BridgeResponse(ok: true, tabs: [])
        }
        let first = try toolOutcome(service.handleLine(Self.toolCall("list_tabs", [:])))
        #expect(first.isError)
        #expect(first.text == MCPStdioService.unreachableText)
        let second = try toolOutcome(service.handleLine(Self.toolCall("list_tabs", [:])))
        #expect(!second.isError)
        #expect(second.text == "No other tabs are open.")
        let ping = try #require(service.handleLine(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#))
        let pingObject = try parseObject(ping)
        let pingResult = try #require(pingObject["result"] as? [String: Any])
        #expect(pingResult.isEmpty)
        #expect(recorder.requests.count == 2)
    }

    @Test func unknownMethodIsMinus32601() throws {
        let (service, recorder) = makeService()
        let line = try #require(
            service.handleLine(#"{"jsonrpc":"2.0","id":7,"method":"no/such"}"#))
        let object = try parseObject(line)
        let error = try #require(object["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32601)
        #expect(error["message"] as? String == "Method not found")
        #expect((object["id"] as? NSNumber)?.intValue == 7)
        #expect(recorder.requests.isEmpty)
    }

    @Test func unparseableLineIsMinus32700WithNullID() throws {
        let (service, recorder) = makeService()
        let line = try #require(service.handleLine("{"))
        let object = try parseObject(line)
        #expect(object["id"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32700)
        #expect(recorder.requests.isEmpty)
    }

    @Test(arguments: [
        #"{"id":1,"method":"ping"}"#,
        #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
        #"{"jsonrpc":2,"id":1,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#,
        #"[]"#,
    ])
    func invalidJSONRPCEnvelopeIsMinus32600(requestLine: String) throws {
        let (service, recorder) = makeService()
        let line = try #require(service.handleLine(requestLine))
        let object = try parseObject(line)
        #expect(object["id"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32600)
        #expect(recorder.requests.isEmpty)
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":[],"method":"ping"}"#,
    ])
    func invalidRequestIDTypeIsRejected(requestLine: String) throws {
        let (service, _) = makeService()
        let object = try parseObject(try #require(service.handleLine(requestLine)))
        #expect(object["id"] is NSNull)
        let error = try #require(object["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32600)
    }

    @Test func initializeRejectsNonStringProtocolVersion() throws {
        let (service, _) = makeService()
        let line = try #require(
            service.handleLine(
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}"#
            ))
        let object = try parseObject(line)
        let error = try #require(object["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32602)
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{}}}"#,
    ])
    func initializeRequiresAdvertisedFields(requestLine: String) throws {
        let (service, _) = makeService()
        let line = try #require(service.handleLine(requestLine))
        let error = try #require(try parseObject(line)["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32602)
    }

    @Test func notificationMethodsRejectAnID() throws {
        let (service, _) = makeService()
        let line = try #require(
            service.handleLine(
                #"{"jsonrpc":"2.0","id":1,"method":"notifications/initialized"}"#
            ))
        let error = try #require(try parseObject(line)["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32600)
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
    ])
    func requestIDRoundTripsUnchanged(requestLine: String) throws {
        let (service, _) = makeService()
        let responseLine = try #require(service.handleLine(requestLine))
        let request = try parseObject(requestLine)
        let response = try parseObject(responseLine)
        #expect(jsonEquals(request["id"] ?? NSNull(), response["id"] ?? NSNull()))
    }

    @Test func stdioSessionDoesNotLetAskBlockPing() async throws {
        let gate = DispatchSemaphore(value: 0)
        let started = SignalProbe()
        let service = MCPStdioService(peer: peer) { request in
            if request.method == .askTab {
                started.signal()
                _ = gate.wait(timeout: .now() + 2)
                return BridgeResponse(ok: true, answer: "done")
            }
            return BridgeResponse(ok: true, tabs: [])
        }
        let lines = LineRecorder()
        let session = MCPStdioSession(service: service, output: lines.append)
        defer {
            gate.signal()
            session.cancelAll()
        }

        session.receive(Self.toolCall("ask_tab", ["tab": "other", "question": "wait"]))
        #expect(await waitFor { started.value })
        session.receive(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        #expect(await waitFor { lines.hasResponse(id: 2) })
        #expect(!lines.hasResponse(id: 1))

        gate.signal()
        #expect(await waitFor { lines.hasResponse(id: 1) })
        #expect(await waitFor { session.inFlightCount == 0 })
    }

    @Test func cancelledNotificationStopsAnInFlightCallWithoutResponse() async {
        let started = SignalProbe()
        let service = MCPStdioService(peer: peer) { _ in
            started.signal()
            while !Task.isCancelled { usleep(5_000) }
            throw CancellationError()
        }
        let lines = LineRecorder()
        let session = MCPStdioSession(service: service, output: lines.append)
        defer { session.cancelAll() }

        session.receive(Self.toolCall("ask_tab", ["tab": "other", "question": "wait"]))
        #expect(await waitFor { started.value })
        session.receive(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        )
        #expect(await waitFor { session.inFlightCount == 0 })
        #expect(lines.values.isEmpty)
    }

    @Test func stdioSessionAllowsACompletedRequestIDToBeReused() async {
        let service = MCPStdioService(peer: peer) { _ in BridgeResponse(ok: true, tabs: []) }
        let lines = LineRecorder()
        let session = MCPStdioSession(service: service, output: lines.append)
        defer { session.cancelAll() }

        let ping = #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#
        session.receive(ping)
        #expect(await waitFor { lines.values.count == 1 && session.inFlightCount == 0 })
        session.receive(ping)
        #expect(await waitFor { lines.values.count == 2 })
        let second = try? parseObject(lines.values[1])
        #expect(second?["result"] != nil)
        #expect(second?["error"] == nil)
    }

    // MARK: - Helpers

    private static let argumentFixtures: [String: [String: String]] = [
        "list_tabs": [:],
        "send_to_tab": ["tab": "other", "message": "hello"],
        "ask_tab": ["tab": "other", "question": "why?"],
        "reply_to": ["request_id": "r1", "answer": "yes"],
    ]

    private static let initializeLine =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"#

    private func makeService(
        _ transport: @escaping @Sendable (BridgeRequest) throws -> BridgeResponse = { _ in
            BridgeResponse(ok: true, tabs: [])
        }
    ) -> (MCPStdioService, Recorder) {
        let recorder = Recorder()
        let service = MCPStdioService(peer: peer) { request in
            recorder.append(request)
            return try transport(request)
        }
        return (service, recorder)
    }

    private static func toolCall(_ name: String, _ arguments: [String: Any]) -> String {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func listedTools(_ service: MCPStdioService) throws -> [String: [String: Any]] {
        let line = try #require(
            service.handleLine(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))
        let object = try parseObject(line)
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [Any])
        var map: [String: [String: Any]] = [:]
        for tool in tools {
            let dict = try #require(tool as? [String: Any])
            let name = try #require(dict["name"] as? String)
            map[name] = dict
        }
        return map
    }

    private func toolOutcome(_ line: String?) throws -> (text: String, isError: Bool) {
        let object = try parseObject(try #require(line))
        let result = try #require(object["result"] as? [String: Any])
        let content = try #require(result["content"] as? [Any])
        let first = try #require(content.first as? [String: Any])
        let text = try #require(first["text"] as? String)
        #expect(first["type"] as? String == "text")
        let isError = (result["isError"] as? Bool) ?? ((result["isError"] as? NSNumber)?.boolValue)
        return (text, try #require(isError as Bool?))
    }
}

struct ToolHappyPath: Sendable {
    var name: String
    var argumentsJSON: String
    var method: BridgeMethod
    var target: String?
    var text: String?
    var requestID: String?
    var timeoutSeconds: Double?
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BridgeRequest] = []

    var requests: [BridgeRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: BridgeRequest) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(request)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

private final class SignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func signal() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

private final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func hasResponse(id: Int) -> Bool {
        values.contains { line in
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let object = raw as? [String: Any]
            else { return false }
            return (object["id"] as? NSNumber)?.intValue == id
        }
    }
}

private func waitFor(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

private func parseObject(_ line: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
    return try #require(object as? [String: Any])
}

private func jsonEquals(_ left: Any, _ right: Any) -> Bool {
    let leftData = try? JSONSerialization.data(withJSONObject: [left])
    let rightData = try? JSONSerialization.data(withJSONObject: [right])
    return leftData != nil && leftData == rightData
}
