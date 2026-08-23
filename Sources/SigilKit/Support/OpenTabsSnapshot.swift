import Foundation

/// The open-tab list persisted across launches.
///
/// Only the session identity is stored. Tabs are always reopened in `.resume`
/// mode so a launch never creates a new conversation on disk.
public struct OpenTabsSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var sessionID: String
        public var cwd: String

        public init(sessionID: String, cwd: String) {
            self.sessionID = sessionID
            self.cwd = cwd
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
