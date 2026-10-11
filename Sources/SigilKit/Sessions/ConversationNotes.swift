import Foundation
import Observation
import os

/// One Markdown scratch pad per verified conversation. Reads are cached; directory
/// events refresh idle notes. Typing stays in memory until the 300ms quiet window.
@MainActor
@Observable
public final class ConversationNotesStore {
    public enum Notice: Equatable, Sendable {
        case conflictPreserved(URL)
        case conflictUnsaved
        case outsideDeletion
        case saveFailed
    }

    public let root: URL
    private struct Entry {
        var text: String
        var baseline: Revision?
        var generation: UInt64 = 0
        var dirty = false
        var writing = false
        // Failed preservation must keep the outside bytes even if disk changes again.
        var outside: [Data] = []
        var preserved: [URL] = []
        var deletedOutside = false
        var notice: Notice?
    }

    private enum Revision: Equatable, Sendable {
        case missing
        case file(data: Data, device: UInt64, inode: UInt64)

        var data: Data? {
            if case .file(let data, _, _) = self { return data }
            return nil
        }
    }

    private struct Pending: Sendable {
        let url: URL
        let generation: UInt64
        let text: String?
        let baseline: Revision?
        let outside: [Data]
        let stamp: Int64
    }

    private struct Completion: Sendable {
        let pending: Pending
        var revision: Revision?
        var outside: [Data] = []
        var preserved: [URL] = []
        var deletedOutside = false
        var failed = false
        var conflict = false
    }

    private var entries: [String: Entry] = [:]
    /// Read by sidebar snapshots; all index/overlay publication is observable.
    public private(set) var searchGeneration: UInt64 = 0
    @ObservationIgnored private var searchReferences: Set<ProviderSessionReference> = []
    @ObservationIgnored private var searchSnapshot: ConversationNotesIndex.Snapshot?
    @ObservationIgnored private var searchCache: [String: ConversationNotesIndex.Cached] = [:]
    @ObservationIgnored private var searchOverlays: [String: String] = [:]
    @ObservationIgnored private var searchRequest: UInt64 = 0
    @ObservationIgnored private var searchBusy = false
    @ObservationIgnored private var searchPending = false
    @ObservationIgnored private var searchRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var searchCancellation: OSAllocatedUnfairLock<Bool>?
    @ObservationIgnored private let searchReader: ConversationNotesIndex.Reader
    @ObservationIgnored private let searchQueue = DispatchQueue(label: "com.gl11tchy.sigil.notes-search", qos: .utility)
    @ObservationIgnored private(set) var searchScanCount = 0
    @ObservationIgnored private(set) var searchPublishedCount = 0
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let watcher = SessionDirectoryWatcher()
    @ObservationIgnored private var watching = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private let conflictTimestamp: @Sendable () -> Int64
    @ObservationIgnored private nonisolated let completions = OSAllocatedUnfairLock(initialState: [Completion]())
    @ObservationIgnored private nonisolated let writeQueue = DispatchQueue(
        label: "com.gl11tchy.sigil.notes", qos: .utility)
    private nonisolated static let log = Logger(subsystem: "com.gl11tchy.sigil", category: "notes")
    static let flushDelay: Duration = .milliseconds(300)

    public init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        self.conflictTimestamp = { Int64(Date().timeIntervalSince1970 * 1000) }
        self.searchReader = .disk
    }

    init(root: URL, conflictTimestamp: @escaping @Sendable () -> Int64) {
        self.root = root
        self.conflictTimestamp = conflictTimestamp
        self.searchReader = .disk
    }

    init(root: URL, searchReader: ConversationNotesIndex.Reader) {
        self.root = root
        self.conflictTimestamp = { Int64(Date().timeIntervalSince1970 * 1000) }
        self.searchReader = searchReader
    }

    deinit {
        searchRefreshTask?.cancel()
        searchCancellation?.withLock { $0 = true }
    }

    /// Membership checks are memory-only. Canonicalization and exact-path
    /// discovery happen once off-main when the captured identity set changes.
    public func prepareSearch(for sessions: [GrokSession]) {
        let references = Set(sessions.map(\.reference))
        guard references != searchReferences else { return }
        searchReferences = references
        // Adding a same-ID folder can make a former flat-note match ambiguous.
        searchSnapshot = nil
        searchGeneration &+= 1
        startWatching()
        requestSearchRefresh(immediate: true)
    }

    /// No filesystem access, decoding or folding per search keystroke.
    public func foldedNote(for reference: ProviderSessionReference) -> String? {
        _ = searchGeneration
        guard searchReferences.contains(reference) else { return nil }
        return searchSnapshot?.foldedNote(for: reference, overlays: searchOverlays)
    }

    /// Project aliases can retarget without changing a raw session reference.
    public func invalidateSearchPaths() {
        guard !searchReferences.isEmpty else { return }
        requestSearchRefresh()
    }

    private func publishSearchOverlay(_ url: URL) {
        guard let entry = entries[url.path] else { return }
        let folded = ConversationNotesIndex.foldedPrefix(entry.text)
        guard searchOverlays[url.path] != folded else { return }
        searchOverlays[url.path] = folded
        searchGeneration &+= 1
    }

    private func requestSearchRefresh(immediate: Bool = false) {
        searchRequest &+= 1
        searchCancellation?.withLock { $0 = true }
        searchRefreshTask?.cancel()
        guard !searchReferences.isEmpty else { return }
        if immediate {
            startSearchScan()
            return
        }
        searchRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.startSearchScan()
        }
    }

    private func startSearchScan() {
        guard !searchBusy else {
            searchPending = true
            return
        }
        guard !searchReferences.isEmpty else { return }
        searchBusy = true
        searchScanCount += 1
        let request = searchRequest
        let references = searchReferences
        let root = self.root
        let cache = searchCache
        let reader = searchReader
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        searchCancellation = cancelled
        searchQueue.async { [weak self] in
            let catalog = ConversationNotesIndex.catalog(
                root: root, references: references, isCancelled: { cancelled.withLock { $0 } })
            let snapshot = ConversationNotesIndex.scan(
                catalog: catalog, cache: cache, reader: reader, isCancelled: { cancelled.withLock { $0 } })
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.searchBusy = false
                self.searchCancellation = nil
                if request == self.searchRequest, let snapshot {
                    self.searchPublishedCount += 1
                    let changed =
                        self.searchSnapshot?.folded != snapshot.folded
                        || self.searchSnapshot?.catalog.references != snapshot.catalog.references
                        || self.searchSnapshot?.origins != snapshot.origins
                    self.searchSnapshot = snapshot
                    self.searchCache = snapshot.cache
                    if changed { self.searchGeneration &+= 1 }
                }
                if self.searchPending {
                    self.searchPending = false
                    self.startSearchScan()
                }
            }
        }
    }

    public static var defaultRoot: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Sigil/notes", isDirectory: true)
    }

    public func note(for sessionID: String, cwd: String) -> String {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return "" }
        load(url, legacyID: Self.isValidSessionID(sessionID) ? sessionID : nil)
        return entries[url.path]?.text ?? ""
    }

    public func notice(for sessionID: String, cwd: String) -> Notice? {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return nil }
        return entries[url.path]?.notice
    }

    public func setNote(_ text: String, for sessionID: String, cwd: String) {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return }
        // Edits/deletes must not adopt a flat note that another folder still
        // needs. Adoption remains exclusive to the first explicit note read.
        load(url)
        entries[url.path]?.text = text
        entries[url.path]?.generation &+= 1
        entries[url.path]?.dirty = true
        publishSearchOverlay(url)
        scheduleFlush()
    }

    public func deleteNote(for sessionID: String, cwd: String) {
        setNote("", for: sessionID, cwd: cwd)
    }

    public func isSaved(for sessionID: String, cwd: String) -> Bool {
        guard let url = fileURL(for: sessionID, cwd: cwd) else { return false }
        guard let entry = entries[url.path] else { return true }
        return !entry.dirty && !entry.writing && entry.notice != .saveFailed
    }

    public func deleteFlatNote(forSessionID sessionID: String) {
        guard Self.isValidSessionID(sessionID) else { return }
        let url = root.appendingPathComponent(sessionID + ".md")
        load(url)
        entries[url.path]?.text = ""
        entries[url.path]?.generation &+= 1
        entries[url.path]?.dirty = true
        publishSearchOverlay(url)
        scheduleFlush()
    }

    /// The quit path drains queued saves and applies their results before retrying.
    public func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        writeQueue.sync {}
        applyCompletions()
        let pending = takePending()
        apply(writeQueue.sync { pending.map(Self.write) })
    }

    public func retrySaves() {
        flushNow()
        refresh()
    }

    private func load(_ url: URL, legacyID: String? = nil) {
        guard entries[url.path] == nil else { return }
        // Install the watcher before the first read to avoid a discovery gap.
        startWatching()
        // Only Grok had a flat layout; provider-prefixed IDs never adopt it.
        if let legacyID { adoptFlatLayoutFile(named: legacyID + ".md", destination: url) }
        do {
            let revision = try Self.read(url)
            entries[url.path] = Entry(text: try Self.text(revision), baseline: revision)
        } catch {
            entries[url.path] = Entry(text: "", baseline: nil, notice: .saveFailed)
        }
        publishSearchOverlay(url)
    }

    private func startWatching() {
        guard !watching else { return }
        // Watch an existing ancestor when notes or a provider directory does not
        // exist yet. Directory events also catch atomic-save renames and deletion.
        var ancestor = root
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        watching = watcher.start(path: ancestor.path, latency: 0.05, contents: .notes(root: root)) {
            [weak self] restart in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if restart {
                    self.watching = false
                    self.startWatching()
                }
                self.refresh()
            }
        }
    }

    private func refresh() {
        requestSearchRefresh()
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let paths = entries.compactMap { path, entry in
            entry.writing ? nil : (URL(fileURLWithPath: path), entry.generation, entry.baseline)
        }
        writeQueue.async { [weak self] in
            let revisions = paths.map { url, generation, baseline in
                (url, generation, baseline, Result { try Self.read(url) })
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyCompletions()
                for (url, generation, baseline, result) in revisions {
                    guard var entry = self.entries[url.path], !entry.writing,
                        entry.generation == generation, entry.baseline == baseline
                    else { continue }
                    switch result {
                    case .success(let revision):
                        if revision == entry.baseline {
                            if !entry.dirty, entry.notice == .saveFailed {
                                entry.notice = nil
                                self.entries[url.path] = entry
                            }
                            continue
                        }
                        if entry.dirty {
                            // The writer reads the actual latest bytes. Only a
                            // failed preservation retains outside bytes in memory.
                            entry.notice = .conflictUnsaved
                        } else {
                            do {
                                entry.text = try Self.text(revision)
                                entry.baseline = revision
                                // A preserved-conflict notice remains available after our own save.
                                if entry.notice == .saveFailed { entry.notice = nil }
                            } catch {
                                entry.notice = .saveFailed
                            }
                        }
                    case .failure:
                        entry.notice = entry.dirty ? .conflictUnsaved : .saveFailed
                    }
                    self.entries[url.path] = entry
                    self.publishSearchOverlay(url)
                }
                self.refreshing = false
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.refresh()
                }
            }
        }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled, let self else { return }
            self.applyCompletions()
            let pending = self.takePending()
            guard !pending.isEmpty else { return }
            self.writeQueue.async { [weak self, completions = self.completions] in
                let results = pending.map(Self.write)
                completions.withLock { $0 += results }
                Task { @MainActor [weak self] in self?.applyCompletions() }
            }
        }
    }

    private func takePending() -> [Pending] {
        Array(entries).compactMap { path, entry in
            guard entry.dirty, !entry.writing else { return nil }
            entries[path]?.writing = true
            return Pending(
                url: URL(fileURLWithPath: path), generation: entry.generation,
                text: entry.text.isEmpty ? nil : entry.text,
                baseline: entry.baseline, outside: entry.outside, stamp: conflictTimestamp())
        }
    }

    private func applyCompletions() {
        let results = completions.withLock { results in
            defer { results.removeAll() }
            return results
        }
        apply(results)
    }

    private func apply(_ results: [Completion]) {
        var changedDuringWrite = false
        for result in results {
            let path = result.pending.url.path
            guard var entry = entries[path] else { continue }
            entry.writing = false
            entry.outside = result.outside
            entry.preserved += result.preserved
            entry.deletedOutside = entry.deletedOutside || result.deletedOutside
            if result.failed {
                entry.notice = result.conflict ? .conflictUnsaved : .saveFailed
            } else {
                entry.baseline = result.revision
                entry.dirty = entry.generation != result.pending.generation
                if let file = entry.preserved.last {
                    entry.notice = .conflictPreserved(file)
                } else if entry.deletedOutside {
                    entry.notice = .outsideDeletion
                } else if entry.notice == .saveFailed || entry.notice == .conflictUnsaved {
                    entry.notice = nil
                }
                changedDuringWrite = changedDuringWrite || entry.dirty
            }
            entries[path] = entry
        }
        if changedDuringWrite { scheduleFlush() }
        // Events received while a write was in flight may have skipped this
        // entry. Read again after completion so those outside edits still arrive.
        if !results.isEmpty { refresh() }
    }

    private nonisolated static func text(_ revision: Revision) throws -> String {
        guard let data = revision.data else { return "" }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    /// Bytes detect equal-timestamp edits; inode/device detect atomic replacement.
    /// Check attributes around the read so a racing save does not become a baseline.
    private nonisolated static func read(_ url: URL) throws -> Revision {
        let fm = FileManager.default
        for _ in 0..<3 {
            do {
                let before = try fm.attributesOfItem(atPath: url.path)
                guard before[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileReadUnknown) }
                let data = try Data(contentsOf: url)
                let after = try fm.attributesOfItem(atPath: url.path)
                let keys: [FileAttributeKey] = [.systemNumber, .systemFileNumber, .size, .modificationDate]
                guard keys.allSatisfy({ (before[$0] as? NSObject) == (after[$0] as? NSObject) }) else { continue }
                guard let device = (after[.systemNumber] as? NSNumber)?.uint64Value,
                    let inode = (after[.systemFileNumber] as? NSNumber)?.uint64Value
                else { throw CocoaError(.fileReadUnknown) }
                return .file(data: data, device: device, inode: inode)
            } catch CocoaError.fileNoSuchFile { return .missing } catch CocoaError.fileReadNoSuchFile {
                return .missing
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    private nonisolated static func write(_ pending: Pending) -> Completion {
        var result = Completion(pending: pending, outside: pending.outside)
        var coordinationError: NSError?
        // Coordinates cooperating editors and other Sigil instances. Uncoordinated
        // writers are re-read after preservation, immediately before replacement.
        // https://developer.apple.com/documentation/foundation/nsfilecoordinator
        NSFileCoordinator().coordinate(writingItemAt: pending.url, options: [], error: &coordinationError) { url in
            do {
                let fm = FileManager.default
                for _ in 0..<3 {
                    let current = try read(url)
                    result.conflict = result.conflict || current != pending.baseline || !result.outside.isEmpty
                    result.deletedOutside =
                        result.deletedOutside || (current == .missing && pending.baseline?.data != nil)
                    if current != pending.baseline, let data = current.data,
                        data != pending.text.map({ Data($0.utf8) }), !result.outside.contains(data)
                    {
                        result.outside.append(data)
                    }
                    if !result.outside.isEmpty {
                        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        while let data = result.outside.first {
                            let conflict = try preserve(data, beside: url, stamp: pending.stamp)
                            result.preserved.append(conflict)
                            result.outside.removeFirst()
                        }
                    }
                    guard try read(url) == current else { continue }
                    if let text = pending.text {
                        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(text.utf8).write(to: url, options: .atomic)
                    } else {
                        do { try fm.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
                    }
                    result.revision = try read(url)
                    guard result.revision?.data == pending.text.map({ Data($0.utf8) }) else {
                        result.conflict = true
                        if let data = result.revision?.data { result.outside.append(data) }
                        throw CocoaError(.fileWriteUnknown)
                    }
                    return
                }
                throw CocoaError(.fileWriteUnknown)
            } catch {
                result.failed = true
                log.error(
                    "note save failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if coordinationError != nil { result.failed = true }
        return result
    }

    private nonisolated static func preserve(_ data: Data, beside url: URL, stamp: Int64) throws -> URL {
        for suffix in 0..<100 {
            let name = url.deletingPathExtension().lastPathComponent + ".conflict-\(stamp)-\(suffix).md"
            let backup = url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                // SDK NSData.h: .withoutOverwriting cannot be combined with .atomic.
                // An exclusive creation never replaces another instance's conflict.
                try data.write(to: backup, options: .withoutOverwriting)
                return backup
            } catch CocoaError.fileWriteFileExists { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// The first notes build wrote `notes/<id>.md` with no folder; adopt that
    /// file the first time the conversation's real location is read.
    private func adoptFlatLayoutFile(named fileName: String, destination: URL) {
        let legacy = root.appendingPathComponent(fileName)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path),
            fm.fileExists(atPath: legacy.path)
        else { return }
        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacy, to: destination)
        } catch {
            Self.log.error(
                "flat note adoption failed for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Preserve every existing Grok path. New native providers get their own
    /// directory namespace and only a validated UUID becomes a file name.
    private func fileURL(for sessionID: String, cwd: String) -> URL? {
        guard !cwd.isEmpty else { return nil }
        let directory = GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(cwd))
        if Self.isValidSessionID(sessionID) {
            return root.appendingPathComponent(directory).appendingPathComponent(sessionID + ".md")
        }
        let parts = sessionID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, ["claudeCode", "codex"].contains(String(parts[0])),
            let uuid = UUID(uuidString: String(parts[1]))
        else { return nil }
        return root.appendingPathComponent(String(parts[0])).appendingPathComponent(directory)
            .appendingPathComponent(uuid.uuidString.lowercased() + ".md")
    }

    private static func isValidSessionID(_ sessionID: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return !sessionID.isEmpty
            && sessionID.rangeOfCharacter(from: allowed.inverted) == nil
    }
}
