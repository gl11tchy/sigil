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
    }

    public var kind: Kind
    public var tabID: String
    public var title: String
    public var body: String

    /// The sealing direction, distinct from replies so a reply can never pass as an alert.
    public static let direction = "push"

    public init(kind: Kind, tabID: String, title: String, body: String) {
        self.kind = kind
        self.tabID = tabID
        self.title = String(title.prefix(96))
        self.body = String(body.prefix(200))
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

        public init(status: String, since: Int, question: String?, title: String) {
            self.status = status
            self.since = since
            self.question = question
            self.title = title
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
        }
        if before.question == nil, let question = now.question {
            alert = RemoteAlert(
                kind: .asking, tabID: tabID, title: now.title,
                body: question.isEmpty ? "Needs your approval." : question)
        }
        let changed = before.status != now.status || (before.question == nil) != (now.question == nil)
        let activity =
            changed
            ? RemoteActivityState(status: now.status, since: now.since, asking: now.question != nil) : nil
        return Plan(alert: alert, activity: activity, ends: changed && now.status == "exited")
    }

    public mutating func forget(tabID: String) {
        last[tabID] = nil
    }

    public var knownTabs: Set<String> { Set(last.keys) }
}
