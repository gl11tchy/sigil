import CryptoKit
import Darwin
import Foundation

/// Read-only, version-sensitive adapters for provider-owned JSONL history.
/// Never edits a transcript or guesses that an unrecognized record is a session.
/// Claude records stream with bounded buffers; Codex keeps its prefix/tail reads. Search uses
/// cached names and paths, never synchronous full-transcript reads.
enum NativeSessionScanner {
    static let prefixLimit = 512 * 1024
    static let tailLimit = 128 * 1024
    static let chunkLimit = 64 * 1024

    struct ContentReader: Sendable {
        var read: @Sendable (FileHandle, UInt64, Int) throws -> Data
        var isCancelled: @Sendable () -> Bool = { Task.isCancelled }

        static let disk = ContentReader { handle, offset, count in
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    static var roots: [(CLIProvider, URL)] {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claude =
            env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        let codex =
            env["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        return [
            (.claudeCode, claude.appendingPathComponent("projects")),
            (.codex, codex.appendingPathComponent("sessions")),
        ]
    }

    static func scan(
        provider: CLIProvider, root: URL, cache: [String: SessionCacheEntry], ignoringCache: Bool,
        wasAvailable: Bool = false,
        rootAvailability: SessionScanner.RootAvailability? = nil,
        contentReader: ContentReader = .disk,
        recordDecoder: NativeSessionRecordDecoder = .init(),
        titleIndexCache: CodexTitleIndexCache? = nil
    ) -> SessionScanner.Result {
        let previous = cache.filter { $0.value.session.provider == provider }
        let fm = FileManager()
        let rootPath = root.standardizedFileURL.path
        var coverage = SessionScanner.Coverage()
        let inspection = rootAvailability?.inspect(root) ?? (SessionScanner.rootStatus(root), false)
        switch inspection.0 {
        case .missing:
            let uncertain = wasAvailable || inspection.1 || !previous.isEmpty
            if uncertain { coverage.uncertainRoots.insert(rootPath) }
            return SessionScanner.Result(
                sessions: previous.values.map(\.session), cache: previous,
                loadError: uncertain ? "\(provider.name) history is unavailable. Saved sessions are kept." : nil,
                coverage: coverage)
        case .unreadable, .notDirectory:
            coverage.uncertainRoots.insert(rootPath)
            return SessionScanner.Result(
                sessions: previous.values.map(\.session), cache: previous,
                loadError: "\(provider.name) history is unavailable. Saved sessions are kept.", coverage: coverage)
        case .available:
            coverage.observedRoots.insert(rootPath)
        }
        var readFailed = false
        guard
            let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    readFailed = true
                    return true
                })
        else {
            coverage.uncertainRoots.insert(rootPath)
            return SessionScanner.Result(
                sessions: previous.values.map(\.session), cache: previous,
                loadError: "\(provider.name) history could not be read.", coverage: coverage)
        }
        let names =
            provider == .codex
            ? (titleIndexCache ?? CodexTitleIndexCache()).names(
                at: root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"),
                ignoringCache: ignoringCache, reader: contentReader, decoder: recordDecoder) : [:]
        var next: [String: SessionCacheEntry] = [:]
        var unrecognized = 0
        var unsupportedVersions: Set<String> = []
        for case let file as URL in walker {
            if contentReader.isCancelled() {
                readFailed = true
                break
            }
            if file.lastPathComponent == "subagents" || file.lastPathComponent == "tool-results" {
                walker.skipDescendants()
                continue
            }
            guard file.pathExtension == "jsonl" else { continue }
            let key = file.standardizedFileURL.path
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard let isRegular = values.isRegularFile, let isSymbolicLink = values.isSymbolicLink else {
                    throw CocoaError(.fileReadUnknown)
                }
                guard isRegular, !isSymbolicLink else {
                    unrecognized += 1
                    if let old = previous[key] { next[key] = old }
                    continue
                }
                let attributes = try fm.attributesOfItem(atPath: file.path)
                guard let modified = attributes[.modificationDate] as? Date,
                    let size = attributes[.size] as? NSNumber,
                    let inode = attributes[.systemFileNumber] as? NSNumber,
                    let device = attributes[.systemNumber] as? NSNumber
                else { throw CocoaError(.fileReadUnknown) }
                let changed = try file.resourceValues(forKeys: [.attributeModificationDateKey])
                    .attributeModificationDate
                if !ignoringCache, let old = previous[key], old.modificationDate == modified,
                    old.size == size.intValue, old.inode == inode.uint64Value,
                    old.device == device.uint64Value, old.changeDate == changed
                {
                    var cached = old
                    cached.session = named(old.session, names: names, fallback: old.nativeSummary)
                    next[key] = cached
                    if old.claudeScan?.incomplete == true { unrecognized += 1 }
                    continue
                }
                let claude: ClaudeRead?
                let parsed: ParseResult
                if provider == .claudeCode {
                    let read = try readClaude(
                        file, size: size.uint64Value, inode: inode.uint64Value, device: device.uint64Value,
                        modified: modified, cached: ignoringCache ? nil : previous[key], reader: contentReader,
                        decoder: recordDecoder)
                    claude = read
                    parsed = read.result
                } else {
                    claude = nil
                    let data = try boundedContents(file, size: size.uint64Value, reader: contentReader)
                    parsed = parseResult(
                        provider: provider, data: data, file: file, modified: modified, decoder: recordDecoder)
                }
                let session: GrokSession
                switch parsed {
                case .session(let recognized):
                    session = recognized
                case .unsupportedVersion(let version):
                    unsupportedVersions.insert(version)
                    unrecognized += 1
                    if let old = previous[key] { next[key] = old }
                    continue
                case .unrecognized:
                    unrecognized += 1
                    // Format uncertainty protects this file, not every missing file in the root.
                    if let old = previous[key] { next[key] = old }
                    continue
                }
                if claude?.state.incomplete == true { unrecognized += 1 }
                next[key] = SessionCacheEntry(
                    modificationDate: modified, size: size.intValue,
                    inode: inode.uint64Value, device: device.uint64Value, changeDate: changed,
                    contents: Data(), session: named(session, names: names), claudeScan: claude?.state,
                    nativeSummary: provider == .codex ? session.summary : nil)
            } catch {
                readFailed = true
                if let old = previous[key] { next[key] = old }
            }
        }
        // Inaccessible subdirectories must not make known conversations disappear.
        if readFailed {
            coverage.uncertainRoots.insert(rootPath)
            for (key, old) in previous where next[key] == nil { next[key] = old }
        }
        if unrecognized > 0 {
            let versions = unsupportedVersions.sorted().prefix(3).joined(separator: ", ")
            let detail = versions.isEmpty ? "" : " Unsupported versions: \(versions)."
            coverage.notices[rootPath] =
                "\(provider.name) history: \(unrecognized) file(s) are incomplete or unsupported. Saved conversations are kept."
                + detail
        }
        return SessionScanner.Result(
            sessions: next.values.map(\.session).sorted(by: SessionScanner.isNewer), cache: next,
            loadError: readFailed ? "Some \(provider.name) history could not be read. Saved sessions are kept." : nil,
            coverage: coverage)
    }

    /// Only bounded display fields survive a scan; transcript messages are not retained.
    struct ClaudeMetadata: Sendable, Equatable {
        var nativeID: String?
        var cwd: String?
        var fallback = ""
        var firstPrompt = ""
        /// nil means no rename; an empty string is an explicit reset to the first prompt.
        var explicitTitle: String?
        var model: String?
        var created: Date?
        var isSubagent = false
        var hasObservedMessages = false
        var unsupportedVersion: String?
        var ambiguous = false

        @discardableResult
        mutating func consume(_ line: Data, decoder: NativeSessionRecordDecoder = .init()) -> Bool {
            guard
                decoder.mayChangeRow(
                    line, provider: .claudeCode, needsPrompt: firstPrompt.isEmpty,
                    needsContent: !hasObservedMessages, needsSummary: fallback.isEmpty)
            else { return true }
            guard let object = decoder.object(line),
                let type = object["type"] as? String
            else { return false }
            if let version = object["version"] as? String, !version.hasPrefix("2."), CLIVersion(version) != nil {
                unsupportedVersion = String(version.prefix(64))
            }
            if let id = object["sessionId"] as? String, UUID(uuidString: id) != nil,
                let path = object["cwd"] as? String, path.hasPrefix("/"),
                let version = object["version"] as? String, version.hasPrefix("2.")
            {
                if let nativeID, nativeID != id { ambiguous = true }
                if let cwd, cwd != path { ambiguous = true }
                nativeID = id
                cwd = path
                created = created ?? SessionTimestamp.parse(object["timestamp"] as? String)
                isSubagent = isSubagent || object["isSidechain"] as? Bool == true
            }
            if ["user", "assistant"].contains(type), object["isMeta"] as? Bool != true,
                let message = object["message"] as? [String: Any]
            {
                if let text = message["content"] as? String {
                    hasObservedMessages = hasObservedMessages || !text.isEmpty
                } else if let blocks = message["content"] as? [[String: Any]] {
                    hasObservedMessages = hasObservedMessages || !blocks.isEmpty
                }
            }
            if type == "custom-title", let title = object["customTitle"] as? String {
                explicitTitle = displayTitle(title)
            } else if type == "summary", fallback.isEmpty, let summary = object["summary"] as? String {
                fallback = displayTitle(summary)
            } else if type == "user", firstPrompt.isEmpty, object["isMeta"] as? Bool != true,
                let message = object["message"] as? [String: Any]
            {
                let blocks = message["content"] as? [[String: Any]] ?? []
                let text =
                    message["content"] as? String ?? blocks.compactMap { block -> String? in
                        guard block["type"] as? String == "text" else { return nil }
                        return block["text"] as? String
                    }.first ?? ""
                if !text.hasPrefix("<") {
                    firstPrompt = displayTitle(text)
                    if fallback.isEmpty {
                        fallback = firstPrompt
                    }
                }
            }
            if type == "assistant", let message = object["message"] as? [String: Any],
                let model = message["model"] as? String
            {
                self.model = model
            }
            return true
        }

        func result(file: URL, modified: Date, fallbackCreated: Date) -> ParseResult {
            guard !ambiguous, let nativeID, let cwd, !cwd.contains("\0") else {
                return ambiguous
                    ? .unrecognized : unsupportedVersion.map(ParseResult.unsupportedVersion) ?? .unrecognized
            }
            let title = explicitTitle == "" ? (firstPrompt.isEmpty ? fallback : firstPrompt) : explicitTitle ?? fallback
            return .session(
                GrokSession(
                    id: nativeID, cwd: cwd, summary: title, createdAt: created ?? fallbackCreated,
                    updatedAt: modified, messageCount: 0, modelID: model, agentName: nil, reasoningEffort: nil,
                    kind: isSubagent ? "subagent" : nil, directory: file, provider: .claudeCode,
                    hasObservedMessages: hasObservedMessages))
        }

        private func displayTitle(_ text: String) -> String {
            String(text.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        }
    }

    struct FileSnapshot: Sendable, Equatable, Codable {
        var inode: UInt64
        var device: Int32
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanos: Int
        var changedSeconds: Int
        var changedNanos: Int
        var bornSeconds: Int
        var bornNanos: Int

        init(_ info: stat) {
            inode = info.st_ino
            device = info.st_dev
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanos = info.st_ctimespec.tv_nsec
            bornSeconds = info.st_birthtimespec.tv_sec
            bornNanos = info.st_birthtimespec.tv_nsec
        }

        func isSameFile(as other: FileSnapshot) -> Bool {
            inode == other.inode && device == other.device
                && bornSeconds == other.bornSeconds && bornNanos == other.bornNanos
        }
    }

    struct ClaudeScanState: Sendable, Equatable {
        var identity: FileSnapshot
        var fallbackCreated: Date
        var metadata = ClaudeMetadata()
        /// Physical EOF already read, including any carried partial record.
        var offset: UInt64 = 0
        var remainder = Data()
        var discardingOversized = false
        var skippedOversized = false
        var incomplete = false
        /// Fingerprint of every byte through offset; validation streams those bytes again.
        var continuityDigest: [UInt8] = []
    }

    private struct ClaudeRead {
        var state: ClaudeScanState
        var result: ParseResult
    }

    private static func readClaude(
        _ file: URL, size: UInt64, inode: UInt64, device: UInt64, modified: Date,
        cached: SessionCacheEntry?, reader: ContentReader, decoder: NativeSessionRecordDecoder
    ) throws -> ClaudeRead {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        func snapshot() throws -> FileSnapshot {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            return FileSnapshot(info)
        }
        let before = try snapshot()
        guard before.size >= 0, UInt64(before.size) == size, before.inode == inode,
            UInt64(bitPattern: Int64(before.device)) == device
        else { throw CocoaError(.fileReadUnknown) }
        var state = ClaudeScanState(identity: before, fallbackCreated: modified)
        var hasher = SHA256()
        if let cached, let old = cached.claudeScan, before.isSameFile(as: old.identity),
            old.offset == UInt64(cached.size), size > old.offset,
            let validated = try validatedPrefix(old, handle: handle, reader: reader)
        {
            state = old
            hasher = validated
        }
        while state.offset < size {
            try checkCancellation(reader)
            let requested = min(chunkLimit, Int(size - state.offset))
            let chunk = try reader.read(handle, state.offset, requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw CocoaError(.fileReadUnknown) }
            hasher.update(data: chunk)
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                try checkCancellation(reader)
                let newline = NativeSessionRecordDecoder.nextNewline(in: chunk, from: cursor)
                let end = newline ?? chunk.endIndex
                if !state.discardingOversized {
                    if state.remainder.count + chunk.distance(from: cursor, to: end) > prefixLimit {
                        state.remainder = Data()
                        state.discardingOversized = true
                        state.skippedOversized = true
                    } else {
                        state.remainder.append(chunk[cursor..<end])
                    }
                }
                if let newline {
                    if !state.discardingOversized { state.metadata.consume(state.remainder, decoder: decoder) }
                    state.remainder = Data()
                    state.discardingOversized = false
                    cursor = chunk.index(after: newline)
                } else {
                    cursor = end
                }
            }
            state.offset += UInt64(chunk.count)
        }
        try checkCancellation(reader)
        var pathInfo = stat()
        guard try snapshot() == before, stat(file.path, &pathInfo) == 0, FileSnapshot(pathInfo) == before else {
            throw CocoaError(.fileReadUnknown)
        }
        state.identity = before
        state.continuityDigest = Array(hasher.finalize())
        // Legacy files may end with a complete JSON object but no newline. Project it
        // without committing it, so an appended delimiter/JSON/UTF-8 fragment is reparsed once.
        var projected = state.metadata
        var finalDecoder = decoder
        // A partial final record must still validate even when it cannot change
        // display fields, because its validity determines the incomplete notice.
        finalDecoder.selectsCandidates = false
        let unfinished = !state.remainder.isEmpty && !projected.consume(state.remainder, decoder: finalDecoder)
        state.incomplete = unfinished || state.skippedOversized || state.discardingOversized
        return ClaudeRead(
            state: state,
            result: projected.result(file: file, modified: modified, fallbackCreated: state.fallbackCreated))
    }

    /// Changed-file validation deliberately rereads the entire old prefix in bounded
    /// chunks. Metadata parsing resumes only when its full fingerprint still matches.
    private static func validatedPrefix(
        _ state: ClaudeScanState, handle: FileHandle, reader: ContentReader
    ) throws -> SHA256? {
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < state.offset {
            try checkCancellation(reader)
            let requested = min(chunkLimit, Int(state.offset - offset))
            let chunk = try reader.read(handle, offset, requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw CocoaError(.fileReadUnknown) }
            hasher.update(data: chunk)
            offset += UInt64(chunk.count)
        }
        try checkCancellation(reader)
        return Array(hasher.finalize()) == state.continuityDigest ? hasher : nil
    }

    private static func checkCancellation(_ reader: ContentReader) throws {
        if reader.isCancelled() { throw CancellationError() }
    }

    private static func boundedContents(_ file: URL, size: UInt64, reader: ContentReader) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0, UInt64(before.st_size) == size
        else { throw CocoaError(.fileReadUnknown) }
        let data = try boundedContents(handle, size: size, reader: reader)
        var after = stat()
        guard lstat(file.path, &after) == 0, after.st_mode & S_IFMT == S_IFREG,
            FileSnapshot(before) == FileSnapshot(after)
        else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    static func boundedContents(_ handle: FileHandle, size: UInt64, reader: ContentReader = .disk) throws -> Data {
        try checkCancellation(reader)
        var data = try reader.read(handle, 0, prefixLimit)
        if size > UInt64(prefixLimit) {
            // Discard the partial prefix record rather than concatenate unrelated JSON.
            if let newline = data.lastIndex(of: 0x0A) { data = Data(data[...newline]) } else { data = Data() }
            let offset = max(UInt64(prefixLimit), size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0)
            try checkCancellation(reader)
            let tail = try reader.read(handle, offset, tailLimit)
            if let newline = tail.firstIndex(of: 0x0A) { data.append(tail.suffix(from: tail.index(after: newline))) }
        }
        return data
    }

    static func parse(provider: CLIProvider, data: Data, file: URL, modified: Date) -> GrokSession? {
        if case .session(let session) = parseResult(provider: provider, data: data, file: file, modified: modified) {
            return session
        }
        return nil
    }

    enum ParseResult {
        case session(GrokSession)
        case unsupportedVersion(String)
        case unrecognized
    }

    static func parseResult(
        provider: CLIProvider, data: Data, file: URL, modified: Date,
        decoder: NativeSessionRecordDecoder = .init()
    ) -> ParseResult {
        guard provider == .claudeCode || provider == .codex else { return .unrecognized }
        if provider == .claudeCode {
            var metadata = ClaudeMetadata()
            for line in NativeSessionRecordDecoder.records(in: data, limit: prefixLimit) {
                metadata.consume(line, decoder: decoder)
            }
            return metadata.result(file: file, modified: modified, fallbackCreated: modified)
        }
        var nativeID: String?
        var cwd: String?
        var title = ""
        var model: String?
        var created: Date?
        var supported = false
        var isSubagent = false
        var hasObservedMessages = false
        for record in NativeSessionRecordDecoder.records(in: data, limit: prefixLimit) {
            guard
                decoder.mayChangeRow(
                    record, provider: .codex, needsPrompt: title.isEmpty, needsContent: !hasObservedMessages)
            else { continue }
            guard let object = decoder.object(record),
                let type = object["type"] as? String
            else { continue }
            if provider == .codex {
                guard let payload = object["payload"] as? [String: Any] else {
                    if type == "session_meta" { return .unrecognized }
                    continue
                }
                if type == "event_msg", payload["type"] as? String == "user_message" {
                    hasObservedMessages =
                        hasObservedMessages || !(payload["message"] as? String ?? "").isEmpty
                        || !(payload["images"] as? [Any] ?? []).isEmpty
                }
                if type == "response_item", payload["type"] as? String == "message",
                    let role = payload["role"] as? String, ["user", "assistant"].contains(role),
                    let blocks = payload["content"] as? [[String: Any]]
                {
                    hasObservedMessages =
                        hasObservedMessages
                        || blocks.contains { block in
                            if block["type"] as? String == "input_image" { return true }
                            guard let text = block["text"] as? String, !text.isEmpty else { return false }
                            return role == "assistant"
                                || (!text.hasPrefix("<environment_context>") && !text.hasPrefix("# AGENTS.md"))
                        }
                }
                if type == "session_meta" {
                    guard let id = payload["id"] as? String, UUID(uuidString: id) != nil,
                        let path = payload["cwd"] as? String, path.hasPrefix("/"),
                        let version = payload["cli_version"] as? String
                    else { return .unrecognized }
                    guard supportedCodexVersion(version) else {
                        return CLIVersion(version) == nil
                            ? .unrecognized : .unsupportedVersion(String(version.prefix(64)))
                    }
                    if let nativeID, nativeID != id { return .unrecognized }
                    if let cwd, cwd != path { return .unrecognized }
                    nativeID = id
                    cwd = path
                    // Resuming appends metadata for the existing conversation, not a new creation.
                    if !supported {
                        created = SessionTimestamp.parse(
                            payload["timestamp"] as? String ?? object["timestamp"] as? String)
                    }
                    supported = true
                    isSubagent = payload["source"] is [String: Any] || payload["parent_thread_id"] as? String != nil
                } else if type == "turn_context" {
                    model = payload["model"] as? String ?? model
                } else if type == "event_msg", payload["type"] as? String == "user_message", title.isEmpty {
                    title = payload["message"] as? String ?? ""
                } else if type == "response_item", payload["type"] as? String == "message",
                    payload["role"] as? String == "user", title.isEmpty,
                    let content = payload["content"] as? [[String: Any]]
                {
                    title =
                        content.compactMap { part -> String? in
                            guard part["type"] as? String == "input_text", let text = part["text"] as? String,
                                !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md")
                            else { return nil }
                            return text
                        }.first ?? ""
                }
            }
        }
        guard supported, let nativeID, let cwd, !cwd.contains("\0") else {
            return .unrecognized
        }
        return .session(
            GrokSession(
                id: nativeID, cwd: cwd, summary: String(title.prefix(240)).replacingOccurrences(of: "\n", with: " "),
                createdAt: created ?? modified, updatedAt: modified, messageCount: 0,
                modelID: model, agentName: nil, reasoningEffort: nil, kind: isSubagent ? "subagent" : nil,
                directory: file, provider: provider, hasObservedMessages: hasObservedMessages))
    }

    private static func named(
        _ session: GrokSession, names: [String: String], fallback: String? = nil
    ) -> GrokSession {
        let name = names[session.nativeSessionID] ?? fallback ?? session.summary
        guard name != session.summary else { return session }
        return GrokSession(
            id: session.nativeSessionID, cwd: session.cwd, summary: name,
            createdAt: session.createdAt, updatedAt: session.updatedAt, messageCount: session.messageCount,
            modelID: session.modelID, agentName: session.agentName, reasoningEffort: session.reasoningEffort,
            kind: session.kind, directory: session.directory, provider: session.provider,
            hasObservedMessages: session.hasObservedMessages, isHistoryValidated: session.isHistoryValidated)
    }

    private static func supportedCodexVersion(_ version: String) -> Bool {
        // Minor updates can keep the supported envelope. The metadata's shape,
        // UUID and absolute cwd still have to validate; a new major stays closed.
        guard let parsed = CLIVersion(version) else { return false }
        return parsed.major == 0 && parsed.minor >= 1
    }
}
