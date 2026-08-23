import Foundation

/// The wire contract between Sigil and the `grok` sessions it hosts.
///
/// Grok has no session-to-session channel of its own, so Sigil is the broker:
/// it owns every tab's pty, so it is the only process that can see them all.
/// Each tab's `grok` gets an MCP server (`sigil-mcp`) whose tools turn into
/// one request on a unix socket that the app listens on.
///
/// Framing is newline-delimited JSON. One request per connection, one response
/// back, then the connection closes. `ask` holds its connection open until the
/// other tab answers, so a long question is a slow response, not a poll loop.
public enum BridgeProtocol {

    /// Bumped when a field changes meaning. The app refuses a mismatched client
    /// rather than guessing, because a stale `sigil-mcp` can outlive an upgrade.
    public static let version = 1
}

/// Who is speaking. Sigil sets `SIGIL_TAB_ID` on each child, and `grok` puts
/// `GROK_SESSION_ID` in the environment of every MCP server it launches, so a
/// caller can be resolved even when the app never chose the session id itself
/// (a `--continue` tab).
public struct BridgePeer: Codable, Sendable, Hashable {
    public var tabID: String?
    public var sessionID: String?

    public init(tabID: String? = nil, sessionID: String? = nil) {
        self.tabID = tabID
        self.sessionID = sessionID
    }

    /// True when neither identifier is present, which means the client was not
    /// launched by Sigil and cannot be placed in the tab list.
    public var isAnonymous: Bool {
        tabID?.nilIfBlank == nil && sessionID?.nilIfBlank == nil
    }
}

public enum BridgeMethod: String, Codable, Sendable {
    /// Every tab Sigil currently has open.
    case listTabs = "list_tabs"
    /// Hand a message to another tab and return without waiting.
    case sendToTab = "send_to_tab"
    /// Hand a question to another tab and wait for its answer.
    case askTab = "ask_tab"
    /// Answer a question a previous `askTab` is still waiting on.
    case replyTo = "reply_to"
}

public struct BridgeRequest: Codable, Sendable, Hashable {
    public var version: Int
    public var method: BridgeMethod
    public var from: BridgePeer
    /// Tab id for `sendToTab` / `askTab`. A title is also accepted, so a model
    /// can address the tab it just saw in `list_tabs` without copying a uuid.
    public var target: String?
    /// The message, the question, or the answer, depending on `method`.
    public var text: String?
    /// The question being answered, for `replyTo`.
    public var requestID: String?
    /// How long `askTab` waits. Clamped by the app; see `BridgeLimits`.
    public var timeoutSeconds: Double?

    public init(
        version: Int = BridgeProtocol.version,
        method: BridgeMethod,
        from: BridgePeer,
        target: String? = nil,
        text: String? = nil,
        requestID: String? = nil,
        timeoutSeconds: Double? = nil
    ) {
        self.version = version
        self.method = method
        self.from = from
        self.target = target
        self.text = text
        self.requestID = requestID
        self.timeoutSeconds = timeoutSeconds
    }
}

/// One open tab, as the other tabs see it.
public struct BridgeTab: Codable, Sendable, Hashable {
    public var tabID: String
    public var title: String
    public var directory: String
    /// `working`, `idle`, or `exited`.
    public var status: String
    /// True for the tab that asked, so a model does not message itself.
    public var isSelf: Bool

    public init(
        tabID: String, title: String, directory: String, status: String, isSelf: Bool
    ) {
        self.tabID = tabID
        self.title = title
        self.directory = directory
        self.status = status
        self.isSelf = isSelf
    }
}

public struct BridgeResponse: Codable, Sendable, Hashable {
    public var ok: Bool
    /// Set when `ok` is false. Text a model can act on, not a code.
    public var error: String?
    public var tabs: [BridgeTab]?
    /// The other tab's answer, for `askTab`.
    public var answer: String?
    /// The id the answering tab must pass back to `replyTo`.
    public var requestID: String?
    /// Extra context worth showing the model, such as the resolved tab title.
    public var note: String?

    public init(
        ok: Bool,
        error: String? = nil,
        tabs: [BridgeTab]? = nil,
        answer: String? = nil,
        requestID: String? = nil,
        note: String? = nil
    ) {
        self.ok = ok
        self.error = error
        self.tabs = tabs
        self.answer = answer
        self.requestID = requestID
        self.note = note
    }

    public static func failure(_ message: String) -> BridgeResponse {
        BridgeResponse(ok: false, error: message)
    }
}

public enum BridgeLimits {
    /// Longest `ask_tab` wait the app honours. Past this the asking tab gets a
    /// timeout it can report, rather than a tool call that never returns.
    public static let maxAskSeconds: Double = 900
    public static let defaultAskSeconds: Double = 300
    public static let minAskSeconds: Double = 5
    /// Longest single UTF-8 message. A byte limit prevents one extended
    /// grapheme from expanding into an arbitrarily large socket frame.
    public static let maxMessageBytes = 8_000
    /// Source compatibility for clients built against version 1 of the API.
    public static let maxMessageCharacters = maxMessageBytes
    /// Refuses a frame that could only be a runaway or a different protocol.
    public static let maxFrameBytes = 1 << 20

    public static func clampedAskSeconds(_ requested: Double?) -> Double {
        guard let requested, requested.isFinite else { return defaultAskSeconds }
        return min(max(requested, minAskSeconds), maxAskSeconds)
    }

    /// Sanitizes and trims `text` to the byte cap, marking it so the reader
    /// knows why it stops. Returns `nil` when nothing visible remains.
    public static func clampedMessage(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = BridgePrompt.sanitize(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let bytes = Data(cleaned.utf8)
        guard bytes.count > maxMessageBytes else { return cleaned }

        let suffix = " [truncated by Sigil at \(maxMessageBytes) bytes]"
        let prefixLimit = max(0, maxMessageBytes - suffix.utf8.count)
        var prefixBytes = Data(bytes.prefix(prefixLimit))
        while String(data: prefixBytes, encoding: .utf8) == nil, !prefixBytes.isEmpty {
            prefixBytes.removeLast()
        }
        guard let prefix = String(data: prefixBytes, encoding: .utf8) else { return nil }
        return prefix + suffix
    }
}

/// Newline-delimited JSON framing, shared by both ends of the socket.
public enum BridgeFraming {

    public enum Error: Swift.Error, Equatable {
        case frameTooLarge
        case notUTF8
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys keep the wire bytes stable, which makes the tests readable.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Encodes `value` as one frame, including its trailing newline.
    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        guard data.count <= BridgeLimits.maxFrameBytes else { throw Error.frameTooLarge }
        // A payload may not contain a raw newline: JSON escapes them, so the
        // separator stays unambiguous without any further quoting.
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }

    /// Splits `buffer` into complete frames, leaving any partial tail behind.
    ///
    /// Reads from a socket arrive in arbitrary chunks, so both ends accumulate
    /// into a buffer and drain it through here. Empty lines are dropped rather
    /// than reported: a peer that writes `\r\n` should not look like an error.
    public static func drainLines(from buffer: inout Data) throws -> [Data] {
        var lines: [Data] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            let length = buffer.distance(from: buffer.startIndex, to: index)
            guard length <= BridgeLimits.maxFrameBytes else { throw Error.frameTooLarge }
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            let trimmed = trimTrailingReturn(Data(line))
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        if buffer.count > BridgeLimits.maxFrameBytes { throw Error.frameTooLarge }
        return lines
    }

    private static func trimTrailingReturn(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }
}

/// Where the socket lives. Kept short on purpose: `sockaddr_un.sun_path` holds
/// 104 bytes, and a path built under the user's home is already half of that.
public enum BridgePaths {

    public static let socketEnvironmentKey = "SIGIL_BRIDGE_SOCKET"
    public static let tabEnvironmentKey = "SIGIL_TAB_ID"
    /// Set by `grok` itself on every MCP server it launches.
    public static let grokSessionEnvironmentKey = "GROK_SESSION_ID"

    public static var supportDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Sigil", isDirectory: true)
    }

    public static var defaultSocket: URL {
        supportDirectory.appendingPathComponent("bridge.sock")
    }

    /// The socket this process should use: the environment wins, so a second
    /// Sigil (or a test) never fights the first one for the same path.
    public static var configuredSocket: URL {
        configuredSocket(environment: ProcessInfo.processInfo.environment)
    }

    public static func configuredSocket(environment: [String: String]) -> URL {
        if let path = environment[socketEnvironmentKey],
            let path = path.nilIfBlank
        {
            return URL(fileURLWithPath: path)
        }
        return defaultSocket
    }

    /// The caller's identity, read from the environment `grok` handed the MCP
    /// server. Verified against grok 1.0.5: both keys arrive on the child.
    public static var peerFromEnvironment: BridgePeer {
        let environment = ProcessInfo.processInfo.environment
        return BridgePeer(
            tabID: environment[tabEnvironmentKey]?.nilIfBlank,
            sessionID: environment[grokSessionEnvironmentKey]?.nilIfBlank
        )
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
