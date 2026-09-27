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
    private var remainder = Data()
    private var discardingLine = false
    private var validatedCodexIdentity = false
    private var activeTurnID: String?
    private var seenEvents = Set<String>()
    private var seenOrder: [String] = []

    public init(url: URL, provider: CLIProvider, sessionID: String, notBefore: Date = Date()) {
        self.url = url
        self.provider = provider
        self.sessionID = sessionID
        self.notBefore = Date(timeIntervalSince1970: floor(notBefore.timeIntervalSince1970 * 1000) / 1000)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        offset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        if provider == .codex, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: NativeSessionScanner.prefixLimit) {
                validatedCodexIdentity =
                    NativeSessionScanner.parse(
                        provider: .codex, data: data, file: url, modified: Date())?.nativeSessionID == sessionID
            }
        }
    }

    public mutating func poll() -> [SessionLifecycleState] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value,
            let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return [] }
        if (inode != nil && inode != currentInode) || size < offset {
            offset = size
            inode = currentInode
            remainder.removeAll()
            activeTurnID = nil
            discardingLine = false
            return [.unknown]
        }
        inode = currentInode
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: 256 * 1024) ?? Data()
            offset += UInt64(data.count)
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

    private mutating func parse(_ data: Data) -> SessionLifecycleState? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestamp = eventTimestamp(object), timestamp >= notBefore
        else { return nil }
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
