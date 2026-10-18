import Foundation
import Observation
import UIKit

/// The system may refuse or expire this time. Fixtures supply the same lifecycle
/// without relying on a simulator's background allowance.
@MainActor
struct SendBackgroundTask {
    let begin: @MainActor (@escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)?

    static var system: Self {
        Self { expiration in
            let id = UIApplication.shared.beginBackgroundTask(withName: "Finish send", expirationHandler: expiration)
            guard id != .invalid else { return nil }
            return { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}

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
    /// Every Mac this phone is paired with, and the one the screens show.
    private(set) var macs: [PairingCredential] = []
    private(set) var activeMacID: String?
    private(set) var phase: RemoteConnection.Phase = .offline
    private(set) var tabs: [RemoteTab] = []
    private(set) var selectedTabID: String?
    private(set) var canRestart = false
    /// The Mac streams rows and takes close, rename and archive.
    private(set) var supportsSessionOps = false
    private(set) var busy = false
    private(set) var sendMayBeIncomplete = false
    private(set) var loadingEarlier = false
    private(set) var macAddress: String?
    private(set) var macName: String?
    /// The approval question on the selected session, for the answer buttons.
    fileprivate(set) var prompt: RemotePrompt?
    /// When the tabs on screen were last heard from the Mac; nil once live.
    private(set) var cachedAt: Date?
    /// At launch, the screen waits for a cache on disk instead of showing an empty Mac.
    private(set) var awaitingCache = false
    private var problem: String?
    var errorMessage: String? {
        get {
            guard let problem else { return nil }
            return sendMayBeIncomplete && !problem.hasPrefix(Self.incompleteSend)
                ? Self.incompleteSend + " " + problem : problem
        }
        set { problem = newValue }
    }
    var rawMode = false
    var drafts: [String: String] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(drafts.keys) where oldValue[id] != drafts[id] {
                draftRevisions[id] = drafts[id] == nil ? nil : UUID()
            }
        }
    }
    @ObservationIgnored private var draftRevisions: [String: UUID] = [:]
    private(set) var attachments: [String: [Attachment]] = [:]
    @ObservationIgnored private var draftsByMac: [String: [String: String]] = [:]
    @ObservationIgnored private var attachmentsByMac: [String: [String: [Attachment]]] = [:]
    /// Identity for unsent work survives a Mac switch even when its disk cache
    /// has not loaded. This metadata never restores tabs or output as live state.
    @ObservationIgnored private var sessionReferences: [String: ProviderSessionReference] = [:]
    @ObservationIgnored private var referencesByMac: [String: [String: ProviderSessionReference]] = [:]

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
    /// The last theme background this Mac sent, for light or dark. It outlives a tab
    /// with no screen yet, so the look does not flip. A restore starts from the one
    /// last saved for the Mac; empty until there is one.
    private(set) var appearanceGround = ""

    let isDemo: Bool
    @ObservationIgnored private let connection: RemoteConnection
    @ObservationIgnored private let backgroundTask: SendBackgroundTask
    private struct PendingCommand {
        let id: UUID
        let macID: String?
        let epoch: Int
        let isSend: Bool
    }
    private struct SendLease {
        let id = UUID()
        let commandID: UUID
        var end: (@MainActor () -> Void)?
    }
    @ObservationIgnored private var command: PendingCommand?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var sendLease: SendLease?
    @ObservationIgnored private var backgroundSend: UUID?
    /// The APNs token, once iOS gave one; sent to the Mac on every connection.
    @ObservationIgnored private var pushToken: String?
    /// A session a notification or widget chose before the socket was up.
    @ObservationIgnored private var pendingTabID: String?
    /// The Mac on screen when Pair another Mac began, for Cancel.
    @ObservationIgnored private var macBeforePairing: String?
    /// Live Activity push tokens by tab, replayed after every handshake: the Mac holds them in memory only.
    @ObservationIgnored private var activityTokens: [String: String] = [:]
    @ObservationIgnored private let liveActivity = LiveActivityController()
    /// Rows per tab from a Mac that streams them.
    @ObservationIgnored private var screens: [String: ScreenModel] = [:]
    /// Text per tab from a Mac that only answers polls.
    @ObservationIgnored private var histories: [String: TerminalHistory] = [:]
    @ObservationIgnored private let formatter = ReadableOutput.bundled()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Lets a cache read land only if nothing replaced the screen meanwhile.
    @ObservationIgnored private var restoreGate = RestoreGate() {
        // Set only on a change: live state invalidates the gate many times a second.
        didSet { if awaitingCache != restoreGate.isAwaiting { awaitingCache = restoreGate.isAwaiting } }
    }
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var chatQuery = ""
    @ObservationIgnored private var lastChunkAt = Date.distantPast
    private struct PendingRestart {
        let id = UUID()
        let tabID: String
        let macID: String?
        let epoch: Int
        let reference: ProviderSessionReference?
    }
    @ObservationIgnored private var pendingRestart: PendingRestart?
    @ObservationIgnored private var freshHandshake = false
    @ObservationIgnored private var foreground = true
    /// True once this connection's `watch` was accepted: no more polling.
    @ObservationIgnored private var streaming = false
    @ObservationIgnored private var credential: PairingCredential?

    init(
        isDemo: Bool, restoreSavedPairings: Bool = true, connection: RemoteConnection? = nil,
        backgroundTask: SendBackgroundTask? = nil
    ) {
        self.isDemo = isDemo
        self.connection = connection ?? RemoteConnection()
        self.backgroundTask = backgroundTask ?? .system
        self.connection.delegate = self
        liveActivity.onToken = { [weak self] tabID, token in self?.sendActivityToken(token, for: tabID) }
        liveActivity.onEnd = { [weak self] tabID in self?.forgetActivityToken(for: tabID) }
        if isDemo {
            DemoData.seed(self)
        } else if restoreSavedPairings {
            let list = CredentialStore.loadList()
            macs = list.macs
            if let saved = list.selected { activate(saved, awaitCache: true) }
        }
    }

    /// Shows one Mac: its cached screen first, then its live connection.
    /// `awaitCache` holds the screen for a cache on disk, as at launch.
    private func activate(_ saved: PairingCredential, awaitCache: Bool = false) {
        activeMacID = saved.id
        drafts = draftsByMac[saved.id] ?? [:]
        attachments = attachmentsByMac[saved.id] ?? [:]
        sessionReferences = referencesByMac[saved.id] ?? [:]
        hasPairing = true
        credential = saved
        macAddress = saved.origin.host
        macName = saved.name
        restoreCache(for: saved, awaitCache: awaitCache)
        connection.resume(saved)
    }

    /// Switches the screens to another paired Mac.
    func switchTo(macID: String) {
        guard macID != activeMacID, let next = macs.first(where: { $0.id == macID }) else { return }
        if isDemo {
            // The demo is offline: only the name changes, the seeded sessions stay.
            activeMacID = macID
            macName = next.label
            return
        }
        saveCacheNow()
        connection.stop()
        liveActivity.end()
        // A notification or a widget can open another Mac at launch: keep the launch wait for its cache.
        let waiting = restoreGate.isAwaiting
        clearMacState()
        CredentialStore.select(id: macID)
        activate(next, awaitCache: waiting)
    }

    /// Preserve unsent work under its pairing, never a bare tab ID from another Mac.
    private func clearMacState() {
        invalidateCommand()
        restoreGate.invalidate()
        if let activeMacID {
            draftsByMac[activeMacID] = drafts
            attachmentsByMac[activeMacID] = attachments
            referencesByMac[activeMacID] = sessionReferences
        }
        drafts = [:]
        attachments = [:]
        sessionReferences = [:]
        tabs = []
        selectedTabID = nil
        pendingTabID = nil
        pendingRestart = nil
        screens = [:]
        histories = [:]
        prompt = nil
        macName = nil
        cachedAt = nil
        streaming = false
        supportsSessionOps = false
        canRestart = false
        activityTokens = [:]
        clearChats()
        projects = []
        sessionOptions = nil
        errorMessage = nil
        sendMayBeIncomplete = false
        appearanceGround = ""
        refreshOutput()
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
        guard isConnected, !busy, let tab = selectedTab, tab.acceptsInput else { return false }
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
            // Pairing another Mac: the one on screen keeps its place in the list and comes back on Cancel.
            if hasPairing {
                macBeforePairing = activeMacID
                saveCacheNow()
                connection.stop()
                liveActivity.end()
                clearMacState()
                activeMacID = nil
                credential = nil
            }
            macAddress = link.origin.host
            connection.pair(link)
            return nil
        }
    }

    /// True while a new Mac is being paired from inside the app.
    var isPairingAnother: Bool { hasPairing && activeMacID == nil }

    /// Goes back to the Mac that was on screen after a pairing attempt that did not finish.
    func cancelPairing() {
        guard isPairingAnother else { return }
        connection.stop(forget: true)
        errorMessage = nil
        let previous = macs.first { $0.id == macBeforePairing } ?? macs.first
        macBeforePairing = nil
        if let previous {
            CredentialStore.select(id: previous.id)
            activate(previous)
        } else {
            hasPairing = false
        }
    }

    func reconnect() {
        if !sendMayBeIncomplete { errorMessage = nil }
        connection.reconnect()
    }

    /// Forgets the Mac on screen. Another paired Mac takes its place, if there is one.
    func forget() {
        pollTask?.cancel()
        saveTask?.cancel()
        connection.stop(forget: true)
        liveActivity.end()
        if let credential {
            ScreenCache.delete(for: credential)
            CredentialStore.delete(id: credential.id)
            macs.removeAll { $0.id == credential.id }
            draftsByMac[credential.id] = nil
            attachmentsByMac[credential.id] = nil
            referencesByMac[credential.id] = nil
        } else {
            CredentialStore.delete()
            macs = []
        }
        credential = nil
        activeMacID = nil
        clearMacState()
        drafts = [:]
        attachments = [:]
        rawMode = false
        if let next = CredentialStore.loadList().selected {
            activate(next)
        } else {
            hasPairing = false
            macAddress = nil
        }
    }

    // MARK: Lifecycle

    func enterForeground() {
        let returning = !foreground
        foreground = true
        backgroundSend = nil
        if returning {
            endSendLease()
            if let command, command.isSend, owns(command) { prepareSendLease(for: command) }
        }
        guard !isDemo, hasPairing || connection.credential != nil else { return }
        switch phase {
        case .connected: if streaming { Task { await startStreaming() } } else { startPolling() }
        case .offline: connection.reconnect()
        case .connecting, .revoked: break
        }
    }

    /// The app opts into finishing an owned send. Teardown keeps the immediate path.
    func enterBackground(finishingSend: Bool = false) {
        foreground = false
        backgroundSend = nil
        pollTask?.cancel()
        saveCacheNow()
        guard !isDemo, phase != .revoked else { return }
        if finishingSend, let command, command.isSend, owns(command),
            let lease = sendLease, lease.commandID == command.id, lease.end != nil
        {
            backgroundSend = command.id
            return
        }
        invalidateCommand()
        connection.stop()
    }

    private func prepareSendLease(for work: PendingCommand) {
        endSendLease()
        guard !isDemo else { return }
        let lease = SendLease(commandID: work.id)
        let leaseID = lease.id
        sendLease = lease
        let end = backgroundTask.begin { [weak self] in self?.expireSendLease(leaseID) }
        if sendLease?.id == leaseID {
            sendLease?.end = end
        } else {
            // Expiration may arrive before begin returns.
            end?()
        }
    }

    private func endSendLease() {
        let end = sendLease?.end
        sendLease = nil
        end?()
    }

    private func expireSendLease(_ id: UUID) {
        guard let lease = sendLease, lease.id == id else { return }
        let work = command
        endSendLease()
        guard let work, work.id == lease.commandID, owns(work),
            !foreground, backgroundSend == work.id else { return }
        invalidateCommand()
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
        // Legacy events have no freshness counter. Poll authenticated replies instead.
        guard connection.supportsOrderedEvents else {
            streaming = false
            startPolling()
            return
        }
        AlertsController.enable()
        await registerPush()
        await replayActivityTokens()
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
        activityTokens[tabID] = token
        guard isConnected, !isDemo else { return }
        Task { _ = try? await connection.request("activity", text: token, tabID: tabID) }
    }

    /// Tells the Mac every activity token again, dropping tabs it no longer has.
    private func replayActivityTokens() async {
        guard isConnected, !isDemo else { return }
        activityTokens = activityTokens.filter { token in tabs.contains { $0.id == token.key } }
        for (tabID, token) in activityTokens {
            _ = try? await connection.request("activity", text: token, tabID: tabID)
        }
    }

    /// The activity ended on the phone: the Mac should stop pushing to it.
    private func forgetActivityToken(for tabID: String) {
        guard activityTokens.removeValue(forKey: tabID) != nil, isConnected, !isDemo else { return }
        Task { _ = try? await connection.request("activity", text: "", tabID: tabID) }
    }

    /// Opens the session a notification or a widget named, on the Mac it names,
    /// now or once connected.
    func open(tabID: String, macID: String? = nil) {
        if let macID, macID != activeMacID {
            guard macs.contains(where: { $0.id == macID }) else {
                errorMessage = "Pair this Mac again before opening its session."
                return
            }
            switchTo(macID: macID)
        }
        if isConnected, let tab = tabs.first(where: { $0.id == tabID }) {
            pendingTabID = nil
            select(tab)
        } else {
            pendingTabID = tabID
        }
    }

    private func reflectLiveActivity() {
        liveActivity.reflect(tab: selectedTab, prompt: prompt, mac: macName, macID: activeMacID)
    }

    // MARK: Commands

    func select(_ tab: RemoteTab) {
        guard tab.id != selectedTabID else { return }
        perform { _ = try await $0.request("select", tabID: tab.id) }
    }

    func interrupt() {
        guard isConnected, let id = selectedTabID else { return }
        let epoch = connection.commandEpoch
        Task { await run {
            try $0.requireCurrentConnection(epoch)
            _ = try await $0.request("key", text: RemoteKey.interrupt.rawValue, tabID: id)
        } }
    }

    /// Keys queue behind each other in the connection, so quick taps are never dropped.
    func send(key: RemoteKey) {
        guard isConnected, let id = selectedTabID else { return }
        let epoch = connection.commandEpoch
        Task { await run {
            try $0.requireCurrentConnection(epoch)
            _ = try await $0.request("key", text: key.rawValue, tabID: id)
        } }
    }

    func restart() {
        guard isConnected, !busy, !isDemo, let id = selectedTabID else { return }
        let pending = PendingRestart(tabID: id, macID: activeMacID, epoch: connection.commandEpoch, reference: sessionReferences[id])
        pendingRestart = pending
        perform { connection in
            defer { if self.pendingRestart?.id == pending.id { self.pendingRestart = nil } }
            _ = try await connection.request("restart", tabID: id)
        }
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

    /// Structured responses require an authoritative interaction. Terminal hints
    /// only type the chosen character; they never claim stale-response protection.
    func answer(_ key: String) {
        guard let id = selectedTabID, let prompt,
            prompt.choices.contains(where: { $0.key == key }) || key == prompt.yes || key == prompt.no
        else { return }
        if prompt.verified {
            guard let instance = prompt.id, !instance.isEmpty, let session = prompt.sessionID, !session.isEmpty,
                selectedTab?.capabilities?.structuredApproval == true
            else { return }
            perform { _ = try await $0.request("answer", text: key, tabID: id, name: instance) }
        } else {
            let epoch = connection.commandEpoch
            perform {
                _ = try await $0.request("key", text: key, tabID: id)
                if prompt.style == .yesNo {
                    try $0.requireCurrentConnection(epoch)
                    _ = try await $0.request("key", text: "enter", tabID: id)
                }
            }
        }
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
        perform { _ = try await $0.request("open", text: chat.folder, name: chat.id, provider: chat.provider) }
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
        let id = UUID()
        let revision = draftRevisions[target]
        perform(id: id, isSend: true, onSuccess: {
            if self.drafts[target] == text, self.draftRevisions[target] == revision { self.drafts[target] = "" }
        }) { connection in
            try self.requireCommand(id)
            for file in files {
                try await self.upload(file, to: target, over: connection, commandID: id)
                try self.requireCommand(id)
                // The Mac has pasted this file, so a retry must not send it again.
                self.attachments[target]?.removeAll { $0.id == file.id }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try self.requireCommand(id)
                _ = try await connection.request("input", text: payload, tabID: target)
            }
            try await Task.sleep(for: .milliseconds(100))
            try self.requireCommand(id)
            _ = try await connection.request("key", text: RemoteKey.enter.rawValue, tabID: target)
            try self.requireCommand(id)
        }
    }

    private func upload(_ file: Attachment, to tabID: String, over connection: RemoteConnection, commandID: UUID) async throws {
        let transfer = RemoteFile.transferID()
        let name = RemoteFile.safeName(file.name)
        for chunk in RemoteFile.chunks(of: file.data) {
            // The relay closes a socket over 30 frames a second, and the Mac replies once per chunk.
            let wait = lastChunkAt.addingTimeInterval(0.05).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            lastChunkAt = Date()
            try requireCommand(commandID)
            _ = try await connection.request(
                "file", text: chunk.base64, tabID: tabID, name: name, index: chunk.index, count: chunk.count,
                transfer: transfer)
        }
    }

    // MARK: Helpers

    private func perform(
        id: UUID = UUID(), isSend: Bool = false,
        onSuccess: (@MainActor () -> Void)? = nil,
        _ work: @escaping @MainActor (RemoteConnection) async throws -> Void
    ) {
        guard isConnected, !busy else { return }
        let pending = PendingCommand(id: id, macID: activeMacID, epoch: connection.commandEpoch, isSend: isSend)
        command = pending
        busy = true
        sendMayBeIncomplete = false
        errorMessage = nil
        // Ask before starting network work, while the app is still in front.
        if isSend { prepareSendLease(for: pending) }
        guard command?.id == id else { return }
        commandTask = Task { @MainActor in
            var failure: Error?
            do {
                if !self.isDemo {
                    try self.requireCommand(id)
                    try await work(self.connection)
                }
            } catch {
                failure = error
            }
            self.completeCommand(pending, error: failure, onSuccess: onSuccess)
        }
    }

    private func owns(_ work: PendingCommand) -> Bool {
        command?.id == work.id && activeMacID == work.macID
            && connection.commandEpoch == work.epoch && isConnected && connection.phase == .connected
    }

    private func requireCommand(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let command, command.id == id, activeMacID == command.macID else { throw RemoteConnectionError.changed }
        try connection.requireCurrentConnection(command.epoch)
    }

    private static let incompleteSend = "Send may be incomplete. Check the terminal before sending again."

    private func markIncompleteSend() {
        sendMayBeIncomplete = true
        errorMessage = Self.incompleteSend
    }

    private func invalidateCommand() {
        let previous = command
        command = nil
        commandTask?.cancel()
        commandTask = nil
        backgroundSend = nil
        endSendLease()
        // A separate createProject operation may own busy without a perform task.
        guard let previous else { return }
        busy = false
        if previous.macID == activeMacID, !isDemo {
            if previous.isSend { markIncompleteSend() }
            else { errorMessage = RemoteConnectionError.changed.localizedDescription }
        }
    }

    private func completeCommand(_ work: PendingCommand, error: Error?, onSuccess: (@MainActor () -> Void)?) {
        guard command?.id == work.id else { return }
        let sameMac = activeMacID == work.macID
        // Commit the draft and release busy in one actor turn. A disconnect
        // between the async work and this completion must retain the draft.
        if error == nil, owns(work) { onSuccess?() }
        if work.isSend, !isDemo, sameMac, error != nil || !owns(work) {
            markIncompleteSend()
        } else if let error, sameMac {
            errorMessage = error.localizedDescription
        }
        let stop = !foreground && backgroundSend == work.id && sameMac
        let stopEpoch = connection.commandEpoch
        command = nil
        commandTask = nil
        backgroundSend = nil
        busy = false
        endSendLease()
        guard stop, !foreground, command == nil, activeMacID == work.macID,
            connection.commandEpoch == stopEpoch, phase != .revoked else { return }
        connection.stop()
    }

    private func run(_ work: (RemoteConnection) async throws -> Void) async {
        if isDemo { return }
        do { try await work(connection) } catch { errorMessage = error.localizedDescription }
    }

    /// Keep edits made on either side of a confirmed conversation replacement.
    /// An identical fragment or attachment ID is kept only once.
    private func mergeUnsentWork(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        let old = drafts[oldID] ?? ""
        let new = drafts[newID] ?? ""
        if !old.isEmpty {
            drafts[newID] = new.isEmpty || new == old ? old : old + "\n\n" + new
        }
        var seen = Set<UUID>()
        let files = ((attachments[oldID] ?? []) + (attachments[newID] ?? [])).filter { seen.insert($0.id).inserted }
        if !files.isEmpty { attachments[newID] = files }
    }

    /// Any snapshot from the Mac: a reply or an event. `olderRows` marks a `rows`
    /// reply, whose screen goes before what is loaded instead of replacing it.
    fileprivate func apply(
        _ state: RemoteState, earlier: String?, olderRows: Bool, restartedFrom oldID: String?,
        restartedTo newID: String?, restartedSession: ProviderSessionReference? = nil
    ) {
        let ids = Set(state.tabs.map(\.id))
        let complete = state.tabListIsComplete
        let pending = pendingRestart.flatMap {
            $0.macID == activeMacID && $0.epoch == connection.commandEpoch ? $0 : nil
        }
        // A tab UUID can change after restart. Only a unique provider-native
        // conversation and canonical project match can inherit unsent work.
        if freshHandshake, complete {
            for (previousID, reference) in sessionReferences where !ids.contains(previousID) {
                let matches = state.tabs.filter { $0.sessionReference == reference }
                guard matches.count == 1, let next = matches.first else { continue }
                mergeUnsentWork(from: previousID, to: next.id)
            }
        }
        freshHandshake = false
        let previousReference = pending?.tabID == oldID ? pending?.reference : oldID.flatMap { sessionReferences[$0] }
        if let oldID, let newID, oldID != newID,
            let reference = previousReference,
            reference == (restartedSession ?? state.tabs.first(where: { $0.id == newID })?.sessionReference)
        {
            mergeUnsentWork(from: oldID, to: newID)
            sessionReferences[newID] = reference
            drafts[oldID] = nil
            attachments[oldID] = nil
            sessionReferences[oldID] = nil
        }
        for tab in state.tabs { sessionReferences[tab.id] = tab.sessionReference }
        // Live, even with no tabs: a cache still being read must not replace it.
        // A launch wait holds until `show` draws this state's output.
        restoreGate.supersede()
        tabs = state.tabs
        selectedTabID = state.selectedTabID
        canRestart = state.canRestart && (selectedTab?.capabilities == nil || selectedTab?.canResume == true)
        supportsSessionOps = state.supportsSessionOps
        prompt = state.prompt
        // Never retain an approval while displaying a different or disconnected tab.
        if let name = state.mac, !name.isEmpty {
            macName = name
            rememberMacName(name)
        }
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
            // A replacement event may precede the restart receipt. Keep the old
            // unsent work until that same Mac/connection proves the replacement.
            var unsentIDs = ids
            if let pending { unsentIDs.insert(pending.tabID) }
            drafts = drafts.filter { unsentIDs.contains($0.key) }
            attachments = attachments.filter { unsentIDs.contains($0.key) }
            sessionReferences = sessionReferences.filter { unsentIDs.contains($0.key) }
        }
        scheduleRefresh()
        scheduleSave()
        reflectLiveActivity()
    }

    /// Streamed output is formatted and styled here, off the main thread. Each refresh
    /// takes the next generation; a result lands only if it is newer than the output
    /// on screen and was built for the Mac, tab and mode still on screen.
    @ObservationIgnored private let worker = OutputWorker { ReadableOutput.bundled() }
    @ObservationIgnored private var outputGeneration = 0
    @ObservationIgnored private var shownGeneration = 0

    /// Output changes arrive many times a second; one repaint per burst is enough.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            let snapshot = self.outputSnapshot()
            let key = (self.activeMacID, self.selectedTabID, self.rawMode)
            self.outputGeneration += 1
            let generation = self.outputGeneration
            guard let next = await self.worker.render(snapshot, generation: generation),
                generation > self.shownGeneration
            else { return }
            // The tab or the mode changed meanwhile: build again for what is on screen now.
            guard key == (self.activeMacID, self.selectedTabID, self.rawMode) else { return self.scheduleRefresh() }
            self.show(next, from: snapshot, generation: generation)
        }
    }

    /// Builds the output at once, on the main thread; a result still on the worker is then dropped.
    func refreshOutput() {
        outputGeneration += 1
        let snapshot = outputSnapshot()
        show(snapshot.render(with: formatter), from: snapshot, generation: outputGeneration)
    }

    private func outputSnapshot() -> OutputSnapshot {
        let screen = selectedTabID.flatMap { screens[$0] }
        let history = screen == nil ? selectedTabID.flatMap { histories[$0] } : nil
        return OutputSnapshot(screen: screen, history: history, raw: rawMode)
    }

    private func show(_ next: StyledText, from snapshot: OutputSnapshot, generation: Int) {
        shownGeneration = generation
        let colours = snapshot.screen?.palette ?? []
        let fg = snapshot.screen?.foreground ?? ""
        let bg = snapshot.screen?.background ?? ""
        if next != styledOutput || colours != palette || fg != themeForeground || bg != themeBackground {
            styledOutput = next
            palette = colours
            themeForeground = fg
            themeBackground = bg
            output = next.text
            outputRevision += 1
        }
        if !bg.isEmpty, bg != appearanceGround { appearanceGround = bg }
        restoreGate.endWait()
    }

    /// The Mac's name goes into the pairing, so the picker can show it before connecting.
    private func rememberMacName(_ name: String) {
        guard var current = credential, current.name != name else { return }
        current.name = name
        credential = current
        if let index = macs.firstIndex(where: { $0.id == current.id }) { macs[index] = current }
        CredentialStore.save(current, select: false)
    }

    // MARK: Cache

    /// Read, decoded and styled off the main actor, starting at once. It lands only on
    /// the screen it was read for: the same Mac, before anything live or another Mac
    /// replaced it. At launch, with a cache on disk, the screen waits for it rather
    /// than showing an empty Mac, but never longer than `RestoreGate.patience`.
    private func restoreCache(for credential: PairingCredential, awaitCache: Bool) {
        // Light or dark from the first frame, as the cached screen will be, so the wait's cover matches it.
        let ground = ScreenCache.ground(for: credential)
        if !ground.isEmpty { appearanceGround = ground }
        let ticket = restoreGate.begin(
            macID: credential.id, awaited: awaitCache && ScreenCache.hasCache(for: credential))
        if awaitingCache {
            Task { [weak self] in
                try? await Task.sleep(for: RestoreGate.patience)
                self?.restoreGate.finish(ticket)
            }
        }
        outputGeneration += 1
        let generation = outputGeneration
        let raw = rawMode
        let worker = worker
        ScreenCache.read(for: credential) { [weak self] cached in
            guard let cached else {
                Task { @MainActor [weak self] in self?.landCache(nil, styled: nil, ticket: ticket) }
                return
            }
            let snapshot = OutputSnapshot(
                screen: cached.selectedTabID.flatMap { cached.screens[$0] }, history: nil, raw: raw)
            worker.submit(snapshot, generation: generation) { [weak self] styled in
                Task { @MainActor [weak self] in
                    self?.landCache(cached, styled: styled.map { ($0, snapshot, generation) }, ticket: ticket)
                }
            }
        }
    }

    /// Tabs and output in one turn. Output styled for a mode or a generation that is
    /// no longer on screen is built again here.
    private func landCache(
        _ cached: CachedScreen?, styled: (StyledText, OutputSnapshot, Int)?, ticket: RestoreGate.Ticket
    ) {
        // A stale restore leaves the wait to what replaced it.
        guard restoreGate.isCurrent(ticket, activeMacID: activeMacID) else { return }
        defer { restoreGate.finish(ticket) }
        guard let cached else { return }
        tabs = cached.tabs
        for tab in cached.tabs where sessionReferences[tab.id] == nil {
            sessionReferences[tab.id] = tab.sessionReference
        }
        selectedTabID = cached.selectedTabID
        macName = cached.mac
        screens = cached.screens
        cachedAt = cached.savedAt
        if let (next, snapshot, generation) = styled, snapshot.raw == rawMode, generation > shownGeneration {
            show(next, from: snapshot, generation: generation)
        } else {
            refreshOutput()
        }
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
        let key = RemoteCrypto.randomKey()
        macs = [
            PairingCredential(id: "demo-mac-1", origin: URL(string: "https://remote.sigilapp.dev")!, room: String(repeating: "0", count: 32), deviceKey: key, ticket: nil, name: "Studio"),
            PairingCredential(id: "demo-mac-2", origin: URL(string: "https://remote.sigilapp.dev")!, room: String(repeating: "1", count: 32), deviceKey: key, ticket: nil, name: "MacBook Air"),
        ]
        activeMacID = "demo-mac-1"
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
        if phase != .connected { invalidateCommand() }
        switch phase {
        case .connected:
            if !sendMayBeIncomplete { errorMessage = nil }
            credential = connection.credential
            streaming = false
            if foreground { Task { await startStreaming() } }
        case .connecting:
            pendingRestart = nil
            prompt = nil
            freshHandshake = true
            streaming = false
            pollTask?.cancel()
            if !foreground { connection.stop() }
        case .offline, .revoked:
            prompt = nil
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
            restartedFrom: restarted == nil ? nil : tabID, restartedTo: restarted, restartedSession: reply.restartedSession)
    }

    func connection(_ connection: RemoteConnection, didReceiveEvent reply: RemoteReply) {
        guard let state = reply.state else { return }
        apply(state, earlier: nil, olderRows: false, restartedFrom: nil, restartedTo: nil)
    }

    func connection(_ connection: RemoteConnection, didSave credential: PairingCredential) {
        var kept = credential
        if let known = macs.first(where: { $0.id == credential.id }), kept.name == nil { kept.name = known.name }
        var list = CredentialStore.loadList()
        // An unavailable Keychain must not drop pairings already held in memory.
        for mac in macs { list.upsert(mac, select: false) }
        list.upsert(kept)
        if !CredentialStore.save(list) {
            errorMessage = "Could not save this pairing. It ends when the app closes."
        }
        self.credential = kept
        macs = list.macs
        activeMacID = kept.id
        hasPairing = true
        macAddress = kept.origin.host
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
            ], yes: "1", no: "3", operation: "Run scripts/test.sh in the selected project.")
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
        // Sigil Dark, or Sigil Light with -demoLight, so both appearances can be shot.
        if ProcessInfo.processInfo.arguments.contains("-demoLight") {
            return RemoteScreen(
                tab: "demo-1", gen: 1, alt: nil, first: 0, end: rows.count, rows: rows,
                palette: [
                    "1f2124", "be2130", "007836", "a76200", "005ecc", "9637ab", "007690", "62656b",
                    "9a9da3", "d7333d", "028c43", "be7200", "0070dd", "a94bbe", "0089a6", "111214",
                ], fg: "1f2124", bg: "fafafb")
        }
        return RemoteScreen(
            tab: "demo-1", gen: 1, alt: nil, first: 0, end: rows.count, rows: rows,
            palette: [
                "313236", "ee5c61", "3cbb72", "f09a2e", "3d9aff", "c571d8", "16a6c7", "a5a8ad",
                "6c6f75", "fe8a89", "75d697", "f7c56d", "7ec0ff", "d9a3e6", "73c8e1", "f2f3f4",
            ], fg: "f2f3f4", bg: "17181a")
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
