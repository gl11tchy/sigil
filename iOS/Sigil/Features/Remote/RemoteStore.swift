import Foundation
import Observation

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let data: Data
    /// A small JPEG for the chip, only for photos.
    let preview: Data?
}

/// Everything the screens show, fed by one `RemoteConnection`.
@MainActor
@Observable
final class RemoteStore {
    private(set) var hasPairing = false
    private(set) var phase: RemoteConnection.Phase = .offline
    private(set) var tabs: [RemoteTab] = []
    private(set) var selectedTabID: String?
    private(set) var canRestart = false
    /// The Mac streams rows and takes close, rename and archive.
    private(set) var supportsSessionOps = false
    private(set) var busy = false
    private(set) var loadingEarlier = false
    private(set) var macAddress: String?
    private(set) var macName: String?
    /// The approval question on the selected session, for the answer buttons.
    fileprivate(set) var prompt: RemotePrompt?
    /// When the tabs on screen were last heard from the Mac; nil once live.
    private(set) var cachedAt: Date?
    var errorMessage: String?
    var rawMode = false
    var drafts: [String: String] = [:]
    private(set) var attachments: [String: [Attachment]] = [:]

    private(set) var chatList = ChatList()
    private(set) var loadingChats = false
    private(set) var projects: [RemoteProject] = []
    private(set) var projectsTruncated = false
    private(set) var sessionOptions: NewSessionOptions?

    /// Bumped whenever the visible output changes, so the output view can repaint.
    private(set) var outputRevision = 0
    private(set) var output = ""
    /// The output with the terminal's colours; `output` is its text.
    private(set) var styledOutput = StyledText.empty
    private(set) var palette: [String] = []
    /// The terminal theme's default text and background, as `RRGGBB`; empty when unknown.
    private(set) var themeForeground = ""
    private(set) var themeBackground = ""

    let isDemo: Bool
    @ObservationIgnored private let connection = RemoteConnection()
    /// The APNs token, once iOS gave one; sent to the Mac on every connection.
    @ObservationIgnored private var pushToken: String?
    /// A session a notification or widget chose before the socket was up.
    @ObservationIgnored private var pendingTabID: String?
    @ObservationIgnored private let liveActivity = LiveActivityController()
    /// Rows per tab from a Mac that streams them.
    @ObservationIgnored private var screens: [String: ScreenModel] = [:]
    /// Text per tab from a Mac that only answers polls.
    @ObservationIgnored private var histories: [String: TerminalHistory] = [:]
    @ObservationIgnored private let formatter = ReadableOutput.bundled()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var chatQuery = ""
    @ObservationIgnored private var lastChunkAt = Date.distantPast
    @ObservationIgnored private var freshHandshake = false
    @ObservationIgnored private var foreground = true
    /// True once this connection's `watch` was accepted: no more polling.
    @ObservationIgnored private var streaming = false
    @ObservationIgnored private var credential: PairingCredential?

    init(isDemo: Bool) {
        self.isDemo = isDemo
        connection.delegate = self
        liveActivity.onToken = { [weak self] tabID, token in self?.sendActivityToken(token, for: tabID) }
        if isDemo {
            DemoData.seed(self)
        } else if let saved = CredentialStore.load() {
            hasPairing = true
            credential = saved
            macAddress = saved.origin.host
            restoreCache(for: saved)
            connection.resume(saved)
        }
    }

    var selectedTab: RemoteTab? { tabs.first { $0.id == selectedTabID } }
    var isConnected: Bool { phase == .connected }
    var isRevoked: Bool { phase == .revoked }

    var draft: String {
        get { selectedTabID.flatMap { drafts[$0] } ?? "" }
        set { if let id = selectedTabID { drafts[id] = newValue } }
    }

    var selectedAttachments: [Attachment] { selectedTabID.flatMap { attachments[$0] } ?? [] }

    var canSend: Bool {
        guard isConnected, !busy, let tab = selectedTab, tab.status != .exited else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selectedAttachments.isEmpty
    }

    // MARK: Pairing

    /// Returns an error to show, or nil once pairing has started.
    func pair(with text: String) -> String? {
        switch PairingLink.parse(text) {
        case .failure(.insecure): return "Sidereal needs an HTTPS address."
        case .failure(.notALink): return "That is not a Sigil pairing link."
        case .success(let link):
            if isDemo { return nil }
            errorMessage = nil
            macAddress = link.origin.host
            connection.pair(link)
            return nil
        }
    }

    func reconnect() {
        errorMessage = nil
        connection.reconnect()
    }

    func forget() {
        pollTask?.cancel()
        saveTask?.cancel()
        connection.stop(forget: true)
        if let credential { ScreenCache.delete(for: credential) }
        credential = nil
        CredentialStore.delete()
        hasPairing = false
        macAddress = nil
        macName = nil
        prompt = nil
        cachedAt = nil
        tabs = []
        selectedTabID = nil
        screens = [:]
        histories = [:]
        drafts = [:]
        attachments = [:]
        clearChats()
        projects = []
        sessionOptions = nil
        errorMessage = nil
        rawMode = false
        streaming = false
        supportsSessionOps = false
        refreshOutput()
    }

    // MARK: Lifecycle

    func enterForeground() {
        foreground = true
        guard !isDemo, hasPairing || connection.credential != nil else { return }
        switch phase {
        case .connected: if streaming { Task { await startStreaming() } } else { startPolling() }
        case .offline: connection.reconnect()
        case .connecting, .revoked: break
        }
    }

    /// iOS suspends the socket in the background anyway; closing it lets the Mac see the phone leave.
    func enterBackground() {
        foreground = false
        pollTask?.cancel()
        saveCacheNow()
        guard !isDemo, phase != .revoked else { return }
        connection.stop()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isConnected, self.foreground, !self.streaming else { return }
                if !self.busy { _ = try? await self.connection.request("state") }
            }
        }
    }

    /// Asks the Mac to send changes as they happen. A Mac that does not know
    /// `watch` is polled once a second, as before.
    private func startStreaming() async {
        guard isConnected, foreground else { return }
        AlertsController.enable()
        await registerPush()
        if let pending = pendingTabID { open(tabID: pending) }
        do {
            _ = try await connection.request("watch")
            streaming = true
            pollTask?.cancel()
        } catch RemoteConnectionError.mac("Unknown action.") {
            streaming = false
            startPolling()
        } catch {
            // The connection will change phase; the next handshake tries again.
        }
    }

    // MARK: Alerts

    /// iOS gave a device token. The Mac hears it now if connected, else on the next connection.
    func setPushToken(_ token: String) {
        guard pushToken != token else { return }
        pushToken = token
        if isConnected { Task { await registerPush() } }
    }

    private func registerPush() async {
        guard let pushToken, isConnected, !isDemo else { return }
        do {
            _ = try await connection.request("notify", text: pushToken, name: AlertsController.pushEnvironment)
        } catch RemoteConnectionError.mac("Unknown action.") {
            // An older Mac: no alerts from it, nothing else changes.
        } catch {
            // The next connection tries again.
        }
    }

    private func sendActivityToken(_ token: String, for tabID: String) {
        guard isConnected, !isDemo else { return }
        Task { _ = try? await connection.request("activity", text: token, tabID: tabID) }
    }

    /// Opens the session a notification or a widget named, now or once connected.
    func open(tabID: String) {
        if isConnected, let tab = tabs.first(where: { $0.id == tabID }) {
            pendingTabID = nil
            select(tab)
        } else {
            pendingTabID = tabID
        }
    }

    private func reflectLiveActivity() {
        liveActivity.reflect(tab: selectedTab, prompt: prompt, mac: macName)
    }

    // MARK: Commands

    func select(_ tab: RemoteTab) {
        guard tab.id != selectedTabID else { return }
        perform { _ = try await $0.request("select", tabID: tab.id) }
    }

    func interrupt() {
        guard isConnected, let id = selectedTabID else { return }
        Task { await run { _ = try await $0.request("key", text: RemoteKey.interrupt.rawValue, tabID: id) } }
    }

    /// Keys queue behind each other in the connection, so quick taps are never dropped.
    func send(key: RemoteKey) {
        guard isConnected, let id = selectedTabID else { return }
        Task { await run { _ = try await $0.request("key", text: key.rawValue, tabID: id) } }
    }

    func restart() {
        guard let id = selectedTabID else { return }
        perform { _ = try await $0.request("restart", tabID: id) }
    }

    func close(_ tab: RemoteTab) {
        perform { _ = try await $0.request("close", tabID: tab.id) }
    }

    /// An empty name restores the Mac's own title.
    func rename(_ tab: RemoteTab, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 80 else {
            errorMessage = "Keep the name under 80 characters."
            return
        }
        perform { _ = try await $0.request("rename", tabID: tab.id, name: trimmed) }
    }

    func archive(_ tab: RemoteTab) {
        perform { _ = try await $0.request("archive", tabID: tab.id) }
    }

    /// Answers the approval question with one of its keys. The Mac checks the
    /// question is still on screen before it types.
    func answer(_ key: String) {
        guard let id = selectedTabID, let prompt,
            prompt.choices.contains(where: { $0.key == key }) || key == prompt.yes || key == prompt.no
        else { return }
        perform { _ = try await $0.request("answer", text: key, tabID: id, name: prompt.id) }
    }

    /// A nil provider lets the Mac start its default CLI, as Macs before provider choice always do.
    /// A nil worktree leaves the choice to the Mac's own setting.
    func newSession(
        in folder: String?, provider: String? = nil, model: String? = nil, effort: String? = nil,
        worktree: Bool? = nil
    ) {
        perform {
            _ = try await $0.request(
                "new", text: folder, provider: provider, model: model, effort: effort, worktree: worktree)
        }
    }

    /// Returns false when this Mac predates provider choice; New then starts its default CLI.
    func loadSessionOptions() async -> Bool {
        guard isConnected, !isDemo else { return sessionOptions != nil }
        do {
            sessionOptions = try await connection.request("options").options
            return sessionOptions != nil
        } catch RemoteConnectionError.mac("Unknown action.") {
            sessionOptions = nil
            return false
        } catch {
            errorMessage = error.localizedDescription
            return sessionOptions != nil
        }
    }

    /// Makes the folder on the Mac and adds it to Projects.
    func createProject(named raw: String, in location: RemoteProject) async -> Result<RemoteProject, RemoteConnectionError> {
        guard let name = ProjectName.validated(raw) else {
            return .failure(.mac("Name the folder without slashes, colons or a leading dot."))
        }
        let project: RemoteProject
        if isDemo {
            project = RemoteProject(name: name, folder: "\(location.folder)/\(name)")
        } else {
            guard isConnected, !busy else { return .failure(.notConnected) }
            busy = true
            defer { busy = false }
            do {
                let reply = try await connection.request("createProject", text: location.folder, name: name)
                guard let created = reply.project else { return .failure(.mac(Self.updateMac)) }
                project = created
            } catch RemoteConnectionError.mac("Unknown action.") {
                return .failure(.mac(Self.updateMac))
            } catch let error as RemoteConnectionError {
                return .failure(error)
            } catch {
                return .failure(.lost)
            }
        }
        projects.removeAll { $0.folder == project.folder }
        projects.insert(project, at: 0)
        return .success(project)
    }

    private static let updateMac = "Update Sigil on your Mac to create projects from your phone."

    /// Returns false when this Mac predates the project list; New then uses its current folder.
    func loadProjects(from offset: Int = 0) async -> Bool {
        guard isConnected else { return true }
        do {
            let reply = try await connection.request("projects", index: offset == 0 ? nil : offset)
            let page = Array((reply.projects ?? []).prefix(40)).filter { !$0.folder.isEmpty && !$0.name.isEmpty }
            projects = offset == 0 ? page : projects + page
            projectsTruncated = page.count == 40 || reply.projectsTruncated == true
            return true
        } catch RemoteConnectionError.mac("Unknown action.") {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return true
        }
    }

    var chats: [RemoteChat] { chatList.chats }

    /// Saved chats, newest first. An empty query lists every chat, a page at a time.
    func loadChats(_ query: String) {
        clearChats()
        let token = searchToken
        // The Mac reads 200 characters, and text over 8 KB drops the connection.
        let trimmed = Self.utf8Prefix(
            String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), bytes: RemoteRequest.textLimit)
        chatQuery = trimmed
        if isDemo {
            let matches = DemoData.chats.filter {
                trimmed.isEmpty || $0.title.localizedCaseInsensitiveContains(trimmed)
                    || $0.folder.localizedCaseInsensitiveContains(trimmed)
            }
            chatList.apply(matches, from: 0, truncated: false)
            return
        }
        guard isConnected else { return }
        loadingChats = true
        Task {
            // Typing waits for a pause; opening the list does not.
            if !trimmed.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            await fetchChats(from: 0, token: token)
        }
    }

    func loadMoreChats() {
        guard isConnected, !loadingChats, chatList.hasMore else { return }
        loadingChats = true
        let token = searchToken
        Task { await fetchChats(from: chatList.offset, token: token) }
    }

    func clearChats() {
        searchToken += 1
        chatList = ChatList()
        loadingChats = false
    }

    private func fetchChats(from offset: Int, token: Int) async {
        guard token == searchToken else { return }
        defer { if token == searchToken { loadingChats = false } }
        do {
            let reply = try await connection.request("chats", text: chatQuery, index: offset == 0 ? nil : offset)
            guard token == searchToken else { return }
            chatList.apply(
                Array((reply.chats ?? []).prefix(ChatList.pageSize)), from: offset,
                truncated: reply.chatsTruncated == true)
        } catch {
            if token == searchToken { errorMessage = error.localizedDescription }
        }
    }

    func open(_ chat: RemoteChat) {
        perform { _ = try await $0.request("open", text: chat.folder, name: chat.id) }
    }

    func loadEarlier() {
        guard isConnected, !loadingEarlier, let id = selectedTabID else { return }
        if let screen = screens[id] {
            guard !screen.exhausted, let oldest = screen.oldestIndex, oldest > 0 else { return }
            loadingEarlier = true
            Task {
                defer { loadingEarlier = false }
                do {
                    _ = try await connection.request("rows", tabID: id, index: oldest)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        guard var bucket = histories[id], !bucket.exhausted else { return }
        let loaded = bucket.text
        guard !loaded.isEmpty else { return }
        let scalars = loaded.unicodeScalars
        let end = Self.utf8Prefix(String(String.UnicodeScalarView(scalars.suffix(40))), bytes: 80)
        guard !end.isEmpty else {
            bucket.exhausted = true
            histories[id] = bucket
            return
        }
        loadingEarlier = true
        Task {
            defer { loadingEarlier = false }
            do {
                _ = try await connection.request(
                    "earlier", text: String(String.UnicodeScalarView(scalars.prefix(80))), tabID: id, name: end, index: loaded.utf16.count)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var earlierExhausted: Bool {
        guard let id = selectedTabID else { return true }
        if let screen = screens[id] { return screen.exhausted || (screen.oldestIndex ?? 0) == 0 }
        return histories[id]?.exhausted ?? true
    }

    // MARK: Attachments and sending

    /// Returns a message when something was not added.
    func attach(_ items: [Attachment]) -> String? {
        guard let id = selectedTabID else { return nil }
        var list = attachments[id] ?? []
        var tooBig = false
        var overLimit = false
        for item in items {
            if item.data.count > RemoteFile.maxBytes {
                tooBig = true
                continue
            }
            if list.count >= RemoteFile.maxAttachments {
                overLimit = true
                continue
            }
            list.append(item)
        }
        attachments[id] = list
        return [tooBig ? "Keep files under 4 MB." : nil, overLimit ? "Up to 16 files per message." : nil]
            .compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }

    func removeAttachment(_ attachment: Attachment) {
        guard let id = selectedTabID else { return }
        attachments[id]?.removeAll { $0.id == attachment.id }
    }

    func sendDraft() {
        guard canSend, let target = selectedTabID else { return }
        let text = draft
        let files = selectedAttachments
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return }
        // After attachments the text gains a leading space, so check it as sent.
        let payload = files.isEmpty ? text : " \(text)"
        guard payload.utf8.count <= RemoteRequest.textLimit else {
            errorMessage = "Keep the message under 8 KB."
            return
        }
        perform { connection in
            for file in files {
                try await self.upload(file, to: target, over: connection)
                // The Mac has pasted this file, so a retry must not send it again.
                self.attachments[target]?.removeAll { $0.id == file.id }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try await connection.request("input", text: payload, tabID: target)
            }
            try await Task.sleep(for: .milliseconds(100))
            _ = try await connection.request("key", text: RemoteKey.enter.rawValue, tabID: target)
            if self.drafts[target] == text { self.drafts[target] = "" }
        }
    }

    private func upload(_ file: Attachment, to tabID: String, over connection: RemoteConnection) async throws {
        let transfer = RemoteFile.transferID()
        let name = RemoteFile.safeName(file.name)
        for chunk in RemoteFile.chunks(of: file.data) {
            // The relay closes a socket over 30 frames a second, and the Mac replies once per chunk.
            let wait = lastChunkAt.addingTimeInterval(0.05).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastChunkAt = Date()
            _ = try await connection.request(
                "file", text: chunk.base64, tabID: tabID, name: name, index: chunk.index, count: chunk.count,
                transfer: transfer)
        }
    }

    // MARK: Helpers

    private func perform(_ work: @escaping (RemoteConnection) async throws -> Void) {
        guard isConnected, !busy else { return }
        busy = true
        errorMessage = nil
        Task {
            await run(work)
            busy = false
        }
    }

    private func run(_ work: (RemoteConnection) async throws -> Void) async {
        if isDemo { return }
        do { try await work(connection) } catch { errorMessage = error.localizedDescription }
    }

    /// Any snapshot from the Mac: a reply or an event. `olderRows` marks a `rows`
    /// reply, whose screen goes before what is loaded instead of replacing it.
    fileprivate func apply(
        _ state: RemoteState, earlier: String?, olderRows: Bool, restartedFrom oldID: String?,
        restartedTo newID: String?
    ) {
        let ids = Set(state.tabs.map(\.id))
        let complete = state.tabListIsComplete
        // A Sigil restart gives every tab a new id. Carry the draft to the tab the Mac selected.
        let allTabsNew = freshHandshake && !tabs.isEmpty && !tabs.contains { ids.contains($0.id) }
        freshHandshake = false
        if let oldID, let newID {
            if let draft = drafts[oldID] { drafts[newID] = draft }
            if let files = attachments[oldID] { attachments[newID] = files }
        }
        if let previous = selectedTabID, let next = state.selectedTabID, previous != next, complete, allTabsNew,
            (drafts[next] ?? "").isEmpty, (attachments[next] ?? []).isEmpty
        {
            drafts[next] = drafts[previous]
            attachments[next] = attachments[previous]
        }
        tabs = state.tabs
        selectedTabID = state.selectedTabID
        canRestart = state.canRestart
        supportsSessionOps = state.supportsSessionOps
        prompt = state.prompt
        if let name = state.mac, !name.isEmpty { macName = name }
        cachedAt = nil
        if let screen = state.screen, let target = screen.tab ?? state.selectedTabID {
            // Rows land in the tab they were read from, even if the selection moved meanwhile.
            var model = screens[target] ?? ScreenModel()
            if olderRows { model.prepend(screen) } else { model.apply(screen) }
            screens[target] = model
        } else if let id = state.selectedTabID, screens[id] == nil {
            // Text snapshots come with polls and command replies. A tab that streams
            // rows keeps them; a streaming Mac sends an empty terminal in any case.
            var bucket = histories[id] ?? TerminalHistory()
            bucket.apply(state.terminal)
            if let earlier { bucket.prepend(earlier) }
            histories[id] = bucket
        }
        if complete {
            screens = screens.filter { ids.contains($0.key) }
            histories = histories.filter { ids.contains($0.key) }
            drafts = drafts.filter { ids.contains($0.key) }
            attachments = attachments.filter { ids.contains($0.key) }
        }
        scheduleRefresh()
        scheduleSave()
        reflectLiveActivity()
    }

    /// Output changes arrive many times a second; one repaint per burst is enough.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refreshOutput()
        }
    }

    func refreshOutput() {
        let next: StyledText
        var colours: [String] = []
        var fg = ""
        var bg = ""
        if let id = selectedTabID, let screen = screens[id] {
            let lines = screen.lines
            colours = screen.palette
            fg = screen.foreground
            bg = screen.background
            if rawMode {
                next = StyledOutput.raw(lines)
            } else {
                next = StyledOutput.readable(formatter.format(ScreenModel.text(of: lines)), lines: lines)
            }
        } else {
            let raw = selectedTabID.flatMap { histories[$0]?.text } ?? ""
            next = StyledText(text: rawMode ? raw : formatter.format(raw), spans: [])
        }
        if next != styledOutput || colours != palette || fg != themeForeground || bg != themeBackground {
            styledOutput = next
            palette = colours
            themeForeground = fg
            themeBackground = bg
            output = next.text
            outputRevision += 1
        }
    }

    // MARK: Cache

    private func restoreCache(for credential: PairingCredential) {
        guard let cached = ScreenCache.load(for: credential) else { return }
        tabs = cached.tabs
        selectedTabID = cached.selectedTabID
        macName = cached.mac
        screens = cached.screens
        cachedAt = cached.savedAt
        refreshOutput()
    }

    private func scheduleSave() {
        guard saveTask == nil, credential != nil || connection.credential != nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveCacheNow()
        }
    }

    private func saveCacheNow() {
        saveTask?.cancel()
        saveTask = nil
        guard !isDemo, let credential = credential ?? connection.credential, !tabs.isEmpty else { return }
        // Only the session on screen: that is what the next launch shows first.
        let kept = selectedTabID.flatMap { id in screens[id].map { [id: $0] } } ?? [:]
        ScreenCache.save(
            CachedScreen(tabs: tabs, selectedTabID: selectedTabID, mac: macName, screens: kept, savedAt: Date()),
            for: credential)
    }

    static func utf8Prefix(_ text: String, bytes: Int) -> String {
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            guard used + size <= bytes else { break }
            used += size
            out.append(character)
        }
        return out
    }

    // MARK: Demo

    fileprivate func seedDemo(tabs: [RemoteTab], selected: String, screen: RemoteScreen) {
        hasPairing = true
        phase = .connected
        macAddress = "remote.sigilapp.dev"
        macName = "Studio"
        self.tabs = tabs
        selectedTabID = selected
        canRestart = true
        supportsSessionOps = true
        var model = ScreenModel()
        model.apply(screen)
        model.exhausted = true
        screens[selected] = model
        projects = [
            RemoteProject(name: "sigil", folder: "~/Documents/sigil", repository: true),
            RemoteProject(name: "site", folder: "~/Documents/sigil/Site", repository: true),
            RemoteProject(name: "relay", folder: "~/Documents/sigil/Sidereal", repository: false),
        ]
        sessionOptions = DemoData.options
        refreshOutput()
    }
}

extension RemoteStore: RemoteConnectionDelegate {
    func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase) {
        self.phase = phase
        switch phase {
        case .connected:
            errorMessage = nil
            credential = connection.credential
            streaming = false
            if foreground { Task { await startStreaming() } }
        case .connecting:
            freshHandshake = true
            streaming = false
            pollTask?.cancel()
        case .offline, .revoked:
            streaming = false
            pollTask?.cancel()
        }
    }

    func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?) {
        guard let state = reply.state else { return }
        let restarted = action == "restart" ? reply.restartedTabID.flatMap { $0 != tabID && $0.utf8.count <= 64 ? $0 : nil } : nil
        apply(
            state, earlier: action == "earlier" && tabID == state.selectedTabID ? (reply.earlier ?? "") : nil,
            olderRows: action == "rows" && tabID == state.selectedTabID,
            restartedFrom: restarted == nil ? nil : tabID, restartedTo: restarted)
        if let restarted, let tabID, restarted != tabID {
            drafts[tabID] = nil
        }
    }

    func connection(_ connection: RemoteConnection, didReceiveEvent reply: RemoteReply) {
        guard let state = reply.state else { return }
        apply(state, earlier: nil, olderRows: false, restartedFrom: nil, restartedTo: nil)
    }

    func connection(_ connection: RemoteConnection, didSave credential: PairingCredential) {
        if !CredentialStore.save(credential) {
            errorMessage = "Could not save this pairing. It ends when the app closes."
        }
        self.credential = credential
        hasPairing = true
        macAddress = credential.origin.host
    }

    func connection(_ connection: RemoteConnection, didFail message: String) {
        errorMessage = message
    }
}

/// Offline sample data so every screen can be screenshotted with no Mac.
enum DemoData {
    @MainActor
    static func seed(_ store: RemoteStore) {
        let tabs = [
            RemoteTab(
                id: "demo-1", title: "sigil · iOS companion", status: .working, provider: "claudeCode",
                providerName: "Claude Code", folder: "sigil", canArchive: false),
            RemoteTab(
                id: "demo-2", title: "site · pricing copy", status: .idle, provider: "grokBuild",
                providerName: "Grok Build", folder: "sigil/Site", canArchive: true),
            RemoteTab(
                id: "demo-3", title: "relay · load test", status: .exited, provider: "codex",
                providerName: "Codex", folder: "sigil/a1b2c3d4", canArchive: false),
        ]
        store.seedDemo(tabs: tabs, selected: "demo-1", screen: screen)
        store.prompt = RemotePrompt(
            question: "Do you want to proceed?", style: .menu,
            choices: [
                .init(label: "Yes", key: "1"),
                .init(label: "Yes, and don't ask again for scripts/test.sh", key: "2"),
                .init(label: "No, and tell Claude what to do differently (esc)", key: "3"),
            ], yes: "1", no: "3")
    }

    /// Terminal rows with the colours a real session has: a bold prompt, green
    /// PASS lines, a red error, a dim path.
    static var screen: RemoteScreen {
        let text = """
            > Add a native iPhone companion that pairs by QR code.

            I'll start with the protocol core, then the screens.

              Read Sources/SigilKit/Remote/RemoteSession.swift
              Read Sidereal/public/app.mjs
              Write iOS/Sigil/Core/Networking/RemoteConnection.swift

            The connection speaks the same sealed protocol as the web companion:
            route, hello, then numbered requests. Replies are matched by sequence
            and a stale reply from an earlier handshake is ignored.

              $ scripts/test.sh
              PASS crypto round trip
              PASS pairing link table
              FAIL history keeps scrolled text: expected 4 lines
              OK 24

            Next: the session screen and the composer.
            """
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { offset, line in
            let row = String(line)
            var runs: [[Int]]?
            if row.hasPrefix(">") { runs = [[0, row.count, 5, -1, 1]] }
            if row.contains("PASS") { runs = [[2, 4, 2, -1, 1]] }
            if row.contains("FAIL") { runs = [[2, 4, 1, -1, 1], [8, row.count - 8, 1, -1, 0]] }
            if row.contains("Read ") || row.contains("Write ") { runs = [[2, row.count - 2, 8, -1, 0]] }
            if row.hasPrefix("  $") { runs = [[2, row.count - 2, 6, -1, 0]] }
            return RemoteScreenRow(i: offset, t: row, w: nil, s: runs)
        }
        return RemoteScreen(
            tab: "demo-1", gen: 1, alt: nil, first: 0, end: rows.count, rows: rows,
            palette: [
                "1c1c1e", "ff6b6b", "5ad27a", "ffd166", "5aa6ff", "d78bff", "5fd8e0", "e6e6e6",
                "6b6b70", "ff8a8a", "7ee89a", "ffe08a", "8ac0ff", "e8a8ff", "8ae6ee", "ffffff",
            ], fg: "e6e6e6", bg: "0b0b0d")
    }

    static let chats = [
        RemoteChat(id: "chat-1", title: "Sessions list misses saved chats", folder: "~/Documents/sigil"),
        RemoteChat(id: "chat-2", title: "Pricing page copy pass", folder: "~/Documents/sigil/Site"),
        RemoteChat(id: "chat-3", title: "Relay load test at 500 phones", folder: "~/Documents/sigil/Sidereal"),
        RemoteChat(id: "chat-4", title: "Keychain pairing survives relaunch", folder: "~/Documents/sigil"),
    ]

    static let options = NewSessionOptions(
        providers: [
            .init(id: "claudeCode", name: "Claude Code", takesModel: false, problem: nil),
            .init(id: "codex", name: "Codex", takesModel: false, problem: nil),
            .init(id: "devin", name: "Devin", takesModel: false, problem: nil),
            .init(id: "cursor", name: "Cursor", takesModel: false, problem: nil),
            .init(id: "kimi", name: "Kimi Code", takesModel: false, problem: nil),
            .init(id: "grokBuild", name: "Grok Build", takesModel: true, problem: nil),
        ],
        provider: "grokBuild", models: ["grok-4.7", "grok-4.7-build-fast", "grok-4.6"], model: "",
        efforts: [
            .init(id: "", name: "CLI default"), .init(id: "low", name: "Low"), .init(id: "medium", name: "Medium"),
            .init(id: "high", name: "High"), .init(id: "xhigh", name: "Extra high"),
        ],
        effort: "",
        locations: [
            RemoteProject(name: "~/Documents", folder: "~/Documents"),
            RemoteProject(name: "~/Documents/sigil", folder: "~/Documents/sigil"),
            RemoteProject(name: "~", folder: "~"),
        ],
        startsInWorktree: true)
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
