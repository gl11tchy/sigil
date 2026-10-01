import Foundation

/// A user-chosen conversation name. Identity is session id + working directory,
/// the same key pins and archives use. Stored by Sigil, not in `summary.json`.
public struct ConversationName: Codable, Equatable, Sendable {
    public var sessionID: String
    public var cwd: String
    public var name: String

    public init(sessionID: String, cwd: String, name: String) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
    }
}

/// Overlay a remembered name on the CLI summary. Empty, whitespace, or a
/// submit equal to the CLI title clears it.
public enum ConversationNaming {
    /// `nil` means no override: show the CLI summary again.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func displayedTitle(for session: GrokSession, customName: String?) -> String {
        if let custom = normalized(customName) { return custom }
        return session.title
    }

    public static func name(
        sessionID: String,
        cwd: String,
        in names: [ConversationName],
        samePath: (String, String) -> Bool
    ) -> String? {
        names.first { $0.sessionID == sessionID && samePath($0.cwd, cwd) }
            .flatMap { normalized($0.name) }
    }

    public static func name(
        for session: GrokSession,
        in names: [ConversationName],
        samePath: (String, String) -> Bool
    ) -> String? {
        name(sessionID: session.id, cwd: session.cwd, in: names, samePath: samePath)
    }

    /// Empty, whitespace, or a name equal to the CLI title (`session.title`)
    /// removes the override. A matching submit with no overlay is a no-op.
    /// Otherwise upserts the trimmed name.
    public static func setting(
        _ raw: String,
        on session: GrokSession,
        onto names: [ConversationName],
        samePath: (String, String) -> Bool
    ) -> [ConversationName] {
        setting(
            raw,
            sessionID: session.id,
            cwd: session.cwd,
            cliTitle: session.title,
            onto: names,
            samePath: samePath
        )
    }

    /// Empty, whitespace, or a name equal to `cliTitle` removes the override.
    /// A tab can be named before the store has listed the session.
    public static func setting(
        _ raw: String,
        sessionID: String,
        cwd: String,
        cliTitle: String,
        onto names: [ConversationName],
        samePath: (String, String) -> Bool
    ) -> [ConversationName] {
        guard let submitted = normalized(raw), submitted != cliTitle else {
            return removing(sessionID: sessionID, cwd: cwd, from: names, samePath: samePath)
        }
        var next = removing(sessionID: sessionID, cwd: cwd, from: names, samePath: samePath)
        next.insert(
            ConversationName(sessionID: sessionID, cwd: cwd, name: submitted),
            at: 0
        )
        return next
    }

    public static func removing(
        sessionID: String,
        cwd: String,
        from names: [ConversationName],
        samePath: (String, String) -> Bool
    ) -> [ConversationName] {
        names.filter { !($0.sessionID == sessionID && samePath($0.cwd, cwd)) }
    }

    public static func removing(
        _ session: GrokSession,
        from names: [ConversationName],
        samePath: (String, String) -> Bool
    ) -> [ConversationName] {
        removing(sessionID: session.id, cwd: session.cwd, from: names, samePath: samePath)
    }
}
