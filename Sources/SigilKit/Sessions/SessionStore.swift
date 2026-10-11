import Foundation
import Observation

struct SessionStoreTiming: Sendable {
    var debounceDelay: Duration = .seconds(1)
    var maximumDebounceDelay: Duration = .seconds(3)
    var watcherRetryDelay: Duration = .seconds(2)
    var watcherLatency: CFTimeInterval = 1
    var indexWriteDelay: Duration = .seconds(1)
}

/// Reads the Grok Build session history off disk and keeps it current.
@MainActor
@Observable
public final class SessionStore {

    typealias ScanOperation =
        @Sendable (
            _ root: URL,
            _ cache: [String: SessionCacheEntry],
            _ ignoringCache: Bool
        ) async -> SessionScanner.Result

    /// Every known session, newest activity first.
    public private(set) var sessions: [GrokSession] = []
    /// True while a scan is in flight.
    public private(set) var isLoading: Bool = false
    /// Set when the sessions directory or one or more session summaries could not be read.
    public private(set) var loadError: String?
    /// Compatibility information does not block loading or independently verified removals.
    public private(set) var historyNotice: String?
    /// An unknown file can belong to an otherwise empty project. Keep project metadata in that case.
    public private(set) var canPruneMissingProjects = false

    public var hasUnvalidatedHistory: Bool { sessions.contains { !$0.isHistoryValidated } }

    public let root: URL
    /// The captured root shared by history scans, watchers and identity proof.
    public var codexHistoryRoot: URL? { nativeRoots.first { $0.0 == .codex }?.1 }
    @ObservationIgnored private var cache: [String: SessionCacheEntry] = [:]
    @ObservationIgnored private var coverage = SessionScanner.Coverage()
    /// Folded search fields, one per entry of `sessions`, in the same order.
    @ObservationIgnored private var searchKeys: [SessionScanner.SearchKey] = []
    @ObservationIgnored private var isStarted = false
    /// How many scans have started, and which of them produced `sessions`.
    /// A scan numbered above a moment's `scanSequence` began after it.
    @ObservationIgnored public private(set) var scanSequence = 0
    public private(set) var appliedScanSequence = 0
    @ObservationIgnored private var forceEpoch = 0
    @ObservationIgnored private var forcedScansInFlight = 0
    @ObservationIgnored private var cachedScanPending = false
    @ObservationIgnored private var inflight = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var firstPendingEvent: ContinuousClock.Instant?
    @ObservationIgnored let watcher = SessionDirectoryWatcher()
    @ObservationIgnored private var nativeWatchers: [String: SessionDirectoryWatcher] = [:]
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var watcherRetryTask: Task<Void, Never>?
    @ObservationIgnored private let eventContinuation: AsyncStream<Bool>.Continuation
    @ObservationIgnored private var eventPump: Task<Void, Never>?
    @ObservationIgnored private let timing: SessionStoreTiming
    @ObservationIgnored private let scanOperation: ScanOperation
    @ObservationIgnored private let nativeRoots: [(CLIProvider, URL)]
    @ObservationIgnored private let indexFile: SessionIndexFile?
    @ObservationIgnored private let titleIndexCache: CodexTitleIndexCache
    @ObservationIgnored private let indexWriter = SessionIndexWriter()
    @ObservationIgnored private var indexWriteTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var startupGeneration = 0

    public convenience init() {
        self.init(
            root: SessionDirectoryWatcher.canonicalURL(GrokPaths.sessionsRoot), timing: SessionStoreTiming(),
            nativeRoots: NativeSessionScanner.roots, indexFile: SessionIndexFile(url: SessionIndexFile.defaultURL))
    }

    public convenience init(root: URL, includesNativeHistory: Bool = false) {
        self.init(
            root: root, timing: SessionStoreTiming(),
            nativeRoots: includesNativeHistory ? NativeSessionScanner.roots : [])
    }

    /// Capture the same roots for the watcher and detached scans. Explicit roots
    /// also keep filesystem tests isolated from the user's provider history.
    convenience init(
        root: URL, timing: SessionStoreTiming, nativeRoots: [(CLIProvider, URL)] = [],
        nativeContentReader: NativeSessionScanner.ContentReader = .disk,
        nativeRecordDecoder: NativeSessionRecordDecoder = .init(),
        indexFile: SessionIndexFile? = nil,
        contentReader: SessionScanner.ContentReader = .disk
    ) {
        let nativeRoots = nativeRoots.map { ($0.0, SessionDirectoryWatcher.canonicalURL($0.1)) }
        // Availability is a monotonic observed fact, including roots with zero sessions.
        // Concurrent or superseded scans may observe it; only applied scans publish notices.
        let availableRoots = SessionScanner.RootAvailability()
        // Scoped to this store's captured roots, never shared across CLI homes.
        let titleIndexCache = CodexTitleIndexCache()
        self.init(
            root: root,
            timing: timing,
            nativeRoots: nativeRoots,
            indexFile: indexFile,
            titleIndexCache: titleIndexCache,
            scanOperation: { root, cache, ignoringCache in
                let scan = Task.detached(priority: .userInitiated) {
                    var result = SessionScanner.scan(
                        root: root,
                        cache: cache.filter { $0.value.session.provider == .grokBuild },
                        ignoringCache: ignoringCache,
                        contentReader: contentReader,
                        rootAvailability: availableRoots
                    )
                    for (provider, nativeRoot) in nativeRoots {
                        let native = NativeSessionScanner.scan(
                            provider: provider, root: nativeRoot, cache: cache, ignoringCache: ignoringCache,
                            rootAvailability: availableRoots, contentReader: nativeContentReader,
                            recordDecoder: nativeRecordDecoder, titleIndexCache: titleIndexCache)
                        result.sessions += native.sessions
                        result.cache.merge(native.cache) { _, new in new }
                        result.loadError =
                            [result.loadError, native.loadError].compactMap { $0 }.joined(separator: "\n")
                            .nilIfBlank
                        result.coverage.merge(native.coverage)
                    }
                    if !nativeRoots.isEmpty { result.sessions.sort(by: SessionScanner.isNewer) }
                    return result
                }
                return await withTaskCancellationHandler {
                    await scan.value
                } onCancel: {
                    scan.cancel()
                }
            }
        )
    }

    init(
        root: URL,
        timing: SessionStoreTiming,
        nativeRoots: [(CLIProvider, URL)] = [],
        indexFile: SessionIndexFile? = nil,
        titleIndexCache: CodexTitleIndexCache = CodexTitleIndexCache(),
        scanOperation: @escaping ScanOperation
    ) {
        self.root = root
        self.timing = timing
        self.scanOperation = scanOperation
        self.nativeRoots = nativeRoots
        self.indexFile = indexFile
        self.titleIndexCache = titleIndexCache
        let stream: AsyncStream<Bool>
        let continuation: AsyncStream<Bool>.Continuation
        (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.eventContinuation = continuation
        self.eventPump = Task { [weak self] in
            for await requiresRestart in stream {
                guard let self, self.isStarted else { continue }
                if requiresRestart {
                    self.watchedPath = nil
                    for watcher in self.nativeWatchers.values { watcher.stop() }
                    self.nativeWatchers.removeAll()
                }
                self.refreshWatcher()
                self.scheduleDebouncedScan()
            }
        }
    }

    deinit {
        startupTask?.cancel()
        indexWriteTask?.cancel()
        eventContinuation.finish()
        eventPump?.cancel()
        watcherRetryTask?.cancel()
        debounceTask?.cancel()
        watcher.stop()
        for watcher in nativeWatchers.values { watcher.stop() }
    }

    /// Begins watching the sessions directory and performs the first scan.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        startupGeneration += 1
        let generation = startupGeneration
        isLoading = true
        startupTask = Task { [weak self] in
            guard let self else { return }
            if let file = self.indexFile, self.scanSequence == 0 {
                let roots = SessionIndexFile.roots(grok: self.root, native: self.nativeRoots)
                let load = Task.detached(priority: .userInitiated) { file.load(roots: roots) }
                let saved = await withTaskCancellationHandler {
                    await load.value
                } onCancel: {
                    load.cancel()
                }
                guard !Task.isCancelled, self.isStarted, generation == self.startupGeneration else { return }
                // A reload racing the disk load owns its result. Display publication is not a scan.
                if self.scanSequence == 0, let saved {
                    self.cache = saved.entries
                    self.sessions = saved.entries.values.map(\.session).sorted(by: SessionScanner.isNewer)
                    self.searchKeys = SessionScanner.searchKeys(for: self.sessions)
                    self.titleIndexCache.restoreDisplaySnapshots(saved.titleIndexes)
                }
            }
            guard !Task.isCancelled, self.isStarted, generation == self.startupGeneration else { return }
            self.refreshWatcher()
            self.startWatcherRetryLoop()
            await self.scan(ignoringCache: false)
            if generation == self.startupGeneration { self.startupTask = nil }
        }
    }

    /// Stops watching. Safe to call when not started.
    public func stop() {
        startupGeneration += 1
        startupTask?.cancel()
        startupTask = nil
        indexWriteTask?.cancel()
        indexWriteTask = nil
        if inflight == 0 { isLoading = false }
        for watcher in nativeWatchers.values { watcher.stop() }
        nativeWatchers.removeAll()
        watcher.stop()
        watchedPath = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        firstPendingEvent = nil
        cachedScanPending = false
        isStarted = false
    }

    /// Forces a rescan, ignoring any caches.
    public func reload() async {
        guard !Task.isCancelled else { return }
        debounceTask?.cancel()
        debounceTask = nil
        firstPendingEvent = nil
        refreshWatcher()
        await scan(ignoringCache: true)
        guard !Task.isCancelled else { return }
        refreshWatcher()
    }

    /// A saved display row cannot launch a CLI or authorize removal. Read its source again first.
    public func validatedSession(for candidate: GrokSession) async -> GrokSession? {
        guard !Task.isCancelled else { return nil }
        func matches(_ session: GrokSession) -> Bool {
            session.reference == candidate.reference && session.directory == candidate.directory
        }
        guard let current = sessions.first(where: matches) else { return nil }
        if current.isHistoryValidated { return current }
        let key = current.directory.standardizedFileURL.path
        let roots = SessionIndexFile.roots(grok: root, native: nativeRoots)
        guard let indexFile, indexFile.permitsSource(key, roots: roots, provider: current.provider) else { return nil }
        await scan(ignoringCache: false, refreshing: key)
        guard !Task.isCancelled, indexFile.permitsSource(key, roots: roots, provider: current.provider) else {
            return nil
        }
        return sessions.first { matches($0) && $0.isHistoryValidated }
    }

    /// A present Grok folder without its summary is not proof that its saved metadata is stale.
    public func protectsGrokMetadata(sessionID: String, cwd: String) -> Bool {
        let folder = GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(cwd))
        let directory = root.appendingPathComponent(folder).appendingPathComponent(sessionID).standardizedFileURL.path
        return coverage.unrecognizedGrokDirectories.contains(directory)
    }

    /// Sessions whose title, project name, `~` path, or cwd match `query`.
    /// Closest title first, then newer activity. An empty or whitespace-only
    /// query returns every session, newest first, without evaluating
    /// `displayedTitle`. Pass `displayedTitle` so a user-chosen name is
    /// searched; the CLI summary still matches after a rename.
    /// Does not read a transcript.
    public func search(
        _ query: String,
        displayedTitle: ((GrokSession) -> String)? = nil
    ) -> [GrokSession] {
        guard let query = SessionScanner.SearchQuery(query) else { return sessions }
        return zip(sessions, searchKeys).compactMap { session, key -> (GrokSession, SessionScanner.SearchRank)? in
            guard
                let rank = SessionScanner.searchRank(
                    key,
                    query: query,
                    displayedTitle: displayedTitle?(session)
                )
            else { return nil }
            return (session, rank)
        }
        .sorted { lhs, rhs in
            if lhs.1.rawValue != rhs.1.rawValue { return lhs.1.rawValue < rhs.1.rawValue }
            return SessionScanner.isNewer(lhs.0, rhs.0)
        }
        .map(\.0)
    }

    /// Walks `root` off the main actor. Cache hits skip JSON decoding.
    func scan(ignoringCache: Bool, refreshing key: String? = nil) async {
        guard !Task.isCancelled else { return }
        if !ignoringCache, forcedScansInFlight > 0 {
            cachedScanPending = true
            return
        }

        scanSequence += 1
        let sequence = scanSequence
        if ignoringCache {
            forceEpoch += 1
            forcedScansInFlight += 1
        }
        let capturedForceEpoch = forceEpoch
        inflight += 1
        if ignoringCache || sessions.isEmpty, !isLoading {
            isLoading = true
        }
        defer {
            inflight -= 1
            if inflight == 0, isLoading { isLoading = false }
            if ignoringCache {
                forcedScansInFlight -= 1
                if forcedScansInFlight == 0, cachedScanPending {
                    cachedScanPending = false
                    Task { await self.scan(ignoringCache: false) }
                }
            }
        }

        let root = self.root
        var snapshot = cache
        if let key, var entry = snapshot[key] {
            // Keep uncertain rows for display while forcing this one source to be parsed.
            entry.inode = nil
            snapshot[key] = entry
        }
        let result = await scanOperation(root, snapshot, ignoringCache)

        guard !Task.isCancelled, capturedForceEpoch == forceEpoch else { return }
        if !ignoringCache {
            guard forcedScansInFlight == 0, sequence >= appliedScanSequence else { return }
        }
        appliedScanSequence = sequence
        cache = result.cache
        var nextCoverage = result.coverage
        for root in nextCoverage.uncertainRoots {
            if let previous = coverage.notices[root] {
                if nextCoverage.notices[root] == nil {
                    nextCoverage.notices[root] = previous
                } else if let current = nextCoverage.notices[root], current != previous {
                    nextCoverage.notices[root] = current + " Earlier compatibility notices remain unresolved."
                }
            }
            // Preserve summary-less folders whose parent could not be enumerated.
            let prefix = root.hasSuffix("/") ? root : root + "/"
            nextCoverage.unrecognizedGrokDirectories.formUnion(
                coverage.unrecognizedGrokDirectories.filter { $0.hasPrefix(prefix) })
        }
        coverage = nextCoverage
        if sessions != result.sessions {
            sessions = result.sessions
            searchKeys = SessionScanner.searchKeys(for: sessions)
        }
        if loadError != result.loadError {
            loadError = result.loadError
        }
        let notice = nextCoverage.notices.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n").nilIfBlank
        if historyNotice != notice { historyNotice = notice }
        let canPrune =
            nextCoverage.uncertainRoots.isEmpty && nextCoverage.notices.isEmpty && result.loadError == nil
            && !hasUnvalidatedHistory
        if canPruneMissingProjects != canPrune { canPruneMissingProjects = canPrune }
        scheduleIndexWrite(sequence: sequence)
        refreshWatcher()
    }

    private func scheduleIndexWrite(sequence: Int) {
        guard let indexFile else { return }
        indexWriteTask?.cancel()
        let snapshot = SessionIndexFile.Snapshot(
            roots: SessionIndexFile.roots(grok: root, native: nativeRoots), entries: cache)
        let writer = indexWriter
        let titles = titleIndexCache
        let delay = timing.indexWriteDelay
        indexWriteTask = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await writer.save(snapshot, to: indexFile, sequence: sequence, titleIndexCache: titles)
        }
    }

    func scheduleDebouncedScan() {
        guard isStarted else { return }
        let now = ContinuousClock.now
        let first = firstPendingEvent ?? now
        firstPendingEvent = first
        let quietDeadline = now.advanced(by: timing.debounceDelay)
        let maximumDeadline = first.advanced(by: timing.maximumDebounceDelay)
        let deadline = min(quietDeadline, maximumDeadline)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                let delay = ContinuousClock.now.duration(to: deadline)
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.isStarted else { return }
            self.debounceTask = nil
            self.firstPendingEvent = nil
            await self.scan(ignoringCache: false)
        }
    }

    private func startWatcherRetryLoop() {
        watcherRetryTask?.cancel()
        watcherRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.timing.watcherRetryDelay)
                } catch {
                    return
                }
                guard self.isStarted else { return }
                self.refreshWatcher()
            }
        }
    }

    /// Watches the root only. While it is missing, nothing is watched: its
    /// nearest existing ancestor can be the home folder, whose churn would
    /// rescan constantly. The retry loop starts the watcher once it appears.
    private func refreshWatcher() {
        guard isStarted else { return }
        if !nativeRoots.isEmpty {
            for (provider, nativeRoot) in nativeRoots {
                let path = nativeRoot.path
                // Codex names live next to sessions, so watch their common parent
                // with a scoped filter rather than accepting all Codex home churn.
                let titleIndex =
                    provider == .codex
                    ? nativeRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl") : nil
                let watchRoot = titleIndex == nil ? nativeRoot : nativeRoot.deletingLastPathComponent()
                guard nativeWatchers[path] == nil, FileManager.default.fileExists(atPath: watchRoot.path) else {
                    continue
                }
                let watcher = SessionDirectoryWatcher()
                let continuation = eventContinuation
                if watcher.start(
                    path: watchRoot.path, latency: timing.watcherLatency,
                    contents: .nativeHistory(root: nativeRoot, titleIndex: titleIndex),
                    handler: { requiresRestart in continuation.yield(requiresRestart) })
                {
                    nativeWatchers[path] = watcher
                    continuation.yield(false)
                }
            }
        }
        guard let desiredPath = existingRootPath() else {
            // Also ends a stream whose root was just deleted (a restart
            // event clears `watchedPath` before this runs).
            watcher.stop()
            if watchedPath != nil {
                // FSEvents has not reported the deletion yet (its restart event
                // clears `watchedPath`), and stopping the stream drops that report.
                // Treat the loss as an event of its own.
                watchedPath = nil
                eventContinuation.yield(false)
            }
            return
        }
        guard desiredPath != watchedPath else { return }

        watcher.stop()
        watchedPath = nil
        let continuation = eventContinuation
        let started = watcher.start(
            path: desiredPath,
            latency: timing.watcherLatency,
            handler: { requiresRestart in continuation.yield(requiresRestart) }
        )
        if started {
            watchedPath = desiredPath
            // Starting on a newly available root may happen during the retry loop, after the
            // creation event was missed. Treat the successful move as an event of its own.
            continuation.yield(false)
        }
    }

    private func existingRootPath() -> String? {
        let path = root.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return path
    }
}
