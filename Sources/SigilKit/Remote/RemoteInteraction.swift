import Foundation

/// Owns the lifetime of one tab's remote interaction. Terminal revisions are
/// deliberately conservative: any output can replace an identical-looking menu.
/// A redraw may invalidate a harmless tap; it must never validate a stale one.
@MainActor
public final class RemoteInteraction {
    public private(set) var pending: RemotePrompt?
    private var revision: UInt64?
    private var sessionID: String?
    private var contentID: String?
    private var consumed = false

    public init() {}

    public func observeTerminal(
        sessionID: String, revision: UInt64, afterInput: Bool, prompt: RemotePrompt?
    ) -> RemotePrompt? {
        guard !afterInput, let prompt else {
            invalidate()
            return nil
        }
        if self.revision == revision, self.sessionID == sessionID, contentID == prompt.contentID {
            return consumed ? nil : pending
        }
        self.revision = revision
        self.sessionID = sessionID
        contentID = prompt.contentID
        consumed = false
        var pending = prompt
        pending.id = UUID().uuidString.lowercased()
        pending.sessionID = sessionID
        // Screen text cannot distinguish provider UI from ordinary output, prove
        // that an operation is still pending, or acknowledge provider acceptance.
        pending.verified = false
        self.pending = pending
        return pending
    }

    public func invalidate() {
        pending = nil
        revision = nil
        sessionID = nil
        contentID = nil
        consumed = true
    }

    /// Main-actor validation and consumption happen without suspension before
    /// dispatch. No current terminal adapter supplies verified approval events.
    /// Legacy clients sending `answer` therefore fail closed rather than receive
    /// terminal typing disguised as an operation-bound approval.
    public func consume(id: String, sessionID: String, key: String) -> RemotePrompt? {
        guard !consumed, let pending, pending.verified == true,
            pending.id == id, pending.sessionID == sessionID, pending.keys.contains(key)
        else { return nil }
        consumed = true
        self.pending = nil
        return pending
    }
}
