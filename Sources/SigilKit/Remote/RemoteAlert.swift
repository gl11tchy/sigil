import Foundation

/// What a push notification says, sealed with the phone's device key so the
/// relay and Apple carry only ciphertext. The phone's notification extension
/// opens it and shows the title and body.
public struct RemoteAlert: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// A turn ended and the session waits for the next message.
        case finished
        /// The session shows an approval question.
        case asking
        /// The session's process exited.
        case ended
        case failed
        case stopped
        /// Terminal text suggests an interaction, but cannot authorize one.
        case attention
    }

    public var kind: Kind
    public var tabID: String
    public var title: String
    public var body: String
    public var id: String
    public var issuedAt: Int

    /// The sealing direction, distinct from replies so a reply can never pass as an alert.
    public static let direction = "push"

    public init(kind: Kind, tabID: String, title: String, body: String, now: Date = Date()) {
        self.kind = kind
        self.tabID = tabID
        self.title = String(title.prefix(96))
        self.body = String(body.prefix(200))
        self.id = UUID().uuidString.lowercased()
        self.issuedAt = Int(now.timeIntervalSince1970)
    }
}

/// The status a Live Activity shows; the relay forwards exactly these keys.
public struct RemoteActivityState: Codable, Sendable, Equatable {
    public var status: String
    /// Seconds since 1970 when the current status began.
    public var since: Int
    public var asking: Bool

    public init(status: String, since: Int, asking: Bool) {
        self.status = status
        self.since = since
        self.asking = asking
    }
}

/// Decides, from one tab's changes, which alert and which activity update to
/// send. Pure, so the table of transitions is a test.
public struct RemoteAlertPlanner: Sendable, Equatable {
    public struct Snapshot: Sendable, Equatable {
        public var status: String
        public var since: Int
        public var question: String?
        public var title: String
        public var interactionID: String?
        public var verified: Bool

        public init(
            status: String, since: Int, question: String?, title: String,
            interactionID: String? = nil, verified: Bool = false
        ) {
            self.status = status
            self.since = since
            self.question = question
            self.title = title
            self.interactionID = interactionID
            self.verified = verified
        }
    }

    public struct Plan: Sendable, Equatable {
        public var alert: RemoteAlert?
        public var activity: RemoteActivityState?
        /// True when the activity should end: the session is gone.
        public var ends: Bool
    }

    private var last: [String: Snapshot] = [:]

    public init() {}

    /// The first sighting of a tab sets its baseline and sends nothing.
    public mutating func plan(tabID: String, _ now: Snapshot) -> Plan {
        defer { last[tabID] = now }
        guard let before = last[tabID] else { return Plan(alert: nil, activity: nil, ends: false) }
        var alert: RemoteAlert?
        if before.status == "working", now.status == "idle" {
            alert = RemoteAlert(kind: .finished, tabID: tabID, title: now.title, body: "Finished and waiting for you.")
        } else if before.status != "exited", now.status == "exited" {
            alert = RemoteAlert(kind: .ended, tabID: tabID, title: now.title, body: "The session ended.")
        } else if before.status != "failed", now.status == "failed" {
            alert = RemoteAlert(
                kind: .failed, tabID: tabID, title: now.title, body: "The session failed. Check the terminal.")
        } else if before.status != "interrupted", now.status == "interrupted" {
            alert = RemoteAlert(kind: .stopped, tabID: tabID, title: now.title, body: "The turn stopped.")
        }
        let newInteraction =
            before.question == nil
            || (now.verified && before.interactionID != now.interactionID)
        if newInteraction, let question = now.question {
            alert = RemoteAlert(
                kind: now.verified ? .asking : .attention, tabID: tabID, title: now.title,
                body: now.verified
                    ? (question.isEmpty ? "Needs your approval." : question) : "Check the terminal: \(question)")
        }
        let changed =
            before.status != now.status || (before.question == nil) != (now.question == nil)
            || before.verified != now.verified
        let activity =
            changed
            ? RemoteActivityState(status: now.status, since: now.since, asking: now.verified && now.question != nil)
            : nil
        return Plan(alert: alert, activity: activity, ends: changed && ["exited", "failed"].contains(now.status))
    }

    public mutating func forget(tabID: String) {
        last[tabID] = nil
    }

    /// Membership without constructing the inspection-only knownTabs set.
    public func knows(tabID: String) -> Bool { last[tabID] != nil }

    public var knownTabs: Set<String> { Set(last.keys) }
}
