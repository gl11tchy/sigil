import Foundation

/// A command to the Mac. Field names and limits mirror `RemoteRequest` in SigilKit;
/// the Mac drops the whole connection when a field goes over its limit.
struct RemoteRequest: Encodable, Equatable {
    let challenge: String
    let sequence: Int
    let action: String
    var tabID: String?
    var text: String?
    var name: String?
    var index: Int?
    var count: Int?
    var transfer: String?

    static let textLimit = 8_192
    static let fileTextLimit = 48_000
}

/// What the phone may ask for. Keys are the names `sendRemoteKey` understands on the Mac.
enum RemoteKey: String, CaseIterable, Identifiable {
    case escape, tab, up, down, left, right, backspace, enter, interrupt

    var id: String { rawValue }
}

enum TabStatus: Equatable {
    case starting, working, idle, exited
    /// A status this build does not know. Shown as-is, never guessed.
    case unknown(String)

    init(raw: String) {
        switch raw {
        case "starting": self = .starting
        case "working": self = .working
        case "idle": self = .idle
        case "exited": self = .exited
        default: self = .unknown(raw)
        }
    }

    var label: String {
        switch self {
        case .starting: return "Starting…"
        case .working: return "Working"
        case .idle: return "Ready"
        case .exited: return "Ended"
        case .unknown(let raw): return raw.capitalized
        }
    }
}

struct RemoteTab: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let status: TabStatus

    private enum CodingKeys: String, CodingKey { case id, title, status }

    init(id: String, title: String, status: TabStatus) {
        self.id = id
        self.title = title
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = TabStatus(raw: try c.decode(String.self, forKey: .status))
    }
}

struct RemoteState: Decodable, Equatable {
    let tabs: [RemoteTab]
    let selectedTabID: String?
    let terminal: String
    let capabilities: [String]?
    let tabsTruncated: Bool?

    var canRestart: Bool { capabilities?.contains("restart") == true }

    /// Absence from a capped snapshot is not evidence that a tab closed.
    /// Older Macs omit the flag, so a full 100-row list counts as capped.
    var tabListIsComplete: Bool {
        if let tabsTruncated { return !tabsTruncated }
        return tabs.count < 100
    }

    /// The same checks the web companion makes before it trusts a snapshot.
    func validate() throws {
        guard tabs.count <= 100 else { throw RemoteCryptoError.invalidMessage }
        var seen = Set<String>()
        for tab in tabs {
            guard !tab.id.isEmpty, seen.insert(tab.id).inserted else { throw RemoteCryptoError.invalidMessage }
        }
        if let selectedTabID, !seen.contains(selectedTabID) { throw RemoteCryptoError.invalidMessage }
    }
}

struct RemoteChat: Decodable, Equatable, Identifiable {
    let id: String
    let title: String
    let folder: String
}

struct RemoteProject: Decodable, Equatable, Identifiable {
    let name: String
    let folder: String
    var id: String { folder }
}

struct RemoteReply: Decodable {
    let challenge: String
    let sequence: Int
    let ok: Bool?
    let error: String?
    let state: RemoteState?
    let ticket: String?
    let restartedTabID: String?
    let chats: [RemoteChat]?
    let projects: [RemoteProject]?
    let earlier: String?
    let chatsTruncated: Bool?
    let projectsTruncated: Bool?
}

/// The outer, unencrypted envelope the relay forwards.
struct RelayFrame: Decodable {
    let route: String?
    let hello: String?
    let error: String?
    let data: String?
}

struct RouteEnvelope: Encodable {
    let room: String?
    let ticket: String?
}
