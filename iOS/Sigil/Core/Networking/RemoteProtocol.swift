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
    /// New sessions: start in a fresh worktree of the project.
    var worktree: Bool?

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

    /// The wire value, for the on-disk cache.
    var raw: String {
        switch self {
        case .starting: return "starting"
        case .working: return "working"
        case .idle: return "idle"
        case .exited: return "exited"
        case .unknown(let raw): return raw
        }
    }
}

struct RemoteTab: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let status: TabStatus
    /// The CLI's id and name, the folder label, and whether a saved chat backs this tab.
    /// Absent from a Mac that predates session operations.
    let provider: String?
    let providerName: String?
    let folder: String?
    let canArchive: Bool?

    private enum CodingKeys: String, CodingKey { case id, title, status, provider, providerName, folder, canArchive }

    init(
        id: String, title: String, status: TabStatus, provider: String? = nil, providerName: String? = nil,
        folder: String? = nil, canArchive: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.provider = provider
        self.providerName = providerName
        self.folder = folder
        self.canArchive = canArchive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        status = TabStatus(raw: try c.decode(String.self, forKey: .status))
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        providerName = try c.decodeIfPresent(String.self, forKey: .providerName)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        canArchive = try c.decodeIfPresent(Bool.self, forKey: .canArchive)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(status.raw, forKey: .status)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(providerName, forKey: .providerName)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(canArchive, forKey: .canArchive)
    }
}

/// One terminal row as the Mac sends it: buffer-absolute index, text, whether it
/// continues the row before it, and style runs `[start, length, fg, bg, flags]`
/// over Character offsets.
struct RemoteScreenRow: Codable, Equatable {
    let i: Int
    let t: String
    let w: Bool?
    let s: [[Int]]?
}

/// A window of rows, or the rows that changed since the last one.
struct RemoteScreen: Decodable, Equatable {
    /// The tab these rows belong to. Older Macs leave it out; the selection stands in.
    let tab: String?
    let gen: Int
    let alt: Bool?
    let first: Int
    let end: Int
    let rows: [RemoteScreenRow]
    let palette: [String]?
    let fg: String?
    let bg: String?

    static let defaultColor = -1
    static let trueColorBase = 1 << 24
}

/// An approval question the selected session is showing. The Mac reads the
/// screen again when a button is tapped, so a stale prompt cannot type.
struct RemotePrompt: Decodable, Equatable {
    struct Choice: Decodable, Equatable, Identifiable {
        let label: String
        /// What `answer` sends: a digit for a menu row, a letter for a yes/no question.
        let key: String
        var id: String { key }
    }

    enum Style: Equatable {
        case menu
        case yesNo
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "menu": self = .menu
            case "yesNo": self = .yesNo
            default: self = .unknown(raw)
            }
        }
    }

    /// The Mac's digest of the words on screen; an answer names it.
    let id: String?
    let question: String
    let style: Style
    let choices: [Choice]
    let yes: String
    let no: String

    private enum CodingKeys: String, CodingKey { case id, question, style, choices, yes, no }

    init(id: String? = nil, question: String, style: Style, choices: [Choice], yes: String, no: String) {
        self.id = id
        self.question = question
        self.style = style
        self.choices = choices
        self.yes = yes
        self.no = no
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        question = try c.decode(String.self, forKey: .question)
        style = Style(raw: try c.decode(String.self, forKey: .style))
        choices = try c.decode([Choice].self, forKey: .choices)
        yes = try c.decode(String.self, forKey: .yes)
        no = try c.decode(String.self, forKey: .no)
    }
}

struct RemoteState: Decodable, Equatable {
    let tabs: [RemoteTab]
    let selectedTabID: String?
    let terminal: String
    let capabilities: [String]?
    let tabsTruncated: Bool?
    /// Present on `watch`, `rows` and events from a Mac that streams rows.
    let screen: RemoteScreen?
    /// This Mac's name.
    let mac: String?
    /// An approval question on the selected session's screen.
    let prompt: RemotePrompt?

    var canRestart: Bool { capabilities?.contains("restart") == true }
    /// The Mac streams changed rows after `watch`; older Macs are polled for text.
    var streamsScreen: Bool { capabilities?.contains("screen") == true }
    var supportsSessionOps: Bool { capabilities?.contains("sessionOps") == true }

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
        if let screen {
            guard screen.rows.count <= 2_000, screen.end >= screen.first, (screen.palette ?? []).count <= 16,
                (screen.tab ?? "").utf8.count <= 64,
                screen.rows.allSatisfy({ $0.i < screen.end && ($0.s ?? []).allSatisfy { $0.count == 5 } })
            else { throw RemoteCryptoError.invalidMessage }
        }
        if let prompt {
            guard prompt.choices.count <= 9, prompt.question.count <= 300, (prompt.id ?? "").utf8.count <= 64,
                prompt.choices.allSatisfy({ $0.label.count <= 300 && $0.key.count <= 8 })
            else { throw RemoteCryptoError.invalidMessage }
        }
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
    /// True when a new session there can start in a worktree. Absent from older Macs.
    let repository: Bool?
    var id: String { folder }

    init(name: String, folder: String, repository: Bool? = nil) {
        self.name = name
        self.folder = folder
        self.repository = repository
    }
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
    /// The Mac's own default for repositories; absent from older Macs.
    let startsInWorktree: Bool?
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
    /// True on a frame the Mac sent unasked; its sequence is 0.
    let event: Bool?
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
