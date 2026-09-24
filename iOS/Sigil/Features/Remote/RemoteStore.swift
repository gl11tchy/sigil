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
    private(set) var busy = false
    private(set) var loadingEarlier = false
    private(set) var macAddress: String?
    var errorMessage: String?
    var rawMode = false
    var drafts: [String: String] = [:]
    private(set) var attachments: [String: [Attachment]] = [:]

    private(set) var chats: [RemoteChat] = []
    private(set) var chatsTruncated = false
    private(set) var searchingChats = false
    private(set) var projects: [RemoteProject] = []
    private(set) var projectsTruncated = false

    /// Bumped whenever the visible output changes, so the output view can repaint.
    private(set) var outputRevision = 0
    private(set) var output = ""

    let isDemo: Bool
    @ObservationIgnored private let connection = RemoteConnection()
    @ObservationIgnored private var histories: [String: TerminalHistory] = [:]
    @ObservationIgnored private let formatter = ReadableOutput.bundled()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var lastChunkAt = Date.distantPast
    @ObservationIgnored private var freshHandshake = false
    @ObservationIgnored private var foreground = true

    init(isDemo: Bool) {
        self.isDemo = isDemo
        connection.delegate = self
        if isDemo {
            DemoData.seed(self)
        } else if let saved = CredentialStore.load() {
            hasPairing = true
            macAddress = saved.origin.host
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
        connection.stop(forget: true)
        CredentialStore.delete()
        hasPairing = false
        macAddress = nil
        tabs = []
        selectedTabID = nil
        histories = [:]
        drafts = [:]
        attachments = [:]
        chats = []
        projects = []
        errorMessage = nil
        rawMode = false
        refreshOutput()
    }

    // MARK: Lifecycle

    func enterForeground() {
        foreground = true
        guard !isDemo, hasPairing || connection.credential != nil else { return }
        switch phase {
        case .connected: startPolling()
        case .offline: connection.reconnect()
        case .connecting, .revoked: break
        }
    }

    /// iOS suspends the socket in the background anyway; closing it lets the Mac see the phone leave.
    func enterBackground() {
        foreground = false
        pollTask?.cancel()
        guard !isDemo, phase != .revoked else { return }
        connection.stop()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isConnected, self.foreground else { return }
                if !self.busy { _ = try? await self.connection.request("state") }
            }
        }
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

    func newSession(in project: RemoteProject?) {
        perform { _ = try await $0.request("new", text: project?.folder) }
    }

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

    func searchChats(_ query: String) {
        searchToken += 1
        let token = searchToken
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isConnected else {
            chats = []
            chatsTruncated = false
            searchingChats = false
            return
        }
        searchingChats = true
        // The Mac reads 200 characters, and text over 8 KB drops the connection.
        let bounded = Self.utf8Prefix(String(trimmed.prefix(200)), bytes: RemoteRequest.textLimit)
        Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard token == searchToken else { return }
                let reply = try await connection.request("chats", text: bounded)
                guard token == searchToken else { return }
                chats = Array((reply.chats ?? []).prefix(40))
                chatsTruncated = reply.chatsTruncated == true
            } catch is CancellationError {
            } catch {
                if token == searchToken { errorMessage = error.localizedDescription }
            }
            if token == searchToken { searchingChats = false }
        }
    }

    func open(_ chat: RemoteChat) {
        perform { _ = try await $0.request("open", text: chat.folder, name: chat.id) }
    }

    func loadEarlier() {
        guard isConnected, !loadingEarlier, let id = selectedTabID, var bucket = histories[id], !bucket.exhausted
        else { return }
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

    var earlierExhausted: Bool { selectedTabID.flatMap { histories[$0]?.exhausted } ?? true }

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

    fileprivate func apply(_ state: RemoteState, earlier: String?, restartedFrom oldID: String?, restartedTo newID: String?) {
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
        if let id = state.selectedTabID {
            var bucket = histories[id] ?? TerminalHistory()
            bucket.apply(state.terminal)
            if let earlier { bucket.prepend(earlier) }
            histories[id] = bucket
        }
        if complete {
            histories = histories.filter { ids.contains($0.key) }
            drafts = drafts.filter { ids.contains($0.key) }
            attachments = attachments.filter { ids.contains($0.key) }
        }
        refreshOutput()
    }

    func refreshOutput() {
        let raw = selectedTabID.flatMap { histories[$0]?.text } ?? ""
        let next = rawMode ? raw : formatter.format(raw)
        if next != output {
            output = next
            outputRevision += 1
        }
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

    fileprivate func seedDemo(tabs: [RemoteTab], selected: String, terminal: String) {
        hasPairing = true
        phase = .connected
        macAddress = "remote.sigilapp.dev"
        self.tabs = tabs
        selectedTabID = selected
        canRestart = true
        var bucket = TerminalHistory()
        bucket.apply(terminal)
        histories[selected] = bucket
        projects = [
            RemoteProject(name: "sigil", folder: "~/Documents/sigil"),
            RemoteProject(name: "site", folder: "~/Documents/sigil/Site"),
            RemoteProject(name: "relay", folder: "~/Documents/sigil/Sidereal"),
        ]
        refreshOutput()
    }
}

extension RemoteStore: RemoteConnectionDelegate {
    func connection(_ connection: RemoteConnection, didChange phase: RemoteConnection.Phase) {
        self.phase = phase
        switch phase {
        case .connected:
            errorMessage = nil
            if foreground { startPolling() }
        case .connecting:
            freshHandshake = true
            pollTask?.cancel()
        case .offline, .revoked:
            pollTask?.cancel()
        }
    }

    func connection(_ connection: RemoteConnection, didReceive reply: RemoteReply, for action: String, tabID: String?) {
        guard let state = reply.state else { return }
        let restarted = action == "restart" ? reply.restartedTabID.flatMap { $0 != tabID && $0.utf8.count <= 64 ? $0 : nil } : nil
        apply(
            state, earlier: action == "earlier" && tabID == state.selectedTabID ? (reply.earlier ?? "") : nil,
            restartedFrom: restarted == nil ? nil : tabID, restartedTo: restarted)
        if let restarted, let tabID, restarted != tabID {
            drafts[tabID] = nil
        }
    }

    func connection(_ connection: RemoteConnection, didSave credential: PairingCredential) {
        if !CredentialStore.save(credential) {
            errorMessage = "Could not save this pairing. It ends when the app closes."
        }
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
            RemoteTab(id: "demo-1", title: "sigil · iOS companion", status: .working),
            RemoteTab(id: "demo-2", title: "site · pricing copy", status: .idle),
            RemoteTab(id: "demo-3", title: "relay · load test", status: .exited),
        ]
        let terminal = """
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
              PASS history keeps scrolled text
              OK 24

            Next: the session screen and the composer.
            """
        store.seedDemo(tabs: tabs, selected: "demo-1", terminal: terminal)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
