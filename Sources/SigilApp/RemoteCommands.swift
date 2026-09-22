import Foundation
import SigilKit

struct RemoteState: Codable, Sendable {
    struct Tab: Codable, Sendable {
        let id: String
        let title: String
        let status: String
    }
    let tabs: [Tab]
    let selectedTabID: String?
    let terminal: String
    var capabilities: [String] = ["restart"]
    var tabsTruncated = false
}

struct RemoteChat: Codable, Sendable {
    var id: String
    var title: String
    var folder: String
}

struct RemoteProject: Codable, Sendable {
    var name: String
    var folder: String
}

struct RemoteReply: Codable, Sendable {
    let challenge: String
    let sequence: Int
    var ok = true
    var error: String?
    var state: RemoteState?
    var ticket: String?
    var restartedTabID: String?
    var chats: [RemoteChat]?
    var projects: [RemoteProject]?
    var earlier: String?
}

@MainActor
enum RemoteCommands {
    static var uploads = RemoteUpload.Inbox()

    static func execute(_ request: RemoteRequest, model: AppModel) -> RemoteReply {
        uploads.prune()
        var reply = RemoteReply(challenge: request.challenge, sequence: request.sequence)
        let tab = model.tabs.first { $0.id.uuidString == request.tabID }
        switch request.action {
        case "pair", "state": break
        case "select":
            guard let tab else { return failure(request, "This tab is closed.") }
            model.select(tab.id)
        case "new":
            guard model.settings.executableExists else {
                return failure(request, "Could not start a session. Check Sigil on your Mac.")
            }
            if let folder = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
                guard
                    let project = projectSessions(model).first(where: {
                        GrokPaths.canonicalPath($0.cwd) == GrokPaths.canonicalPath(folder)
                    })
                else { return failure(request, "Choose a project folder.") }
                let remembered = model.settings.defaultDirectory
                let focused = model.settings.focusedProjectPath
                guard model.newTab(in: URL(fileURLWithPath: project.cwd)) != nil else {
                    return failure(request, "Could not start a session. Check Sigil on your Mac.")
                }
                if model.settings.defaultDirectory != remembered {
                    model.settings.defaultDirectory = remembered
                }
                if model.settings.focusedProjectPath != focused {
                    model.settings.focusedProjectPath = focused
                }
            } else if model.newTab(in: model.newSessionDirectory) == nil {
                return failure(request, "Could not start a session. Check Sigil on your Mac.")
            }
        case "chats":
            reply.chats = page(savedChats(model, query: request.text ?? ""), offset: request.index ?? 0).compactMap {
                chatRecord($0, model: model)
            }
        case "projects":
            reply.projects = page(projectRecords(model), offset: request.index ?? 0)
        case "open":
            guard let id = request.name, let folder = request.text,
                !id.isEmpty, id.utf8.count <= 80, !folder.isEmpty
            else { return failure(request, "That chat is not available.") }
            let wanted = GrokPaths.canonicalPath(folder)
            guard
                let session = model.store.sessions.first(where: {
                    $0.id == id && GrokPaths.canonicalPath($0.cwd) == wanted
                })
            else { return failure(request, "That chat is not available.") }
            model.open(session)
            let opened = model.tabs.contains {
                $0.sessionID == session.id
                    && GrokPaths.canonicalPath($0.workingDirectory.path) == GrokPaths.canonicalPath(session.cwd)
            }
            guard opened else {
                return failure(request, "Could not open that chat. Check Sigil on your Mac.")
            }
        case "earlier":
            guard let tab else { return failure(request, "This tab is closed.") }
            let anchor = request.text ?? ""
            let loaded = request.index ?? 0
            let slice =
                anchor.isEmpty || loaded <= 0
                ? ""
                : tab.controller.remoteEarlierSlice(
                    before: anchor, endAnchor: request.name ?? "", loadedCharacters: loaded)
            reply.earlier = boundedSuffix(slice, bytes: 12_000)
        case "restart":
            guard let tab, let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else {
                return failure(request, "This tab is closed.")
            }
            guard case .exited = tab.activity, !tab.controller.isRunning else {
                return failure(request, "Only ended sessions can be restarted.")
            }
            guard model.settings.executableExists,
                (try? tab.workingDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return failure(request, "Restore the folder or Grok CLI on your Mac, then try again.") }
            model.restartTab(id: tab.id)
            guard index < model.tabs.count, model.tabs[index].id != tab.id else {
                return failure(request, "Could not restart this session. Check Sigil on your Mac.")
            }
            reply.restartedTabID = model.tabs[index].id.uuidString
        case "input":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 8_192,
                text.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
                })
            else { return failure(request, "Enter plain text, up to 8 KB.") }
            guard tab.controller.pasteRemoteText(text) else {
                return failure(request, "This prompt does not support multiline paste.")
            }
        case "key":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let key = request.text, tab.controller.sendRemoteKey(key) else {
                return failure(request, "Unknown key.")
            }
        case "file":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let transfer = request.transfer, let name = request.name, let index = request.index,
                let count = request.count, let text = request.text
            else { return failure(request, "That file could not be sent.") }
            do {
                if let url = try uploads.receive(
                    transfer: transfer, name: name, index: index, count: count, base64: text,
                    directory: TerminalDrop.cacheDirectory())
                {
                    let paste = TerminalDrop.pasteText(for: [url.path]) + " "
                    guard tab.controller.pasteRemoteText(paste) else {
                        return failure(request, "This prompt does not support file paste.")
                    }
                }
            } catch TerminalDrop.Error.tooLarge {
                return failure(request, "Keep files under 4 MB.")
            } catch {
                return failure(request, "That file could not be sent.")
            }
        default: return failure(request, "Unknown action.")
        }
        reply.state = snapshot(model)
        return fitting(reply)
    }

    private static let pageSize = 40

    private static func savedChats(_ model: AppModel, query: String) -> [GrokSession] {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        return model.store.search(trimmed) { model.title(for: $0) }.filter { isListable($0, model: model) }
    }

    /// Archived chats stay searchable. Project folders follow the sidebar and omit them.
    private static func projectSessions(_ model: AppModel) -> [SidebarProject] {
        SidebarOrganization.projects(
            from: savedChats(model, query: "").filter { !model.isArchived($0) },
            canonicalPath: GrokPaths.canonicalPath)
    }

    private static func isListable(_ session: GrokSession, model: AppModel) -> Bool {
        if !model.settings.showEmptySessions {
            let named =
                !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || session.messageCount > 2
                || model.hasCustomName(session)
            if !named && !model.isOpen(session) { return false }
        }
        if !model.settings.showWorktreeSessions, isEphemeral(path: session.cwd), !model.isOpen(session) {
            return false
        }
        if !model.settings.showSubagentSessions, session.isSubagent, !model.isOpen(session) {
            return false
        }
        return true
    }

    private static func chatRecord(_ session: GrokSession, model: AppModel) -> RemoteChat? {
        let folder = session.cwd
        guard !session.id.isEmpty, session.id.utf8.count <= 80, folder.utf8.count <= 4_000 else { return nil }
        return RemoteChat(id: session.id, title: bounded(model.title(for: session), bytes: 96), folder: folder)
    }

    private static func projectRecords(_ model: AppModel) -> [RemoteProject] {
        projectSessions(model).compactMap { project in
            guard project.cwd.utf8.count <= 4_000, !project.cwd.isEmpty else { return nil }
            return RemoteProject(name: bounded(project.name, bytes: 96), folder: project.cwd)
        }
    }

    private static func page<T>(_ items: [T], offset: Int) -> [T] {
        let start = max(0, min(offset, items.count))
        return Array(items.dropFirst(start).prefix(pageSize))
    }

    /// Plaintext has to stay under the sealed-frame cap. Drop the extra list
    /// before dropping the live tail.
    private static func fitting(_ reply: RemoteReply) -> RemoteReply {
        var reply = reply
        if encodedCount(reply) <= 48_000 { return reply }
        reply.earlier = reply.earlier.map { boundedSuffix($0, bytes: 4_000) }
        if encodedCount(reply) <= 48_000 { return reply }
        reply.earlier = nil
        reply.chats = nil
        reply.projects = nil
        return reply
    }

    private static func encodedCount(_ reply: RemoteReply) -> Int {
        (try? JSONEncoder().encode(reply).count) ?? Int.max
    }

    static func snapshot(_ model: AppModel) -> RemoteState {
        let tabs = model.tabs.map { tab in
            let status = tab.activity.statusName
            return RemoteState.Tab(
                id: tab.id.uuidString, title: bounded(model.title(for: tab), bytes: 96), status: status)
        }
        return RemoteState(
            tabs: visibleTabs(tabs, selectedID: model.selectedTab?.id.uuidString),
            selectedTabID: model.selectedTab?.id.uuidString,
            terminal: boundedSuffix(model.selectedTab?.controller.remoteSnapshot() ?? "", bytes: 12_000),
            tabsTruncated: tabs.count > 100
        )
    }

    static func visibleTabs(_ tabs: [RemoteState.Tab], selectedID: String?) -> [RemoteState.Tab] {
        var visible = Array(tabs.prefix(100))
        if let selectedID, !visible.contains(where: { $0.id == selectedID }),
            let selected = tabs.first(where: { $0.id == selectedID }), !visible.isEmpty
        {
            visible[visible.count - 1] = selected
        }
        return visible
    }

    static func bounded(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        var cut = Array(text.utf8.prefix(bytes))
        while String(bytes: cut, encoding: .utf8) == nil { cut.removeLast() }
        return String(bytes: cut, encoding: .utf8) ?? ""
    }

    static func boundedSuffix(_ text: String, bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        var cut = Array(text.utf8.suffix(bytes))
        while String(bytes: cut, encoding: .utf8) == nil { cut.removeFirst() }
        return String(bytes: cut, encoding: .utf8) ?? ""
    }

    private static func failure(_ request: RemoteRequest, _ message: String) -> RemoteReply {
        RemoteReply(challenge: request.challenge, sequence: request.sequence, ok: false, error: message)
    }
}
