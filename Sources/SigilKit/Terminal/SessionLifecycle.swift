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
    private var device: UInt32?
    private var trailingAnchor = Data()
    private var remainder = Data()
    private var discardingLine = false
    private var validatedCodexIdentity = false
    private var activeTurnID: String?
    private var hasCurrentReadEvidence = false
    private var workRevision: UInt64 = 0
    private var seenEvents = Set<String>()
    private var seenOrder: [String] = []
    private var transcript: CodexSessionBinding.Transcript?
    private var validatedPrefix: Data?
    private var initialMetadataPending = false
    private var catchUpBoundary: UInt64?
    private var catchUpAnchor = Data()
    private var catchUpState: SessionLifecycleState?

    /// Catch-up restores state, not historical completion notifications.
    public var isCatchingUp: Bool { catchUpBoundary != nil }

    /// Current readable-file evidence plus a session/turn-validated work event.
    /// Nominal provider support, a path or an empty/missing journal is insufficient.
    /// Quiet successful polls preserve the revision rather than invent progress.
    public var validatedWorkRevision: UInt64? {
        hasCurrentReadEvidence && canObserve && !isCatchingUp && activeTurnID != nil ? workRevision : nil
    }

    /// A journal path alone does not establish an observable provider lifecycle.
    /// Grok may create its journal later; Codex must already have validated metadata.
    public var canObserve: Bool {
        provider == .grokBuild || (provider == .codex && validatedCodexIdentity)
    }

    public init(
        url: URL, provider: CLIProvider, sessionID: String, notBefore: Date = Date(),
        readFromBeginning: Bool = false
    ) {
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
                device = identity.device
                trailingAnchor = anchor
                if readFromBeginning, provider == .codex {
                    offset = 0
                    trailingAnchor = Data()
                    catchUpBoundary = identity.size
                    catchUpAnchor = anchor
                    initialMetadataPending = true
                }
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

    /// Live attachment uses the exact validated descriptor identity and a
    /// process lease. Explicit old-history links retain tail-only behavior.
    public init(transcript: CodexSessionBinding.Transcript, readFromBeginning: Bool = true) {
        self.init(
            url: URL(fileURLWithPath: transcript.fileIdentity.path), provider: .codex,
            sessionID: transcript.session.nativeSessionID, notBefore: transcript.processStartedAt ?? Date(),
            readFromBeginning: readFromBeginning && transcript.canReadFromBeginning)
        self.transcript = transcript
        guard let handle = openHandle() else {
            validatedCodexIdentity = false
            return
        }
        defer { try? handle.close() }
        guard let current = Self.identity(handle), matches(current, transcript: transcript),
            current.inode == inode, current.device == device,
            let prefix = try? handle.read(upToCount: NativeSessionScanner.prefixLimit),
            let parsed = NativeSessionScanner.parse(provider: .codex, data: prefix, file: url, modified: Date()),
            parsed.nativeSessionID == sessionID,
            GrokPaths.canonicalPath(parsed.cwd) == GrokPaths.canonicalPath(transcript.session.cwd)
        else {
            validatedCodexIdentity = false
            return
        }
        validatedPrefix = prefix
    }

    public mutating func poll() -> [SessionLifecycleState] {
        hasCurrentReadEvidence = false
        guard canObserve else { return [] }
        let before = transcript?.lease()
        if transcript != nil, before == nil { return invalidateObservation() }
        let result = pollRecords()
        if let transcript, transcript.lease() != before { return invalidateObservation() }
        if transcript != nil, !transcriptFileIsUnchanged() { return invalidateObservation() }
        return result
    }

    /// A stable held descriptor is insufficient if its pathname was replaced
    /// while reading. Recheck the exact file and bounded read evidence before
    /// returning events; ordinary appends remain valid.
    private func transcriptFileIsUnchanged() -> Bool {
        guard let transcript, let handle = openHandle() else { return false }
        defer { try? handle.close() }
        guard let current = Self.identity(handle), matches(current, transcript: transcript), current.size >= offset,
            let validatedPrefix,
            (try? handle.read(upToCount: validatedPrefix.count)) == validatedPrefix,
            (try? Self.anchor(handle, behind: offset)) == trailingAnchor
        else { return false }
        return true
    }

    private mutating func pollRecords() -> [SessionLifecycleState] {
        guard let handle = openHandle() else { return transcript == nil ? [] : invalidateObservation() }
        defer { try? handle.close() }
        // Inspect the opened file, not path metadata that could race replacement.
        guard let current = Self.identity(handle) else {
            return transcript == nil ? [] : invalidateObservation()
        }
        do {
            if let transcript {
                guard matches(current, transcript: transcript), let validatedPrefix,
                    try handle.read(upToCount: validatedPrefix.count) == validatedPrefix
                else { return invalidateObservation() }
            }
            if let boundary = catchUpBoundary {
                guard current.size >= boundary, try Self.anchor(handle, behind: boundary) == catchUpAnchor
                else { return invalidateObservation() }
            }
            let replaced = inode != nil && (inode != current.inode || device != current.device)
            var rewritten = current.size < offset
            if !rewritten { rewritten = try Self.anchor(handle, behind: offset) != trailingAnchor }
            if replaced || rewritten {
                offset = current.size
                inode = current.inode
                device = current.device
                trailingAnchor = try Self.anchor(handle, behind: offset)
                remainder.removeAll()
                activeTurnID = nil
                discardingLine = false
                validatedCodexIdentity = false
                catchUpBoundary = nil
                return [.unknown]
            }
            inode = current.inode
            device = current.device
            hasCurrentReadEvidence = true
            guard current.size > offset else { return [] }
            try handle.seek(toOffset: offset)
            let limit = catchUpBoundary.map { Int(min($0 - offset, 256 * 1024)) } ?? (256 * 1024)
            let data = try handle.read(upToCount: limit) ?? Data()
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
                if let event = parse(line) {
                    if catchUpBoundary != nil { catchUpState = event } else { events.append(event) }
                }
            }
            if remainder.count > 1_048_576 {
                remainder.removeAll()
                discardingLine = true
            }
            if let boundary = catchUpBoundary, offset >= boundary || !canObserve {
                catchUpBoundary = nil
                return catchUpState.map { [$0] } ?? []
            }
            return events
        } catch {
            hasCurrentReadEvidence = false
            return transcript == nil ? [] : invalidateObservation()
        }
    }

    private mutating func invalidateObservation() -> [SessionLifecycleState] {
        hasCurrentReadEvidence = false
        validatedCodexIdentity = false
        activeTurnID = nil
        catchUpBoundary = nil
        return [.unknown]
    }

    private func openHandle() -> FileHandle? {
        guard transcript != nil else { return try? FileHandle(forReadingFrom: url) }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        return descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
    }

    private func matches(
        _ identity: (size: UInt64, inode: UInt64, device: UInt32), transcript: CodexSessionBinding.Transcript
    ) -> Bool {
        identity.inode == transcript.fileIdentity.inode && identity.device == transcript.fileIdentity.device
    }

    private static func identity(_ handle: FileHandle) -> (size: UInt64, inode: UInt64, device: UInt32)? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            return nil
        }
        return (UInt64(info.st_size), info.st_ino, UInt32(bitPattern: info.st_dev))
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
            if initialMetadataPending {
                initialMetadataPending = false
                guard
                    let parsed = NativeSessionScanner.parse(
                        provider: .codex, data: data + Data([0x0A]), file: url, modified: Date()),
                    parsed.nativeSessionID == sessionID,
                    transcript.map({ GrokPaths.canonicalPath($0.session.cwd) == GrokPaths.canonicalPath(parsed.cwd) })
                        ?? true
                else {
                    validatedCodexIdentity = false
                    return .unknown
                }
                return nil
            }
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
                workRevision += 1
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
            guard validatedCodexIdentity, !initialMetadataPending else { return nil }
            guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
                let type = payload["type"] as? String, let turnID = payload["turn_id"] as? String,
                !turnID.isEmpty
            else { return nil }
            // The file was selected by validated session_meta identity, not by cwd/time.
            guard remember("\(turnID):\(type)") else { return nil }
            if type == "task_started" {
                activeTurnID = turnID
                workRevision += 1
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
