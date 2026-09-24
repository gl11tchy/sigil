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

/// What the phone may choose when it starts a session, as the Mac's New Session sheet offers.
struct RemoteNewSessionOptions: Codable, Sendable {
    struct Provider: Codable, Sendable {
        var id: String
        var name: String
        /// Only these take a model and an effort.
        var takesModel: Bool
        /// Why Sigil cannot start it now, or nil.
        var problem: String?
    }
    struct Choice: Codable, Sendable {
        var id: String
        var name: String
    }
    var providers: [Provider]
    var provider: String
    var models: [String]
    var model: String
    var efforts: [Choice]
    var effort: String
    /// Folders a new project can go in.
    var locations: [RemoteProject]
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
    var chatsTruncated = false
    var projectsTruncated = false
    var options: RemoteNewSessionOptions?
    var project: RemoteProject?
}

@MainActor
enum RemoteCommands {
    static var uploads = RemoteUpload.Inbox()

    /// Where phone sessions make worktrees. Tests point it at a scratch folder.
    static var worktreeRoot = SigilWorktree.root

    static func execute(_ request: RemoteRequest, model: AppModel) async -> RemoteReply {
        uploads.prune()
        var reply = RemoteReply(challenge: request.challenge, sequence: request.sequence)
        let tab = model.tabs.first { $0.id.uuidString == request.tabID }
        switch request.action {
        case "pair", "state": break
        case "select":
            guard let tab else { return failure(request, "This tab is closed.") }
            model.select(tab.id)
        case "new":
            // A phone that names no provider gets the one the Mac's New Session sheet opens on.
            let provider: CLIProvider
            if let raw = request.provider {
                guard let chosen = CLIProvider(rawValue: raw) else {
                    return failure(request, "Update Sigil on your Mac to use that provider.")
                }
                provider = chosen
            } else {
                provider = model.settings.defaultProvider
            }
            if let problem = startProblem(provider, model: model) { return failure(request, problem) }
            // Other CLIs do not take Grok's model or effort flags.
            let takesModel = NewSessionLaunch.showsModelAndEffort(provider)
            let chosenModel = takesModel ? request.model.map(GrokModelCatalog.normalized) : ""
            let chosenEffort = takesModel ? request.effort : ""
            guard chosenModel.map(isModelName) ?? true, chosenEffort.map(AppSettings.effortOptions.contains) ?? true
            else { return failure(request, "Choose a model and effort from the list.") }
            let named = request.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let project: URL
            if named.isEmpty {
                project = model.newSessionDirectory
            } else {
                guard
                    let record = projectRecords(model).first(where: {
                        GrokPaths.canonicalPath($0.folder) == GrokPaths.canonicalPath(named)
                    })
                else { return failure(request, "Choose a project folder.") }
                project = URL(fileURLWithPath: record.folder)
            }
            guard AppModel.isUsableDirectory(project)
            else { return failure(request, "Restore the folder on your Mac, then try again.") }
            // As the Mac's New Session sheet does: a git repository gets a new worktree when Settings says so.
            var start = project
            if model.settings.startsInWorktree, SigilWorktree.isInRepository(project) {
                do {
                    start = try await SigilWorktree.create(for: project, root: worktreeRoot) ?? project
                } catch {
                    let detail = error.localizedDescription.split(whereSeparator: \.isNewline).first ?? ""
                    return failure(request, bounded("Could not create a worktree. \(detail)", bytes: 240))
                }
            }
            let remembered = model.settings.defaultDirectory
            let focused = model.settings.focusedProjectPath
            guard model.newTab(in: start, model: chosenModel, effort: chosenEffort, provider: provider) != nil
            else { return failure(request, "Could not start a session. Check Sigil on your Mac.") }
            if !named.isEmpty {
                if model.settings.defaultDirectory != remembered {
                    model.settings.defaultDirectory = remembered
                }
                if model.settings.focusedProjectPath != focused {
                    model.settings.focusedProjectPath = focused
                }
            }
        case "options":
            reply.options = newSessionOptions(model)
        case "createProject":
            let name = (request.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isFolderName(name) else {
                return failure(request, "Name the folder without slashes, colons or a leading dot.")
            }
            guard let parent = request.text,
                let location = projectLocations(model).first(where: {
                    GrokPaths.canonicalPath($0.folder) == GrokPaths.canonicalPath(parent)
                })
            else { return failure(request, "Choose where the project goes.") }
            let folder = URL(fileURLWithPath: location.folder).appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
                // An existing folder of that name becomes the project.
                guard isDirectory.boolValue else { return failure(request, "A file with that name is already there.") }
            } else {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                } catch {
                    return failure(request, "Could not create that folder on your Mac.")
                }
            }
            model.addProject(folder)
            reply.project = RemoteProject(name: bounded(name, bytes: 96), folder: folder.path)
        case "chats":
            let query = request.text ?? ""
            var chats = savedChats(model, query: query)
            // Recent chats leave out open tabs: the phone lists those above them.
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chats.removeAll { model.isOpen($0) }
            }
            reply.chats = page(chats, offset: request.index ?? 0).compactMap { chatRecord($0, model: model) }
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
            // AppModel reports these with a modal alert, which would block this loop.
            if !model.isOpen(session) {
                guard model.settings.executableExists
                else { return failure(request, "Restore the Grok CLI on your Mac, then try again.") }
                guard AppModel.isUsableDirectory(URL(fileURLWithPath: session.cwd))
                else { return failure(request, "Restore the folder on your Mac, then try again.") }
            }
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
            guard AppModel.isUsableDirectory(tab.workingDirectory)
            else { return failure(request, "Restore the folder on your Mac, then try again.") }
            guard tab.spec.provider != .grokBuild || model.settings.executableExists
            else { return failure(request, "Restore the Grok CLI on your Mac, then try again.") }
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

    /// The sidebar's folders: grouped from chats, plus added folders with no chat yet.
    private static func projectRecords(_ model: AppModel) -> [RemoteProject] {
        SidebarOrganization.merging(
            added: model.settings.addedProjects, into: projectSessions(model),
            canonicalPath: GrokPaths.canonicalPath
        ).compactMap { project in
            guard project.cwd.utf8.count <= 4_000, !project.cwd.isEmpty else { return nil }
            return RemoteProject(name: bounded(project.name, bytes: 96), folder: project.cwd)
        }
    }

    /// Where a new project may go: the folders holding the listed projects, then home.
    static func projectLocations(_ model: AppModel) -> [RemoteProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var result: [RemoteProject] = []
        func add(_ path: String) {
            guard !path.isEmpty, path != "/", path.utf8.count <= 4_000,
                seen.insert(GrokPaths.canonicalPath(path)).inserted,
                model.settings.showWorktreeSessions || !isEphemeral(path: path),
                AppModel.isUsableDirectory(URL(fileURLWithPath: path))
            else { return }
            let shown = path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
            result.append(RemoteProject(name: shown, folder: path))
        }
        for project in projectRecords(model) where result.count < 7 {
            add(URL(fileURLWithPath: project.folder).deletingLastPathComponent().path)
        }
        add(home)
        return result
    }

    /// Grok's model list, read by `refreshModels` before an options reply.
    /// The CLI can take seconds to answer, so it never runs inside `execute`.
    static var listedModels: (executable: String, models: [String])?

    static func refreshModels(model: AppModel) async {
        let path = model.settings.executablePath
        guard let found = await GrokModelCatalog.menuModels(executable: model.settings.executableURL) else { return }
        listedModels = (path, found)
    }

    static func newSessionOptions(_ model: AppModel) -> RemoteNewSessionOptions {
        let settings = model.settings
        let listed =
            listedModels.flatMap { $0.executable == settings.executablePath ? $0.models : nil }
            ?? GrokModelCatalog.fallback
        let saved = GrokModelCatalog.normalized(settings.model)
        return RemoteNewSessionOptions(
            providers: CLIProvider.allCases.map {
                .init(
                    id: $0.rawValue, name: $0.name, takesModel: NewSessionLaunch.showsModelAndEffort($0),
                    problem: startProblem($0, model: model))
            },
            provider: settings.defaultProvider.rawValue,
            models: Array(GrokModelCatalog.choices(listed: listed, saved: saved).filter(isModelName).prefix(100)),
            model: isModelName(saved) ? saved : "",
            efforts: AppSettings.effortOptions.map { .init(id: $0, name: AppSettings.effortLabel($0)) },
            effort: settings.effort,
            locations: projectLocations(model))
    }

    /// Why `provider` cannot start now. Checked here because AppModel reports
    /// these with a modal alert, which would block this loop.
    static func startProblem(_ provider: CLIProvider, model: AppModel) -> String? {
        if provider == .grokBuild, !model.settings.executableExists {
            return "Restore the Grok CLI on your Mac, then try again."
        }
        if !model.hasSignIn(provider) {
            return "Set up \(provider.name) sign-in in Sigil on your Mac, then try again."
        }
        return nil
    }

    /// Empty picks the CLI default. Anything else is one argument, never a flag.
    static func isModelName(_ name: String) -> Bool {
        name.isEmpty || (name.utf8.count <= 64 && !name.hasPrefix("-") && !name.contains(where: \.isWhitespace))
    }

    /// One new folder name: no path separators, no hidden or relative names.
    static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 80 && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains(":") && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func page<T>(_ items: [T], offset: Int) -> [T] {
        let start = max(0, min(offset, items.count))
        return Array(items.dropFirst(start).prefix(pageSize))
    }

    /// Plaintext has to stay under the sealed-frame cap. Shrink the terminal
    /// before shortening a list, so a large snapshot cannot wipe real matches.
    static func fitting(_ reply: RemoteReply) -> RemoteReply {
        var reply = reply
        func fits() -> Bool { encodedCount(reply) <= 48_000 }
        if fits() { return reply }
        reply.earlier = reply.earlier.map { boundedSuffix($0, bytes: 4_000) }
        if fits() { return reply }
        reply.earlier = nil
        if fits() { return reply }
        reply = shrinkTerminal(reply, bytes: 4_000)
        if fits() { return reply }
        reply = shrinkTerminal(reply, bytes: 0)
        if fits() { return reply }
        while !fits(), let chats = reply.chats, !chats.isEmpty {
            reply.chats = Array(chats.dropLast())
            reply.chatsTruncated = true
        }
        while !fits(), let projects = reply.projects, !projects.isEmpty {
            reply.projects = Array(projects.dropLast())
            reply.projectsTruncated = true
        }
        if !fits() {
            if reply.chats == nil, reply.projects == nil, reply.earlier == nil {
                reply.state = nil
            } else {
                reply.ok = false
                reply.error = "That list is too long."
            }
        }
        return reply
    }

    private static func shrinkTerminal(_ reply: RemoteReply, bytes: Int) -> RemoteReply {
        guard let state = reply.state else { return reply }
        var reply = reply
        reply.state = RemoteState(
            tabs: state.tabs,
            selectedTabID: state.selectedTabID,
            terminal: bytes == 0 ? "" : boundedSuffix(state.terminal, bytes: bytes),
            capabilities: state.capabilities,
            tabsTruncated: state.tabsTruncated
        )
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
