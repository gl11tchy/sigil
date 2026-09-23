import Foundation
import Observation

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

    private let root: URL
    @ObservationIgnored private var cache: [String: SessionCacheEntry] = [:]
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
    @ObservationIgnored private let watcher = SessionDirectoryWatcher()
    @ObservationIgnored private var watchedPath: String?
    @ObservationIgnored private var watcherRetryTask: Task<Void, Never>?
    @ObservationIgnored private let eventContinuation: AsyncStream<Bool>.Continuation
    @ObservationIgnored private var eventPump: Task<Void, Never>?
    @ObservationIgnored private let timing: SessionStoreTiming
    @ObservationIgnored private let scanOperation: ScanOperation

    public convenience init(root: URL = GrokPaths.sessionsRoot) {
        self.init(
            root: root,
            timing: SessionStoreTiming(),
            scanOperation: { root, cache, ignoringCache in
                await Task.detached(priority: .userInitiated) {
                    SessionScanner.scan(
                        root: root,
                        cache: cache,
                        ignoringCache: ignoringCache
                    )
                }.value
            }
        )
    }

    convenience init(root: URL, timing: SessionStoreTiming) {
        self.init(
            root: root,
            timing: timing,
            scanOperation: { root, cache, ignoringCache in
                await Task.detached(priority: .userInitiated) {
                    SessionScanner.scan(
                        root: root,
                        cache: cache,
                        ignoringCache: ignoringCache
                    )
                }.value
            }
        )
    }

    init(
        root: URL,
        timing: SessionStoreTiming,
        scanOperation: @escaping ScanOperation
    ) {
        self.root = root
        self.timing = timing
        self.scanOperation = scanOperation
        let stream: AsyncStream<Bool>
        let continuation: AsyncStream<Bool>.Continuation
        (stream, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(16)
        )
        self.eventContinuation = continuation
        self.eventPump = Task { [weak self] in
            for await requiresRestart in stream {
                guard let self, self.isStarted else { continue }
                if requiresRestart { self.watchedPath = nil }
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
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sessions
        }
        return sessions.compactMap { session -> (GrokSession, SessionScanner.SearchRank)? in
            guard
                let rank = SessionScanner.searchRank(
                    session,
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

    /// Groups `search` results by working directory, in that same order.
    public func groupedByProject(matching query: String = "") -> [(
        cwd: String, sessions: [GrokSession]
    )] {
        SessionScanner.grouped(search(query))
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
        if sessions != result.sessions {
            sessions = result.sessions
        }
        if loadError != result.loadError {
            loadError = result.loadError
        }
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

    private func refreshWatcher() {
        guard isStarted else { return }
        guard let desiredPath = nearestExistingDirectory(to: root) else {
            if watchedPath != nil {
                watcher.stop()
                watchedPath = nil
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

    private func nearestExistingDirectory(to requestedRoot: URL) -> String? {
        let fm = FileManager.default
        var candidate = requestedRoot.standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
    }
}
