import Foundation

/// The open-tab list persisted across launches.
///
/// The session identity, model and effort are stored. Tabs are always reopened in `.resume`
/// mode so a launch never creates a new conversation on disk.
public struct OpenTabsSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var sessionID: String
        public var cwd: String
        /// The tab's model and reasoning effort. Empty means the CLI default.
        /// Nil only in older snapshots; restore then uses Settings.
        public var model: String?
        public var effort: String?

        public init(sessionID: String, cwd: String, model: String? = nil, effort: String? = nil) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.model = model
            self.effort = effort
        }
    }

    public var tabs: [Entry]
    public var selectedSessionID: String?
    /// The selected tab's working directory. Older snapshots do not contain
    /// this field and continue to fall back to ID-only selection.
    public var selectedCWD: String?

    public init(tabs: [Entry], selectedSessionID: String?, selectedCWD: String? = nil) {
        self.tabs = tabs
        self.selectedSessionID = selectedSessionID
        self.selectedCWD = selectedCWD
    }

    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> OpenTabsSnapshot? {
        try? JSONDecoder().decode(OpenTabsSnapshot.self, from: data)
    }
}
