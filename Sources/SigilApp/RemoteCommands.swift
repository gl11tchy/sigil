import Foundation
import SigilKit

struct RemoteState: Codable, Sendable {
    struct Tab: Codable, Sendable, Equatable {
        let id: String
        let title: String
        let status: String
        /// The CLI's id and name, and the folder label the Mac's tab shows.
        var provider: String?
        var providerName: String?
        var folder: String?
        /// Only recognized history with the archive capability can be archived.
        var canArchive: Bool?
        var sessionID: String?
        var capabilities: ProviderCapabilities?
        var processRunning: Bool?
        var cwd: String?
    }
    let tabs: [Tab]
    let selectedTabID: String?
    let terminal: String
    var capabilities: [String] = ["restart", "screen", "sessionOps", "eventSequence", "approvalContext"]
    var tabsTruncated = false
    /// The selected tab's rows, on `watch`, `rows` and in events. Absent elsewhere.
    var screen: RemoteScreen?
    /// This Mac's name, for a phone paired with more than one.
    var mac: String?
    /// An approval question the selected tab is showing, for the phone's answer buttons.
    var prompt: RemotePrompt?
}

struct RemoteChat: Codable, Sendable {
    var id: String
    var title: String
    var folder: String
    var provider: String?
}

struct RemoteProject: Codable, Sendable {
    var name: String
    var folder: String
    /// True when a new session there can start in a worktree.
    var repository: Bool?
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
    /// The Mac's own default for repositories, so the phone's toggle starts where the Mac would.
    var startsInWorktree: Bool?
}

struct RemoteReply: Codable, Sendable {
    let challenge: String
    let sequence: Int
    var ok = true
    var error: String?
    var state: RemoteState?
    var ticket: String?
    var restartedTabID: String?
    var restartedSession: ProviderSessionReference?
    var chats: [RemoteChat]?
    var projects: [RemoteProject]?
    var earlier: String?
    var chatsTruncated = false
    var projectsTruncated = false
    var options: RemoteNewSessionOptions?
    var project: RemoteProject?
    /// True on a frame the Mac sent unasked. Its sequence is 0.
    var event: Bool?
    /// Strictly rising across watches within one authenticated connection.
    var eventSequence: Int?
    var clientNonce: String?
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
        case "watch":
            // The stream itself is started by RemoteControl; the reply carries the full window.
            reply.state = snapshot(model, screen: model.selectedTab?.controller.remoteScreenWindow())
            return fitting(reply)
        case "rows":
            guard let tab else { return failure(request, "This tab is closed.") }
            guard let before = request.index, before > 0 else { return failure(request, "Nothing earlier.") }
            let window = tab.controller.remoteScreenWindow(maxRows: 0, maxCharacters: 0)
            let older = tab.controller.remoteScreenRows(before: before)
            reply.state = snapshot(
                model,
                screen: RemoteScreen(
                    tab: tab.id.uuidString, gen: window.gen, first: window.first, end: window.end, rows: older))
            return fitting(reply)
        case "close":
            guard let tab else { return failure(request, "This tab is closed.") }
            model.closeTab(tab.id)
        case "rename":
            guard let tab else { return failure(request, "This tab is closed.") }
            let name = (request.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.utf8.count <= 80,
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return failure(request, "Keep the name under 80 characters.") }
            model.renameFromRemote(tab, to: name)
        case "archive":
            guard let tab else { return failure(request, "This tab is closed.") }
            guard model.archiveFromRemote(tab) else {
                return failure(request, "Only saved Grok chats can be archived. Close this tab instead.")
            }
        case "new":
            // A phone that names no provider gets the one the Mac's New Session sheet opens on.
            let provider: CLIProvider
            if let raw = request.provider {
                guard let chosen = CLIProvider(rawValue: raw) else {
                    return failure(request, "Update Sigil on your Mac to use that provider.")
                }
                provider = chosen
            } else {
                // An omitted first-run default must be resolved after the
                // complete inventory, rather than snapshotting provisional Grok.
                if model.settings.needsInitialProviderSelection {
                    await model.refreshProviderInstallationsForEntry()
                }
                guard !Task.isCancelled else { return failure(request, "Remote was turned off.") }
                provider = model.settings.defaultProvider
                model.settings.finishInitialProviderSelection()
            }
            // The phone lists Grok's models and efforts only.
            let takesModel = provider == .grokBuild
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
            if let problem = await checkedStartProblem(provider, model: model) { return failure(request, problem) }
            // As the Mac's New Session sheet does: a git repository gets a new worktree when
            // Settings says so. A phone that shows the toggle sends its own answer.
            var start = project
            if request.worktree ?? model.settings.startsInWorktree, SigilWorktree.isInRepository(project) {
                do {
                    start = try await SigilWorktree.create(for: project, root: worktreeRoot) ?? project
                } catch {
                    let detail = error.localizedDescription.split(whereSeparator: \.isNewline).first ?? ""
                    return failure(request, bounded("Could not create a worktree. \(detail)", bytes: 240))
                }
                // Remote was stopped while git ran: start nothing for a phone that is gone.
                guard !Task.isCancelled else { return failure(request, "Remote was turned off.") }
            }
            let remembered = model.settings.defaultDirectory
            let focused = model.settings.focusedProjectPath
            // A provider refresh may have started while the worktree was created.
            if let problem = await checkedStartProblem(provider, model: model) { return failure(request, problem) }
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
            await model.refreshProviderInstallationsForEntry()
            guard !Task.isCancelled else { return failure(request, "Remote was turned off.") }
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
                if let problem = await checkedStartProblem(session.provider, model: model) {
                    return failure(request, problem)
                }
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
            guard let tab else {
                return failure(request, "This tab is closed.")
            }
            guard case .exited = tab.activity, !tab.controller.isRunning else {
                return failure(request, "Only ended sessions can be restarted.")
            }
            guard tab.spec.provider != .codex || tab.sessionReference != nil else {
                return failure(request, "Open this Codex conversation from Chats. Its session ID is not known.")
            }
            guard AppModel.isUsableDirectory(tab.workingDirectory)
            else { return failure(request, "Restore the folder on your Mac, then try again.") }
            if let problem = await checkedStartProblem(tab.spec.provider, model: model) {
                return failure(request, problem)
            }
            guard let index = model.tabs.firstIndex(where: { $0.id == tab.id }) else {
                return failure(request, "This tab is closed.")
            }
            model.restartTab(id: tab.id)
            guard index < model.tabs.count, model.tabs[index].id != tab.id else {
                return failure(request, "Could not restart this session. Check Sigil on your Mac.")
            }
            reply.restartedTabID = model.tabs[index].id.uuidString
            reply.restartedSession = model.tabs[index].sessionReference
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
        case "answer":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            // Refresh the host ledger, not just a hash of the same-looking text.
            guard let current = prompt(for: tab), request.name == current.id,
                let sessionID = current.sessionID, let key = request.text
            else { return failure(request, "That question is no longer on screen.") }
            guard let prompt = tab.remoteInteraction.consume(id: current.id, sessionID: sessionID, key: key)
            else { return failure(request, "This is unverified terminal output. Use terminal controls.") }
            // No await between consume and write. Success means dispatched only.
            tab.controller.send(text: key + (prompt.style == .yesNo ? "\r" : ""))
        case "file":
            guard let tab, tab.controller.isRunning else { return failure(request, "This session is not running.") }
            guard let transfer = request.transfer, let name = request.name, let index = request.index,
                let count = request.count, let text = request.text
            else { return failure(request, "That file could not be sent.") }
            do {
                if let url = try uploads.receive(
                    transfer: transfer, name: name, index: index, count: count, base64: text,
                    directory: TerminalDrop.cacheDirectory(), scope: request.challenge + ":" + tab.id.uuidString)
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
                || session.messageCount > 2 || session.hasObservedMessages
                || model.hasCustomName(session)
            if !named && !model.isOpen(session) { return false }
        }
        if !model.settings.showWorktreeSessions, isEphemeral(path: session.cwd), !model.isOpen(session) {
            return false
        }
        if !model.settings.showSubagentSessions, session.isSubagent, !model.isOpen(session) {
            return false
        }
        if !model.settings.showOtherAppSessions, !model.settings.isSigilConversation(session.id),
            !model.isOpen(session)
        {
            return false
        }
        return true
    }

    private static func chatRecord(_ session: GrokSession, model: AppModel) -> RemoteChat? {
        let folder = session.cwd
        guard !session.id.isEmpty, session.id.utf8.count <= 80, folder.utf8.count <= 4_000 else { return nil }
        return RemoteChat(
            id: session.id, title: bounded(model.title(for: session), bytes: 96), folder: folder,
            provider: session.provider.rawValue)
    }

    /// The sidebar's folders: grouped from chats, plus added folders with no chat yet.
    private static func projectRecords(_ model: AppModel) -> [RemoteProject] {
        SidebarOrganization.merging(
            added: model.settings.addedProjects, into: projectSessions(model),
            canonicalPath: GrokPaths.canonicalPath
        ).compactMap { project in
            guard project.cwd.utf8.count <= 4_000, !project.cwd.isEmpty else { return nil }
            return RemoteProject(
                name: bounded(project.name, bytes: 96), folder: project.cwd,
                repository: SigilWorktree.isInRepository(URL(fileURLWithPath: project.cwd)))
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
        await model.refreshProviderInstallationsForEntry()
        guard model.providerLaunchProblem(.grokBuild) == nil else { return }
        let path = model.grokExecutableURL.path
        guard let found = await GrokModelCatalog.menuModels(executable: model.grokExecutableURL) else { return }
        listedModels = (path, found)
    }

    static func newSessionOptions(_ model: AppModel) -> RemoteNewSessionOptions {
        let settings = model.settings
        let listed =
            listedModels.flatMap { $0.executable == model.grokExecutableURL.path ? $0.models : nil }
            ?? GrokModelCatalog.fallback
        let saved = GrokModelCatalog.normalized(settings.model)
        return RemoteNewSessionOptions(
            providers: CLIProvider.allCases.map {
                .init(
                    id: $0.rawValue, name: $0.name, takesModel: $0 == .grokBuild,
                    problem: startProblem($0, model: model))
            },
            provider: settings.defaultProvider.rawValue,
            models: Array(GrokModelCatalog.choices(listed: listed, saved: saved).filter(isModelName).prefix(100)),
            model: isModelName(saved) ? saved : "",
            efforts: AppSettings.effortOptions.map { .init(id: $0, name: AppSettings.effortLabel($0)) },
            effort: settings.effort,
            locations: projectLocations(model),
            startsInWorktree: settings.startsInWorktree)
    }

    /// Why `provider` cannot start now. Checked here because AppModel reports
    /// these with a modal alert, which would block this loop.
    static func startProblem(_ provider: CLIProvider, model: AppModel) -> String? {
        if let problem = model.providerLaunchProblem(provider) { return problem }
        if !model.hasSignIn(provider) {
            return "Set up \(provider.name) sign-in in Sigil on your Mac, then try again."
        }
        return nil
    }

    private static func checkedStartProblem(_ provider: CLIProvider, model: AppModel) async -> String? {
        let problem = await model.checkedProviderLaunchProblem(provider)
        guard !Task.isCancelled else { return "Remote was turned off." }
        return problem ?? startProblem(provider, model: model)
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
        // Older rows go first; the phone asks for them again when it scrolls up.
        while !fits(), var screen = reply.state?.screen, screen.rows.count > 1 {
            screen.rows.removeFirst(max(1, screen.rows.count / 4))
            screen.first = screen.rows.first?.i ?? screen.end
            reply.state?.screen = screen
        }
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
            tabsTruncated: state.tabsTruncated,
            screen: state.screen,
            mac: state.mac,
            prompt: state.prompt
        )
        return reply
    }

    private static func encodedCount(_ reply: RemoteReply) -> Int {
        (try? JSONEncoder().encode(reply).count) ?? Int.max
    }

    static func snapshot(_ model: AppModel, screen: RemoteScreen? = nil, terminal: Bool = true) -> RemoteState {
        RemoteState(
            tabs: visibleTabs(tabRecords(model), selectedID: model.selectedTab?.id.uuidString),
            selectedTabID: model.selectedTab?.id.uuidString,
            terminal: terminal
                ? boundedSuffix(model.selectedTab?.controller.remoteSnapshot() ?? "", bytes: 12_000) : "",
            tabsTruncated: model.tabs.count > 100,
            screen: screen,
            mac: macName,
            prompt: model.selectedTab.flatMap(prompt(for:))
        )
    }

    /// An explicitly unverified terminal hint, with a host-owned observation ID.
    static func prompt(for tab: TerminalTab) -> RemotePrompt? {
        guard tab.controller.isRunning else {
            tab.remoteInteraction.invalidate()
            return nil
        }
        // Read before display bounds; oversized context produces no hint.
        let window = tab.controller.remoteScreenWindow(maxRows: PromptDetector.window + 80, maxCharacters: 64_000)
        let sessionID = "\(tab.spec.provider.rawValue):\(tab.sessionID ?? "unknown"):\(tab.id.uuidString)"
        return tab.remoteInteraction.observeTerminal(
            sessionID: sessionID, revision: tab.controller.remoteInteractionRevision,
            afterInput: tab.controller.remoteInteractionAfterInput,
            prompt: PromptDetector.detect(rows: window.rows.map(\.t)))
    }

    static func snapshot(_ model: AppModel, screen window: RemoteScreenWindow?) -> RemoteState {
        let screen = window.map {
            RemoteScreen(
                tab: model.selectedTab?.id.uuidString, gen: $0.gen, alt: $0.alt ? true : nil, first: $0.first,
                end: $0.end, rows: $0.rows, palette: $0.palette, fg: $0.fg, bg: $0.bg)
        }
        return snapshot(model, screen: screen, terminal: false)
    }

    static func tabRecords(_ model: AppModel) -> [RemoteState.Tab] {
        model.tabs.map { tab in
            RemoteState.Tab(
                id: tab.id.uuidString, title: bounded(model.title(for: tab), bytes: 96),
                status: tab.activity.statusName, provider: tab.spec.provider.rawValue,
                providerName: tab.spec.provider.name,
                folder: bounded(
                    tab.workingDirectory.sigilWorktreeLabel ?? tab.workingDirectory.lastPathComponent, bytes: 96),
                canArchive: tab.spec.provider.capabilities.archive && model.session(for: tab) != nil,
                sessionID: tab.nativeSessionID, capabilities: tab.capabilities,
                processRunning: tab.controller.isRunning, cwd: tab.workingDirectory.path)
        }
    }

    static var macName: String {
        bounded(Host.current().localizedName ?? "Mac", bytes: 64)
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
