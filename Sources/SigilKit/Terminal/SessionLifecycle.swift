import Darwin
import Foundation

/// Only provider-confirmed successful completion enters idle. A live process,
/// title, or quiet terminal cannot prove that a turn finished.
public enum SessionLifecycleState: Equatable, Sendable {
    case starting, working, waitingForApproval, idle, interrupted, failed, disconnected, unknown
    case exited(code: Int32?)

    public var endedInFailure: Bool {
        if case .failed = self { return true }
        if case .exited(let code?) = self { return code != 0 }
        return false
    }

    public var statusName: String {
        switch self {
        case .starting: "starting"
        case .working: "working"
        case .waitingForApproval: "waitingForApproval"
        case .idle: "idle"
        case .interrupted: "interrupted"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .unknown: "unknown"
        case .exited(let code): code.map { $0 == 0 ? "exited" : "failed" } ?? "exited"
        }
    }
}

/// A bounded reader of the actual owned conversation journal. File replacement,
/// truncation, malformed records, or missing native turn identity fail closed.
/// Parsing is isolated because provider journal formats are not stable APIs.
public struct ProviderLifecycleJournal: Sendable {
    private let url: URL
    private let provider: CLIProvider
    private let sessionID: String
    private let notBefore: Date
    private var offset: UInt64
    private var inode: UInt64?
    private var trailingAnchor = Data()
    private var remainder = Data()
    private var discardingLine = false
    private var validatedCodexIdentity = false
    private var activeTurnID: String?
    private var seenEvents = Set<String>()
    private var seenOrder: [String] = []

    /// A journal path alone does not establish an observable provider lifecycle.
    /// Grok may create its journal later; Codex must already have validated metadata.
    public var canObserve: Bool {
        provider == .grokBuild || (provider == .codex && validatedCodexIdentity)
    }

    public init(url: URL, provider: CLIProvider, sessionID: String, notBefore: Date = Date()) {
        self.url = url
        self.provider = provider
        self.sessionID = sessionID
        self.notBefore = Date(timeIntervalSince1970: floor(notBefore.timeIntervalSince1970 * 1000) / 1000)
        offset = 0
        inode = nil
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let identity = Self.identity(handle), let anchor = try? Self.anchor(handle, behind: identity.size) {
                offset = identity.size
                inode = identity.inode
                trailingAnchor = anchor
            }
            if provider == .codex {
                try? handle.seek(toOffset: 0)
                if let data = try? handle.read(upToCount: NativeSessionScanner.prefixLimit) {
                    validatedCodexIdentity =
                        NativeSessionScanner.parse(
                            provider: .codex, data: data, file: url, modified: Date())?.nativeSessionID == sessionID
                }
            }
        }
    }

    public mutating func poll() -> [SessionLifecycleState] {
        guard canObserve else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        // Inspect the opened file, not path metadata that could race replacement.
        guard let current = Self.identity(handle) else { return [] }
        do {
            let replaced = inode != nil && inode != current.inode
            var rewritten = current.size < offset
            if !rewritten { rewritten = try Self.anchor(handle, behind: offset) != trailingAnchor }
            if replaced || rewritten {
                offset = current.size
                inode = current.inode
                trailingAnchor = try Self.anchor(handle, behind: offset)
                remainder.removeAll()
                activeTurnID = nil
                discardingLine = false
                validatedCodexIdentity = false
                return [.unknown]
            }
            inode = current.inode
            guard current.size > offset else { return [] }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            offset += UInt64(data.count)
            trailingAnchor = Data((trailingAnchor + data).suffix(64))
            remainder.append(data)
            var events: [SessionLifecycleState] = []
            while let end = remainder.firstIndex(of: 0x0A) {
                let line = Data(remainder[..<end])
                remainder.removeSubrange(...end)
                if discardingLine {
                    discardingLine = false
                    continue
                }
                guard line.count <= 1_048_576 else { continue }
                if let event = parse(line) { events.append(event) }
            }
            if remainder.count > 1_048_576 {
                remainder.removeAll()
                discardingLine = true
            }
            return events
        } catch { return [] }
    }

    private static func identity(_ handle: FileHandle) -> (size: UInt64, inode: UInt64)? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 else { return nil }
        return (UInt64(info.st_size), info.st_ino)
    }

    /// Detect truncate-and-rewrite even when inode and final size look unchanged.
    /// Checking only the prior boundary keeps each poll bounded independently of history size.
    private static func anchor(_ handle: FileHandle, behind offset: UInt64) throws -> Data {
        let count = Int(min(offset, 64))
        try handle.seek(toOffset: offset - UInt64(count))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    private mutating func parse(_ data: Data) -> SessionLifecycleState? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if provider == .codex, object["type"] as? String == "session_meta" {
            // An appended session header is a new writer/identity boundary, not
            // evidence that the previous owned turn completed.
            validatedCodexIdentity = false
            activeTurnID = nil
            return .unknown
        }
        guard let timestamp = eventTimestamp(object), timestamp >= notBefore else { return nil }
        if provider == .grokBuild {
            guard let params = object["params"] as? [String: Any], params["sessionId"] as? String == sessionID,
                let update = params["update"] as? [String: Any], let type = update["sessionUpdate"] as? String
            else { return nil }
            let meta = params["_meta"] as? [String: Any]
            guard let eventID = meta?["eventId"] as? String, remember(eventID) else { return nil }
            if ["agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"].contains(type),
                let turnID = meta?["promptId"] as? String, !turnID.isEmpty
            {
                activeTurnID = turnID
                return .working
            }
            guard type == "turn_completed", let turnID = update["prompt_id"] as? String,
                turnID == activeTurnID
            else { return nil }
            activeTurnID = nil
            switch update["stop_reason"] as? String {
            case "end_turn": return .idle
            case "cancelled": return .interrupted
            default: return .unknown
            }
        }
        if provider == .codex {
            guard validatedCodexIdentity else { return nil }
            guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
                let type = payload["type"] as? String, let turnID = payload["turn_id"] as? String,
                !turnID.isEmpty
            else { return nil }
            // The file was selected by validated session_meta identity, not by cwd/time.
            guard remember("\(turnID):\(type)") else { return nil }
            if type == "task_started" {
                activeTurnID = turnID
                return .working
            }
            guard turnID == activeTurnID else { return nil }
            switch type {
            case "task_complete":
                activeTurnID = nil
                return .idle
            case "turn_aborted":
                activeTurnID = nil
                return .interrupted
            default: return nil
            }
        }
        return nil
    }

    private func eventTimestamp(_ object: [String: Any]) -> Date? {
        if provider == .grokBuild {
            // Installed Grok 1.0.40 writes integer seconds in timestamp and
            // precise event-generation milliseconds in params._meta. Using the
            // coarse seconds could accept a delayed old event in the same second.
            let params = object["params"] as? [String: Any]
            let meta = params?["_meta"] as? [String: Any]
            if let milliseconds = meta?["agentTimestampMs"] as? NSNumber {
                let number = milliseconds.doubleValue
                guard number.isFinite, number >= 1_000_000_000_000, number < 10_000_000_000_000 else { return nil }
                return Date(timeIntervalSince1970: number / 1000)
            }
        }
        return SessionTimestamp.parse(object["timestamp"] as? String)
    }

    private mutating func remember(_ id: String) -> Bool {
        guard seenEvents.insert(id).inserted else { return false }
        seenOrder.append(id)
        if seenOrder.count > 4096 { seenEvents.remove(seenOrder.removeFirst()) }
        return true
    }
}
