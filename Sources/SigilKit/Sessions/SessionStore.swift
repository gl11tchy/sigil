import Foundation
import Observation
import os

struct SessionStoreTiming: Sendable {
    var debounceDelay: Duration = .seconds(1)
    var maximumDebounceDelay: Duration = .seconds(3)
    var watcherRetryDelay: Duration = .seconds(2)
    var watcherLatency: CFTimeInterval = 1
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
    @ObservationIgnored public private(set) var appliedScanSequence = 0
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

    public convenience init() {
        self.init(root: GrokPaths.sessionsRoot, includesNativeHistory: true)
    }

    public convenience init(root: URL, includesNativeHistory: Bool = false) {
        self.init(
            root: root, timing: SessionStoreTiming(),
            nativeRoots: includesNativeHistory ? NativeSessionScanner.roots : [])
    }

    /// Capture the same roots for the watcher and detached scans. Explicit roots
    /// also keep filesystem tests isolated from the user's provider history.
    convenience init(root: URL, timing: SessionStoreTiming, nativeRoots: [(CLIProvider, URL)] = []) {
        let nativeRoots = nativeRoots.map { ($0.0, SessionDirectoryWatcher.canonicalURL($0.1)) }
        // Availability is a monotonic observed fact, including roots with zero sessions.
        // Concurrent or superseded scans may observe it; only applied scans publish notices.
        let availableRoots = OSAllocatedUnfairLock(initialState: Set<String>())
        self.init(
            root: root,
            timing: timing,
            nativeRoots: nativeRoots,
            scanOperation: { root, cache, ignoringCache in
                await Task.detached(priority: .userInitiated) {
                    let previousRoots = availableRoots.withLock { $0 }
                    var result = SessionScanner.scan(
                        root: root,
                        cache: cache.filter { $0.value.session.provider == .grokBuild },
                        ignoringCache: ignoringCache,
                        wasAvailable: previousRoots.contains(root.standardizedFileURL.path)
                    )
                    for (provider, nativeRoot) in nativeRoots {
                        let native = NativeSessionScanner.scan(
                            provider: provider, root: nativeRoot, cache: cache, ignoringCache: ignoringCache,
                            wasAvailable: previousRoots.contains(nativeRoot.standardizedFileURL.path))
                        result.sessions += native.sessions
                        result.cache.merge(native.cache) { _, new in new }
                        result.loadError =
                            [result.loadError, native.loadError].compactMap { $0 }.joined(separator: "\n")
                            .nilIfBlank
                        result.coverage.merge(native.coverage)
                    }
                    let observedRoots = result.coverage.observedRoots
                    availableRoots.withLock { $0.formUnion(observedRoots) }
                    if !nativeRoots.isEmpty { result.sessions.sort(by: SessionScanner.isNewer) }
                    return result
                }.value
            }
        )
    }

    init(
        root: URL,
        timing: SessionStoreTiming,
        nativeRoots: [(CLIProvider, URL)] = [],
        scanOperation: @escaping ScanOperation
    ) {
        self.root = root
        self.timing = timing
        self.scanOperation = scanOperation
        self.nativeRoots = nativeRoots
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
        refreshWatcher()
        startWatcherRetryLoop()
        Task { await self.scan(ignoringCache: false) }
    }

    /// Stops watching. Safe to call when not started.
    public func stop() {
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
        debounceTask?.cancel()
        debounceTask = nil
        firstPendingEvent = nil
        refreshWatcher()
        await scan(ignoringCache: true)
        refreshWatcher()
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
    func scan(ignoringCache: Bool) async {
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
        let snapshot = cache
        let result = await scanOperation(root, snapshot, ignoringCache)

        guard capturedForceEpoch == forceEpoch else { return }
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
            searchKeys = sessions.map(SessionScanner.SearchKey.init)
        }
        if loadError != result.loadError {
            loadError = result.loadError
        }
        let notice = nextCoverage.notices.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n").nilIfBlank
        if historyNotice != notice { historyNotice = notice }
        let canPrune = nextCoverage.uncertainRoots.isEmpty && nextCoverage.notices.isEmpty && result.loadError == nil
        if canPruneMissingProjects != canPrune { canPruneMissingProjects = canPrune }
        refreshWatcher()
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
