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
    /// New sessions: the CLI, and for Grok its model and effort.
    var provider: String?
    var model: String?
    var effort: String?

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

/// What a new session may use, from the Mac's New Session sheet. Macs from
/// before provider choice do not know the `options` action.
struct NewSessionOptions: Decodable, Equatable {
    struct Provider: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let takesModel: Bool
        /// Why the Mac cannot start it now, or nil.
        let problem: String?
    }
    struct Choice: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
    }
    let providers: [Provider]
    let provider: String
    let models: [String]
    let model: String
    let efforts: [Choice]
    let effort: String
    /// Folders a new project can go in.
    let locations: [RemoteProject]
}

/// One page of saved chats, newest first. The Mac pages by offset and may
/// trim a page to fit a frame, so the next offset counts what arrived.
struct ChatList: Equatable {
    private(set) var chats: [RemoteChat] = []
    private(set) var offset = 0
    private(set) var hasMore = false

    static let pageSize = 40

    mutating func apply(_ page: [RemoteChat], from start: Int, truncated: Bool) {
        if start == 0 { chats = [] }
        for chat in page where !chats.contains(where: { $0.id == chat.id && $0.folder == chat.folder }) {
            chats.append(chat)
        }
        offset = start + page.count
        hasMore = !page.isEmpty && (page.count >= Self.pageSize || truncated)
    }
}

/// A folder name the Mac accepts for a new project. Returns the trimmed name, or nil.
enum ProjectName {
    static func validated(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80, !name.hasPrefix("."), !name.contains("/"), !name.contains(":"),
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return name
    }
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
    let options: NewSessionOptions?
    let project: RemoteProject?
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
