import Foundation

/// The open-tab list persisted across launches.
///
/// The session identity, model and effort are stored. Tabs are always reopened in `.resume`
/// mode so a launch never creates a new conversation on disk.
public struct OpenTabsSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var sessionID: String
        public var provider: CLIProvider
        public var cwd: String
        /// The tab's model and reasoning effort. Empty means the CLI default.
        /// Nil only in older snapshots; restore then uses Settings.
        public var model: String?
        public var effort: String?
        /// Sigil task identity, separate from the provider's resume reference.
        /// Nil in legacy snapshots; does not make an unknown native ID resumable.
        public var taskID: String?

        public init(
            sessionID: String, cwd: String, model: String? = nil, effort: String? = nil,
            provider: CLIProvider = .grokBuild, taskID: String? = nil
        ) {
            self.sessionID = sessionID
            self.provider = provider
            self.cwd = cwd
            self.model = model
            self.effort = effort
            self.taskID = taskID
        }

        private enum CodingKeys: String, CodingKey { case sessionID, cwd, model, effort, provider, taskID }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try values.decode(String.self, forKey: .sessionID)
            cwd = try values.decode(String.self, forKey: .cwd)
            model = try values.decodeIfPresent(String.self, forKey: .model)
            effort = try values.decodeIfPresent(String.self, forKey: .effort)
            taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
            provider = try values.decodeIfPresent(CLIProvider.self, forKey: .provider) ?? .grokBuild
        }
    }

    public var tabs: [Entry]
    public var selectedSessionID: String?
    /// The selected tab's working directory. Older snapshots do not contain
    /// this field and continue to fall back to ID-only selection.
    public var selectedCWD: String?
    public var selectedProvider: CLIProvider?

    public init(
        tabs: [Entry], selectedSessionID: String?, selectedCWD: String? = nil, selectedProvider: CLIProvider? = nil
    ) {
        self.tabs = tabs
        self.selectedSessionID = selectedSessionID
        self.selectedCWD = selectedCWD
        self.selectedProvider = selectedProvider
    }

    public func encode() -> Data? {
        try? JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) -> OpenTabsSnapshot? {
        try? JSONDecoder().decode(OpenTabsSnapshot.self, from: data)
    }
}
