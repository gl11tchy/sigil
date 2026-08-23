import Foundation

/// JSON-RPC 2.0 (MCP) over newline-delimited stdin/stdout, with no IO of its own.
///
/// Each `tools/call` becomes one `BridgeRequest` sent through `transport`.
/// Socket failures must not kill the process: they come back as a tool error.
public struct MCPStdioService: Sendable {
    public typealias Transport = @Sendable (BridgeRequest) throws -> BridgeResponse

    public static let unreachableText =
        "Sigil is not running, or tab messaging is off. Ask the user to enable it in Sigil's settings."

    private let peer: BridgePeer
    private let transport: Transport

    public init(
        peer: BridgePeer = BridgePaths.peerFromEnvironment,
        transport: @escaping Transport
    ) {
        self.peer = peer
        self.transport = transport
    }

    /// One stdin line in, at most one JSON-RPC response line out. `nil` means
    /// a notification: write nothing.
    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let parsed = ParsedRPC.parse(trimmed) else {
            return RPC.encodeError(id: NSNull(), code: -32700, message: "Parse error")
        }
        return dispatch(parsed)
    }
}

private struct ParsedRPC {
    var id: Any
    var hasID: Bool
    var method: String?
    var params: Any?

    static func parse(_ line: String) -> ParsedRPC? {
        guard let data = line.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else { return nil }
        return ParsedRPC(
            id: object["id"] ?? NSNull(),
            hasID: object.keys.contains("id"),
            method: object["method"] as? String,
            params: object["params"]
        )
    }
}

extension MCPStdioService {
    private func dispatch(_ parsed: ParsedRPC) -> String? {
        guard let method = parsed.method, !method.isEmpty else {
            guard parsed.hasID else { return nil }
            return RPC.encodeError(id: parsed.id, code: -32600, message: "Invalid Request")
        }

        switch method {
        case "notifications/initialized":
            return nil
        case "initialize":
            guard parsed.hasID else { return nil }
            return RPC.encodeResult(id: parsed.id, result: Self.initializeResult())
        case "ping":
            guard parsed.hasID else { return nil }
            return RPC.encodeResult(id: parsed.id, result: [String: Any]())
        case "tools/list":
            guard parsed.hasID else { return nil }
            return RPC.encodeResult(id: parsed.id, result: ["tools": Self.toolCatalog()])
        case "tools/call":
            guard parsed.hasID else { return nil }
            return callTool(id: parsed.id, params: parsed.params)
        default:
            guard parsed.hasID else { return nil }
            return RPC.encodeError(id: parsed.id, code: -32601, message: "Method not found")
        }
    }

    private func callTool(id: Any, params: Any?) -> String {
        let dict = params as? [String: Any] ?? [:]
        guard let name = RPC.nonBlankString(dict["name"]) else {
            return RPC.toolResult(id: id, text: "Missing required argument: name", isError: true)
        }
        let arguments = dict["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "list_tabs":
            return send(
                id: id,
                BridgeRequest(method: .listTabs, from: peer),
                present: Self.presentList
            )
        case "send_to_tab":
            return require(id: id, arguments, "tab", "message") { tab, message in
                send(
                    id: id,
                    BridgeRequest(method: .sendToTab, from: peer, target: tab, text: message),
                    present: { response in
                        (Self.withNote("Delivered.", response), false)
                    }
                )
            }
        case "ask_tab":
            return require(id: id, arguments, "tab", "question") { tab, question in
                let timeout = BridgeLimits.clampedAskSeconds(RPC.number(arguments["timeout_seconds"]))
                return send(
                    id: id,
                    BridgeRequest(
                        method: .askTab,
                        from: peer,
                        target: tab,
                        text: question,
                        timeoutSeconds: timeout
                    ),
                    present: { response in Self.presentAsk(response, timeout: timeout) }
                )
            }
        case "reply_to":
            return require(id: id, arguments, "request_id", "answer") { requestID, answer in
                send(
                    id: id,
                    BridgeRequest(
                        method: .replyTo, from: peer, text: answer, requestID: requestID),
                    present: { response in
                        (Self.withNote("Replied.", response), false)
                    }
                )
            }
        default:
            return RPC.toolResult(id: id, text: "Unknown tool: \(name)", isError: true)
        }
    }

    private func require(
        id: Any,
        _ arguments: [String: Any],
        _ first: String,
        _ second: String,
        then: (String, String) -> String
    ) -> String {
        guard let a = RPC.nonBlankString(arguments[first]) else {
            return RPC.toolResult(
                id: id, text: "Missing required argument: \(first)", isError: true)
        }
        guard let b = RPC.nonBlankString(arguments[second]) else {
            return RPC.toolResult(
                id: id, text: "Missing required argument: \(second)", isError: true)
        }
        return then(a, b)
    }

    private func send(
        id: Any,
        _ request: BridgeRequest,
        present: (BridgeResponse) -> (String, Bool)
    ) -> String {
        let response: BridgeResponse
        do {
            response = try transport(request)
        } catch {
            return RPC.toolResult(id: id, text: Self.unreachableText, isError: true)
        }
        if !response.ok {
            let text = Self.withNote(response.error ?? "Sigil bridge error", response)
            return RPC.toolResult(id: id, text: text, isError: true)
        }
        let (text, isError) = present(response)
        return RPC.toolResult(id: id, text: text, isError: isError)
    }

    private static func presentList(_ response: BridgeResponse) -> (String, Bool) {
        (withNote(formatTabs(response.tabs), response), false)
    }

    private static func presentAsk(_ response: BridgeResponse, timeout: Double) -> (String, Bool) {
        if let answer = response.answer?.nilIfBlank {
            return (withNote(answer, response), false)
        }
        let seconds = timeout.rounded() == timeout ? String(Int(timeout)) : String(timeout)
        return (
            withNote("The other tab did not answer within \(seconds) seconds.", response),
            true
        )
    }

    private static func formatTabs(_ tabs: [BridgeTab]?) -> String {
        guard let tabs, !tabs.isEmpty else { return "No other tabs are open." }
        return tabs.map { tab in
            var line = "\(tab.tabID)  \(tab.title)  \(tab.directory)  \(tab.status)"
            if tab.isSelf { line += "  (you)" }
            return line
        }.joined(separator: "\n")
    }

    private static func withNote(_ text: String, _ response: BridgeResponse) -> String {
        guard let note = response.note?.nilIfBlank else { return text }
        return text + "\n" + note
    }

    private static func initializeResult() -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "sigil", "version": "1"],
        ]
    }

    /// Catalog is independent of the call handlers on purpose: tests compare
    /// `inputSchema.required` against the arguments those handlers actually read.
    private static func toolCatalog() -> [[String: Any]] {
        [
            [
                "name": "list_tabs",
                "description":
                    "List the other Sigil tabs open right now, with their id, title, folder and status. Call this before sending or asking.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String](),
                ],
            ],
            [
                "name": "send_to_tab",
                "description":
                    "Hand a message to another Sigil tab. Returns as soon as it is delivered; it does not wait for a reply. `tab` accepts the id or the title from list_tabs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab": ["type": "string"],
                        "message": ["type": "string"],
                    ],
                    "required": ["tab", "message"],
                ],
            ],
            [
                "name": "ask_tab",
                "description":
                    "Ask another Sigil tab a question and wait for its answer. Use this when you need the result before you continue. Waits up to timeout_seconds (default 300, max 900).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab": ["type": "string"],
                        "question": ["type": "string"],
                        "timeout_seconds": ["type": "number"],
                    ],
                    "required": ["tab", "question"],
                ],
            ],
            [
                "name": "reply_to",
                "description":
                    "Answer a question another tab asked you. The request id is in the message you received.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "request_id": ["type": "string"],
                        "answer": ["type": "string"],
                    ],
                    "required": ["request_id", "answer"],
                ],
            ],
        ]
    }
}

private enum RPC {
    static func encodeResult(id: Any, result: Any) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func encodeError(id: Any, code: Int, message: String) -> String {
        encode([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message],
        ])
    }

    static func toolResult(id: Any, text: String, isError: Bool) -> String {
        encodeResult(
            id: id,
            result: [
                "content": [["type": "text", "text": text]],
                "isError": isError,
            ]
        )
    }

    static func encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
        }
        return string
    }

    static func nonBlankString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string.nilIfBlank
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            // JSON booleans ride on NSNumber; a timeout must be numeric.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}
