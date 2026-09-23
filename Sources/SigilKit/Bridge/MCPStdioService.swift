import Foundation

/// JSON-RPC 2.0 (MCP) over newline-delimited stdin/stdout, with no IO of its own.
///
/// Each `tools/call` becomes one `BridgeRequest` sent through `transport`.
/// Socket failures must not kill the process: they come back as a tool error.
public struct MCPStdioService: Sendable {
    public typealias Transport = @Sendable (BridgeRequest) throws -> BridgeResponse

    public static let unreachableText =
        "Sigil is not running, or tab messaging is off. Ask the user to enable it in Sigil's settings."
    public static let protocolVersion = "2024-11-05"

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
        switch ParsedRPC.parse(trimmed) {
        case .parseError:
            return RPC.encodeError(id: NSNull(), code: -32700, message: "Parse error")
        case .invalidRequest:
            return RPC.encodeError(id: NSNull(), code: -32600, message: "Invalid Request")
        case .request(let parsed):
            return dispatch(parsed)
        }
    }
}

private enum RPCRequestID: Hashable, Sendable {
    case string(String)
    case number(String)

    init?(_ value: Any) {
        if let string = value as? String {
            self = .string(string)
            return
        }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number)
        else { return nil }
        self = .number(number.stringValue)
    }
}

private enum RPCParseResult {
    case request(ParsedRPC)
    case parseError
    case invalidRequest
}

private struct ParsedRPC {
    var id: Any
    var hasID: Bool
    /// Never empty: parse() refuses a request without one.
    var method: String
    var params: Any?
    var requestKey: RPCRequestID?

    static func parse(_ line: String) -> RPCParseResult {
        guard let data = line.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data)
        else { return .parseError }
        guard let object = raw as? [String: Any],
            object["jsonrpc"] as? String == "2.0",
            let method = object["method"] as? String,
            !method.isEmpty
        else { return .invalidRequest }

        let hasID = object.keys.contains("id")
        let id = object["id"] ?? NSNull()
        let requestKey = hasID ? RPCRequestID(id) : nil
        if hasID, requestKey == nil { return .invalidRequest }
        if let params = object["params"], !(params is [String: Any]) {
            return .invalidRequest
        }
        return .request(
            ParsedRPC(
                id: object["id"] ?? NSNull(),
                hasID: hasID,
                method: method,
                params: object["params"],
                requestKey: requestKey
            ))
    }

    var cancelledRequestKey: RPCRequestID? {
        guard method == "notifications/cancelled", !hasID,
            let params = params as? [String: Any],
            let requestID = params["requestId"]
        else { return nil }
        return RPCRequestID(requestID)
    }
}

extension MCPStdioService {
    private func dispatch(_ parsed: ParsedRPC) -> String? {
        switch parsed.method {
        case "notifications/initialized":
            guard !parsed.hasID else {
                return RPC.encodeError(id: parsed.id, code: -32600, message: "Invalid Request")
            }
            return nil
        case "notifications/cancelled":
            guard !parsed.hasID else {
                return RPC.encodeError(id: parsed.id, code: -32600, message: "Invalid Request")
            }
            return nil
        case "initialize":
            guard parsed.hasID else { return nil }
            guard let params = parsed.params as? [String: Any],
                RPC.nonBlankString(params["protocolVersion"]) != nil,
                params["capabilities"] is [String: Any],
                let clientInfo = params["clientInfo"] as? [String: Any],
                RPC.nonBlankString(clientInfo["name"]) != nil,
                RPC.nonBlankString(clientInfo["version"]) != nil
            else {
                return RPC.encodeError(id: parsed.id, code: -32602, message: "Invalid params")
            }
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
                guard let message = BridgeLimits.clampedMessage(message) else {
                    return RPC.toolResult(
                        id: id, text: "Missing required argument: message", isError: true)
                }
                return send(
                    id: id,
                    BridgeRequest(method: .sendToTab, from: peer, target: tab, text: message),
                    present: { response in
                        (Self.withNote("Queued.", response), false)
                    }
                )
            }
        case "ask_tab":
            return require(id: id, arguments, "tab", "question") { tab, question in
                guard let question = BridgeLimits.clampedMessage(question) else {
                    return RPC.toolResult(
                        id: id, text: "Missing required argument: question", isError: true)
                }
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
                    present: { response in Self.presentAsk(response) }
                )
            }
        case "reply_to":
            return require(id: id, arguments, "request_id", "answer") { requestID, answer in
                guard let answer = BridgeLimits.clampedMessage(answer) else {
                    return RPC.toolResult(
                        id: id, text: "Missing required argument: answer", isError: true)
                }
                return send(
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

    /// The app answers an ask with ok only when it carries the reply; a timeout
    /// comes back as a failure and never reaches here.
    private static func presentAsk(_ response: BridgeResponse) -> (String, Bool) {
        (withNote(response.answer ?? "", response), false)
    }

    private static func formatTabs(_ tabs: [BridgeTab]?) -> String {
        guard let tabs, !tabs.isEmpty else { return "No other tabs are open." }
        return tabs.map { tab in
            let fields = [tab.tabID, tab.title, tab.directory, tab.status]
                .map(sanitizeMetadata)
            var line = fields.joined(separator: "  ")
            if tab.isSelf { line += "  (you)" }
            return line
        }.joined(separator: "\n")
    }

    private static func sanitizeMetadata(_ value: String) -> String {
        let cleaned = BridgePrompt.sanitize(value)
        return cleaned.isEmpty ? "-" : cleaned
    }

    private static func withNote(_ text: String, _ response: BridgeResponse) -> String {
        guard let note = response.note?.nilIfBlank else { return text }
        return text + "\n" + note
    }

    private static func initializeResult() -> [String: Any] {
        [
            "protocolVersion": protocolVersion,
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
                    "Queue a message for another Sigil tab. The user must approve delivery; it does not wait for a reply. `tab` accepts the id or the title from list_tabs.",
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
                    "Queue a question for another Sigil tab and wait for its answer. The user must approve delivery. Waits up to timeout_seconds (default 300, max 900).",
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

/// Concurrent JSON-RPC session for the stdio executable. Requests may finish
/// out of order, as JSON-RPC permits, so a long `ask_tab` does not block pings,
/// tool discovery, or cancellation notifications.
public final class MCPStdioSession: @unchecked Sendable {
    public typealias Output = @Sendable (String) -> Void

    private let lock = NSLock()
    private let service: MCPStdioService
    private let output: Output
    private var jobs: [RPCRequestID: MCPInFlightJob] = [:]

    public init(service: MCPStdioService, output: @escaping Output) {
        self.service = service
        self.output = output
    }

    deinit {
        cancelAll()
    }

    /// Accepts one stdin line and returns immediately. Responses are passed to
    /// `output`; notifications intentionally produce no output.
    public func receive(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let parsedResult = ParsedRPC.parse(trimmed)
        if case .request(let parsed) = parsedResult,
            parsed.method == "notifications/cancelled",
            !parsed.hasID
        {
            if let key = parsed.cancelledRequestKey { cancel(key) }
            return
        }

        guard case .request(let parsed) = parsedResult,
            parsed.hasID,
            let key = parsed.requestKey
        else {
            if let response = service.handleLine(trimmed) { output(response) }
            return
        }

        let job = MCPInFlightJob()
        lock.lock()
        let duplicate = jobs[key] != nil
        if !duplicate {
            jobs[key] = job
        }
        lock.unlock()
        guard !duplicate else {
            output(RPC.encodeError(id: parsed.id, code: -32600, message: "Duplicate request id"))
            return
        }

        let task = Task.detached { [service, output, weak self, job] in
            defer { self?.finish(key, job: job) }
            let response = await MCPRequestLane().handle(trimmed, with: service)
            guard !Task.isCancelled, let response else { return }
            output(response)
        }
        job.install(task)
    }

    /// Cancels every bridge call when stdin closes or the executable exits.
    public func cancelAll() {
        lock.lock()
        let current = Array(jobs.values)
        lock.unlock()
        for job in current { job.cancel() }
    }

    public var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    private func cancel(_ key: RPCRequestID) {
        lock.lock()
        let job = jobs[key]
        lock.unlock()
        job?.cancel()
    }

    private func finish(_ key: RPCRequestID, job: MCPInFlightJob) {
        lock.lock()
        if jobs[key] === job { jobs.removeValue(forKey: key) }
        lock.unlock()
    }
}

/// Runs one request on its own dispatch thread. The transport blocks on a
/// socket, and blocked cooperative threads starve every other task, pings
/// included. The call stays in its task, so cancellation still reaches it.
private actor MCPRequestLane {
    private let queue = DispatchSerialQueue(label: "com.gl11tchy.sigil.mcp.request")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    func handle(_ line: String, with service: MCPStdioService) -> String? {
        service.handleLine(line)
    }
}

private final class MCPInFlightJob: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
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
