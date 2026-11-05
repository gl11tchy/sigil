import Foundation
import Observation

struct SessionStoreTiming: Sendable {
    var debounceDelay: Duration = .seconds(1)
    var maximumDebounceDelay: Duration = .seconds(3)
    var watcherRetryDelay: Duration = .seconds(2)
    var watcherLatency: CFTimeInterval = 1
    var indexWriteDelay: Duration = .seconds(1)
    var historyValidationDelay: Duration = .milliseconds(250)
}

/// Reads the Grok Build session history off disk and keeps it current.
@MainActor
@Observable
public final class SessionStore {

    typealias ScanOperation =
        @Sendable (
            _ root: URL,
            _ cache: [String: SessionCacheEntry],
            _ policy: SessionHistoryScanner.Policy
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

    /// One shared source pass serves startup, restoration and actions. Failed unchanged sources are not retried in a loop.
    public var hasPendingHistoryValidation: Bool {
        guard isStarted else { return false }
        return historyValidationTask != nil
            || cache.contains {
                !$0.value.session.isHistoryValidated && historyValidationAttempts[$0.key] != $0.value
            }
    }

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
    @ObservationIgnored private var historyValidationTask: Task<Void, Never>?
    @ObservationIgnored private var historyValidationGeneration = 0
    @ObservationIgnored private var historyValidationScanInFlight = false
    @ObservationIgnored private var historyValidationAttempts: [String: SessionCacheEntry] = [:]
    @ObservationIgnored private var forcedScanWaiters: [CheckedContinuation<Void, Never>] = []

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
        let scanner = SessionHistoryScanner(
            nativeRoots: nativeRoots, availableRoots: availableRoots, titleIndexCache: titleIndexCache,
            contentReader: contentReader, nativeContentReader: nativeContentReader,
            nativeRecordDecoder: nativeRecordDecoder)
        self.init(
            root: root,
            timing: timing,
            nativeRoots: nativeRoots,
            indexFile: indexFile,
            titleIndexCache: titleIndexCache,
            scanOperation: { root, cache, policy in
                let scan = Task.detached(priority: .userInitiated) {
                    scanner.scan(root: root, cache: cache, policy: policy)
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
        historyValidationTask?.cancel()
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
        cancelHistoryValidation()
        historyValidationAttempts.removeAll()
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

    /// Rereads Grok summaries and checks native file identities, parsing changed or unvalidated sources.
    public func reload() async {
        await reload(rebuildingNativeHistory: false)
    }

    /// Explicit Retry/diagnostic recovery, including unchanged failed sources and stale native cache entries.
    public func rebuildHistory() async {
        await reload(rebuildingNativeHistory: true)
    }

    /// Refreshes the list immediately after a deletion, retaining unchanged provider caches.
    public func refresh() async {
        guard !Task.isCancelled else { return }
        debounceTask?.cancel()
        debounceTask = nil
        firstPendingEvent = nil
        refreshWatcher()
        await scan(ignoringCache: false)
        guard !Task.isCancelled else { return }
        refreshWatcher()
    }

    private func reload(rebuildingNativeHistory: Bool) async {
        guard !Task.isCancelled else { return }
        cancelHistoryValidation()
        // Read saved display rows even when their metadata matches. Cache reuse never grants source authority.
        // This pass retries them once; do not immediately repeat unchanged failures in background validation.
        historyValidationAttempts = cache.filter { !$0.value.session.isHistoryValidated }
        debounceTask?.cancel()
        debounceTask = nil
        firstPendingEvent = nil
        refreshWatcher()
        await scan(
            ignoringCache: true, refreshing: Set(historyValidationAttempts.keys),
            rebuildingNativeHistory: rebuildingNativeHistory)
        guard !Task.isCancelled else { return }
        refreshWatcher()
    }

    /// A saved display row cannot launch a CLI or authorize removal. Read its source again first.
    public func validatedSession(for candidate: GrokSession) async -> GrokSession? {
        await validatedSessions(for: [candidate]).first
    }

    /// Validate a saved tab snapshot together, rather than traversing every history root once per tab.
    public func validatedSessions(for candidates: [GrokSession]) async -> [GrokSession] {
        guard !Task.isCancelled else { return [] }
        let generation = startupGeneration
        if candidates.contains(where: { !$0.isHistoryValidated }) {
            if appliedScanSequence == 0 { await startupTask?.value }
            repeat {
                if forcedScansInFlight > 0 {
                    await withCheckedContinuation { forcedScanWaiters.append($0) }
                }
                guard !Task.isCancelled, generation == startupGeneration else { return [] }
                scheduleHistoryValidation(delay: .zero)
                await historyValidationTask?.value
                guard !Task.isCancelled, generation == startupGeneration else { return [] }
            } while forcedScansInFlight > 0
        }
        let roots = SessionIndexFile.roots(grok: root, native: nativeRoots)
        return candidates.compactMap { candidate in
            guard
                let current = sessions.first(where: {
                    $0.reference == candidate.reference && $0.directory == candidate.directory && $0.isHistoryValidated
                })
            else { return nil }
            if !candidate.isHistoryValidated {
                guard let indexFile,
                    indexFile.permitsSource(
                        current.directory.standardizedFileURL.path, roots: roots, provider: current.provider)
                else { return nil }
            }
            return current
        }
    }

    private func cancelHistoryValidation() {
        historyValidationGeneration += 1
        historyValidationTask?.cancel()
        historyValidationTask = nil
        historyValidationScanInFlight = false
    }

    private func scheduleHistoryValidation(delay: Duration) {
        guard isStarted, indexFile != nil, appliedScanSequence > 0, historyValidationTask == nil,
            forcedScansInFlight == 0,
            hasPendingHistoryValidation
        else { return }
        let generation = historyValidationGeneration
        historyValidationTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, generation == self.historyValidationGeneration else { return }
            defer {
                if generation == self.historyValidationGeneration {
                    self.historyValidationTask = nil
                    self.historyValidationScanInFlight = false
                    if self.cachedScanPending, self.forcedScansInFlight == 0 {
                        self.cachedScanPending = false
                        Task { await self.scan(ignoringCache: false) }
                    }
                }
            }
            // The envelope bounds this set to 10,000 sources. One pass, existing per-provider read bounds,
            // and scanner cancellation checks keep validation finite; unchanged failures remain display-only.
            let targets = self.cache.filter {
                !$0.value.session.isHistoryValidated && self.historyValidationAttempts[$0.key] != $0.value
            }
            guard !targets.isEmpty else { return }
            self.historyValidationAttempts.merge(targets) { _, new in new }
            self.historyValidationScanInFlight = true
            await self.scan(ignoringCache: false, refreshing: Set(targets.keys))
        }
    }

    /// A present Grok folder without its summary is not proof that its saved metadata is stale.
    public func protectsGrokMetadata(sessionID: String, cwd: String) -> Bool {
        let folder = GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(cwd))
        let directory = root.appendingPathComponent(folder).appendingPathComponent(sessionID).standardizedFileURL.path
        return coverage.unrecognizedGrokDirectories.contains(directory)
    }

    /// Cached rows can remain visible after a failed Grok read or unsupported
    /// summary. Their retained fields alone cannot authorize a new resume.
    /// An unrelated native root's failure is not a Grok source failure.
    public func isGrokHistoryUncertain(for session: GrokSession) -> Bool {
        session.provider != .grokBuild || !session.isHistoryValidated || appliedScanSequence == 0 || isLoading
            || coverage.uncertainRoots.contains(root.standardizedFileURL.path)
            || coverage.unrecognizedGrokDirectories.contains(session.directory.standardizedFileURL.path)
    }

    /// Sessions whose title, project name, `~` path, or cwd match `query`.
    /// Closest title first, then higher `boost`, then newer activity. An empty or whitespace-only
    /// query returns every session, newest first, without evaluating
    /// `displayedTitle` or `boost`. Pass `displayedTitle` so a user-chosen name is
    /// searched; the CLI summary still matches after a rename.
    /// Does not read a transcript.
    public func search(
        _ query: String,
        displayedTitle: ((GrokSession) -> String)? = nil
    ) -> [GrokSession] {
        search(query, boost: nil, displayedTitle: displayedTitle)
    }

    /// The boost label is required so existing trailing title closures keep
    /// selecting the original overload, including with Swift's forward scan.
    public func search(
        _ query: String,
        boost: ((GrokSession) -> Int)?,
        displayedTitle: ((GrokSession) -> String)? = nil
    ) -> [GrokSession] {
        search(query, boost: boost, matchingNotes: nil, displayedTitle: displayedTitle)
    }

    /// Precomputed note membership is inspected only after title/path miss.
    /// Both labels are required to retain existing trailing-title call forms.
    public func search(
        _ query: String,
        boost: ((GrokSession) -> Int)?,
        matchingNotes: ((GrokSession) -> Bool)?,
        displayedTitle: ((GrokSession) -> String)? = nil
    ) -> [GrokSession] {
        SessionScanner.search(
            query, sessions: sessions, keys: searchKeys, boost: boost, displayedTitle: displayedTitle,
            matchingNotes: matchingNotes)
    }

    /// Walks `root` off the main actor. Cache hits skip JSON decoding.
    func scan(
        ignoringCache: Bool, refreshing keys: Set<String> = [], rebuildingNativeHistory: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        if !ignoringCache, forcedScansInFlight > 0 || (keys.isEmpty && historyValidationScanInFlight) {
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
                if forcedScansInFlight == 0 {
                    let waiters = forcedScanWaiters
                    forcedScanWaiters.removeAll()
                    for waiter in waiters { waiter.resume() }
                }
                if forcedScansInFlight == 0, cachedScanPending {
                    cachedScanPending = false
                    Task { await self.scan(ignoringCache: false) }
                }
            }
        }

        let root = self.root
        var snapshot = cache
        for key in keys {
            guard var entry = snapshot[key] else { continue }
            // Keep uncertain rows for display while forcing this one source to be parsed.
            entry.inode = nil
            snapshot[key] = entry
        }
        let policy: SessionHistoryScanner.Policy =
            rebuildingNativeHistory ? .rebuild : (ignoringCache ? .reload : .cached)
        var result = await scanOperation(root, snapshot, policy)

        // Invalidating an inode is a read request, never a new source identity. Preserve failed saved metadata
        // so the eventual pass cannot schedule itself again merely because its own cache marker changed.
        for key in keys where result.cache[key]?.session.isHistoryValidated == false {
            result.cache[key]?.inode = cache[key]?.inode
        }

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
        if isStarted { scheduleHistoryValidation(delay: timing.historyValidationDelay) }
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
