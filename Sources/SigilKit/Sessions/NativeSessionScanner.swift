import Foundation

/// Read-only, version-sensitive adapters for provider-owned JSONL history.
/// Never edits a transcript or guesses that an unrecognized record is a session.
/// Prefix/tail reads bound memory independently of transcript size. Search uses
/// cached names and paths, never synchronous full-transcript reads.
enum NativeSessionScanner {
    static let prefixLimit = 512 * 1024
    static let tailLimit = 128 * 1024

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
        provider: CLIProvider, root: URL, cache: [String: SessionCacheEntry], ignoringCache: Bool
    ) -> SessionScanner.Result {
        let previous = cache.filter { $0.value.session.provider == provider }
        let fm = FileManager()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return SessionScanner.Result(
                sessions: previous.values.map(\.session), cache: previous,
                loadError: previous.isEmpty ? nil : "\(provider.name) history is unavailable. Saved sessions are kept.")
        }
        var failed = false
        guard
            let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    failed = true
                    return true
                })
        else {
            return SessionScanner.Result(
                sessions: previous.values.map(\.session), cache: previous,
                loadError: "\(provider.name) history could not be read.")
        }
        let names =
            provider == .codex
            ? codexNames(at: root.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")) : [:]
        var next: [String: SessionCacheEntry] = [:]
        for case let file as URL in walker {
            if file.lastPathComponent == "subagents" || file.lastPathComponent == "tool-results" {
                walker.skipDescendants()
                continue
            }
            guard file.pathExtension == "jsonl" else { continue }
            let key = file.standardizedFileURL.path
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
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
                    cached.session = named(old.session, names: names)
                    next[key] = cached
                    continue
                }
                let data = try boundedContents(file, size: size.uint64Value)
                guard let session = parse(provider: provider, data: data, file: file, modified: modified) else {
                    // Unrecognized files are not sessions; retain a previously recognized record.
                    if let old = previous[key] { next[key] = old }
                    failed = true
                    continue
                }
                next[key] = SessionCacheEntry(
                    modificationDate: modified, size: size.intValue,
                    inode: inode.uint64Value, device: device.uint64Value, changeDate: changed,
                    contents: Data(), session: named(session, names: names))
            } catch {
                failed = true
                if let old = previous[key] { next[key] = old }
            }
        }
        // Inaccessible subdirectories must not make known conversations disappear.
        if failed { for (key, old) in previous where next[key] == nil { next[key] = old } }
        return SessionScanner.Result(
            sessions: next.values.map(\.session).sorted(by: SessionScanner.isNewer), cache: next,
            loadError: failed ? "Some \(provider.name) history could not be read. Saved sessions are kept." : nil)
    }

    private static func boundedContents(_ file: URL, size: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: prefixLimit) ?? Data()
        if size > UInt64(prefixLimit) {
            // Discard the partial prefix record rather than concatenate unrelated JSON.
            if let newline = data.lastIndex(of: 0x0A) { data = Data(data[...newline]) } else { data = Data() }
            let offset = max(UInt64(prefixLimit), size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0)
            try handle.seek(toOffset: offset)
            let tail = try handle.read(upToCount: tailLimit) ?? Data()
            if let newline = tail.firstIndex(of: 0x0A) { data.append(tail.suffix(from: tail.index(after: newline))) }
        }
        return data
    }

    static func parse(provider: CLIProvider, data: Data, file: URL, modified: Date) -> GrokSession? {
        guard provider == .claudeCode || provider == .codex else { return nil }
        var nativeID: String?
        var cwd: String?
        var title = ""
        var model: String?
        var created: Date?
        var supported = false
        var isSubagent = false
        var hasObservedMessages = false
        for line in data.split(separator: 0x0A) where line.count <= prefixLimit {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let type = object["type"] as? String
            else { continue }
            if provider == .codex {
                guard let payload = object["payload"] as? [String: Any] else {
                    if type == "session_meta" { return nil }
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
                        let version = payload["cli_version"] as? String, supportedCodexVersion(version)
                    else { return nil }
                    if let nativeID, nativeID != id { return nil }
                    if let cwd, cwd != path { return nil }
                    nativeID = id
                    cwd = path
                    supported = true
                    created = SessionTimestamp.parse(payload["timestamp"] as? String ?? object["timestamp"] as? String)
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
            } else {
                if ["user", "assistant"].contains(type), object["isMeta"] as? Bool != true,
                    let message = object["message"] as? [String: Any]
                {
                    if let text = message["content"] as? String {
                        hasObservedMessages = hasObservedMessages || !text.isEmpty
                    } else if let blocks = message["content"] as? [[String: Any]] {
                        hasObservedMessages = hasObservedMessages || !blocks.isEmpty
                    }
                }
                if let id = object["sessionId"] as? String, UUID(uuidString: id) != nil,
                    let path = object["cwd"] as? String, path.hasPrefix("/"),
                    let version = object["version"] as? String, version.hasPrefix("2.")
                {
                    if let nativeID, nativeID != id { return nil }
                    if let cwd, cwd != path { return nil }
                    nativeID = id
                    cwd = path
                    supported = true
                    created = created ?? SessionTimestamp.parse(object["timestamp"] as? String)
                    isSubagent = isSubagent || object["isSidechain"] as? Bool == true
                }
                if type == "custom-title", let custom = object["customTitle"] as? String {
                    title = custom
                } else if type == "summary", title.isEmpty {
                    title = object["summary"] as? String ?? ""
                } else if type == "user", title.isEmpty, object["isMeta"] as? Bool != true,
                    let message = object["message"] as? [String: Any]
                {
                    let blocks = message["content"] as? [[String: Any]] ?? []
                    let text =
                        message["content"] as? String ?? blocks.compactMap { block -> String? in
                            guard block["type"] as? String == "text" else { return nil }
                            return block["text"] as? String
                        }.first ?? ""
                    if !text.hasPrefix("<") { title = text }
                }
                if type == "assistant", let message = object["message"] as? [String: Any] {
                    model = message["model"] as? String ?? model
                }
            }
        }
        guard supported, let nativeID, let cwd, !cwd.contains("\0") else { return nil }
        return GrokSession(
            id: nativeID, cwd: cwd, summary: String(title.prefix(240)).replacingOccurrences(of: "\n", with: " "),
            createdAt: created ?? modified, updatedAt: modified, messageCount: 0,
            modelID: model, agentName: nil, reasoningEffort: nil, kind: isSubagent ? "subagent" : nil,
            directory: file, provider: provider, hasObservedMessages: hasObservedMessages)
    }

    /// Codex's append-only name index is also version-sensitive. It only supplies
    /// display names for sessions whose transcript identity already validated.
    private static func codexNames(at file: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        let limit: UInt64 = 2 * 1024 * 1024
        guard let size = try? handle.seekToEnd() else { return [:] }
        let offset = size > limit ? size - limit : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(limit)) else { return [:] }
        var lines = data.split(separator: 0x0A)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        var names: [String: String] = [:]
        for line in lines where line.count < 16_384 {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = row["id"] as? String, UUID(uuidString: id) != nil,
                let title = row["thread_name"] as? String, !title.isEmpty
            else { continue }
            names[id] = String(title.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        }
        return names
    }

    private static func named(_ session: GrokSession, names: [String: String]) -> GrokSession {
        guard let name = names[session.nativeSessionID], name != session.summary else { return session }
        return GrokSession(
            id: session.nativeSessionID, cwd: session.cwd, summary: name,
            createdAt: session.createdAt, updatedAt: session.updatedAt, messageCount: session.messageCount,
            modelID: session.modelID, agentName: session.agentName, reasoningEffort: session.reasoningEffort,
            kind: session.kind, directory: session.directory, provider: session.provider,
            hasObservedMessages: session.hasObservedMessages)
    }

    private static func supportedCodexVersion(_ version: String) -> Bool {
        // Minor updates can keep the supported envelope. The metadata's shape,
        // UUID and absolute cwd still have to validate; a new major stays closed.
        guard let parsed = CLIVersion(version) else { return false }
        return parsed.major == 0
    }
}
