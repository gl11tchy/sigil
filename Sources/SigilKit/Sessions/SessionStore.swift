import Foundation
import Observation

/// Reads the Grok Build session history off disk and keeps it current.
@MainActor
@Observable
public final class SessionStore {

    /// Every known session, newest activity first.
    public private(set) var sessions: [GrokSession] = []
    /// True while a scan is in flight.
    public private(set) var isLoading: Bool = false
    /// Set when the sessions directory could not be read at all.
    public private(set) var loadError: String?

    private let root: URL
    @ObservationIgnored private var cache: [String: SessionCacheEntry] = [:]
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inflight = 0
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private let watcher = SessionDirectoryWatcher()
    @ObservationIgnored private let eventContinuation: AsyncStream<Void>.Continuation
    @ObservationIgnored private var eventPump: Task<Void, Never>?

    public init(root: URL = GrokPaths.sessionsRoot) {
        self.root = root
        let stream: AsyncStream<Void>
        let continuation: AsyncStream<Void>.Continuation
        (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.eventContinuation = continuation
        self.eventPump = Task { [weak self] in
            for await _ in stream {
                self?.scheduleDebouncedScan()
            }
        }
    }

    deinit {
        eventContinuation.finish()
        watcher.stop()
    }

    /// Begins watching the sessions directory and performs the first scan.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        let continuation = eventContinuation
        watcher.start(path: root.path, latency: 1.0) {
            continuation.yield(())
        }
        Task { await self.scan(ignoringCache: false) }
    }

    /// Stops watching. Safe to call when not started.
    public func stop() {
        watcher.stop()
        debounceTask?.cancel()
        debounceTask = nil
        isStarted = false
    }

    /// Forces a rescan, ignoring any caches.
    public func reload() async {
        debounceTask?.cancel()
        debounceTask = nil
        await scan(ignoringCache: true)
    }

    /// Sessions whose title, project name or path match `query`, newest first.
    /// An empty or whitespace-only query returns every session.
    public func search(_ query: String) -> [GrokSession] {
        sessions.filter { SessionScanner.matches($0, query: query) }
    }

    /// Sessions grouped by working directory, each group newest first,
    /// groups ordered by their most recent session.
    public func groupedByProject(matching query: String = "") -> [(
        cwd: String, sessions: [GrokSession]
    )] {
        SessionScanner.grouped(search(query))
    }

    /// Walks `root` off the main actor. Cache hits skip `summary.json` I/O.
    func scan(ignoringCache: Bool) async {
        generation += 1
        let gen = generation
        inflight += 1
        isLoading = true
        defer {
            inflight -= 1
            if inflight == 0 { isLoading = false }
        }

        let root = self.root
        let snapshot = ignoringCache ? [:] : cache
        let result = await Task.detached(priority: .userInitiated) {
            SessionScanner.scan(root: root, cache: snapshot)
        }.value

        guard gen == generation else { return }
        cache = result.cache
        sessions = result.sessions
        loadError = result.loadError
    }

    private func scheduleDebouncedScan() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await self?.scan(ignoringCache: false)
        }
    }
}
