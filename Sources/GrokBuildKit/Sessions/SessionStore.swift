import Foundation
import Observation

/// Reads the Grok Build session history off disk and keeps it current.
///
/// IMPLEMENTATION PENDING — this file declares the API the app is written against.
@MainActor
@Observable
public final class SessionStore {

    /// Every known session, newest activity first.
    public private(set) var sessions: [GrokSession] = []
    /// True while the first full scan is still running.
    public private(set) var isLoading: Bool = false
    /// Set when the sessions directory could not be read at all.
    public private(set) var loadError: String?

    private let root: URL

    public init(root: URL = GrokPaths.sessionsRoot) {
        self.root = root
    }

    /// Begins watching the sessions directory and performs the first scan.
    public func start() {}

    /// Stops watching. Safe to call when not started.
    public func stop() {}

    /// Forces a rescan, ignoring any caches.
    public func reload() async {}

    /// Sessions whose title, project name or path match `query`, newest first.
    /// An empty or whitespace-only query returns every session.
    public func search(_ query: String) -> [GrokSession] {
        sessions
    }

    /// Sessions grouped by working directory, each group newest first,
    /// groups ordered by their most recent session.
    public func groupedByProject(matching query: String = "") -> [(cwd: String, sessions: [GrokSession])] {
        []
    }
}
