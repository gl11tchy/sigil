import AppKit
import Darwin
import Foundation
import Observation
import SigilKit
import UniformTypeIdentifiers
import os

/// Window-level state: the open tabs, the session sidebar, and the actions the menus call.
@MainActor
@Observable
final class AppModel {

    typealias TrashConversation = (URL) throws -> Void
    typealias ErrorPresenter = (Error) -> Void

    let settings: AppSettings
    let store: SessionStore

    private(set) var tabs: [TerminalTab] = []
    var selectedTabID: TerminalTab.ID? {
        didSet {
            if oldValue != selectedTabID {
                hideFindBarOnTabSwitch(previousID: oldValue)
            }
        }
    }
    var searchText: String = ""
    var isShowingNewSessionSheet = false
    /// Find-in-terminal bar for the selected tab.
    var isFindBarVisible = false
    var findQuery = ""
    var findMatchIndex = 0
    var findMatchCount = 0
    /// The thread viewer can be collapsed for a full-width terminal.
    var isSidebarVisible = true
    /// Bumped by Find Conversations so the search field takes focus even when
    /// the sidebar just became visible, or already had it.
    private(set) var searchFocusToken = 0

    /// True while this process owns the tab-messaging socket.
    private(set) var isTabMessagingAvailable = false
    /// Locks Settings while the global Grok registration and local socket move together.
    private(set) var isTabMessagingChangeInProgress = false
    private(set) var tabMessagingError: String?
    private var tabMessagingNeedsReconcile = false
    private var tabBridge: TabBridge?
    private var didAppear = false
    private var didLoadOpenTabsSnapshot = false
    private var isRestoringTabs = false
    /// Saved entries that are temporarily unavailable stay here instead of being erased.
    private var deferredOpenTabs: [OpenTabsSnapshot.Entry] = []
    private var deferredSelectedEntry: OpenTabsSnapshot.Entry?
    /// Older snapshots saved only an ID. Keep it until the first matching tab
    /// can be restored or the user makes a new selection.
    private var deferredLegacySelectedSessionID: String?
    private let trashConversation: TrashConversation
    private let presentError: ErrorPresenter

    init(
        settings: AppSettings = AppSettings(),
        store: SessionStore = SessionStore(),
        trashConversation: @escaping TrashConversation = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        presentError: @escaping ErrorPresenter = { error in
            NSAlert(error: error).runModal()
        }
    ) {
        self.settings = settings
        self.store = store
        self.trashConversation = trashConversation
        self.presentError = presentError
    }

    func onAppear() async {
        guard !didAppear else { return }
        didAppear = true
        if Self.isSmokeTest { return }
        store.start()
        await reconcileTabMessaging()
        restoreOpenTabs()
    }

    var selectedTab: TerminalTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// The directory a new tab should open in: the current tab's, else the remembered one.
    var currentDirectory: URL {
        if let directory = selectedTab?.workingDirectory, Self.isUsableDirectory(directory) {
            return directory
        }
        let stored = settings.defaultDirectory
        if Self.isUsableDirectory(URL(fileURLWithPath: stored)) {
            return URL(fileURLWithPath: stored)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Sidebar

    /// Restrict the sidebar to conversations started in the current tab's folder.
    var scopeToCurrentFolder = false

    /// Conversations for the sidebar: newest first, one-shot noise filtered out,
    /// optionally scoped to the folder the current tab is working in.
    var sidebarSessions: [GrokSession] {
        var result = store.search(searchText)
        if !settings.showEmptySessions {
            // A session you have open is always worth listing, even before the CLI
            // has written a summary for it. Otherwise the row marking the
            // conversation on screen is the one row the list refuses to show.
            result = result.filter { isReal($0) || isOpen($0) }
        }
        if scopeToCurrentFolder {
            let folder = currentDirectory.resolvingSymlinksInPath().path
            result = result.filter { Self.samePath($0.cwd, folder) }
        }
        return result
    }

    /// A session worth listing: it has a summary, or more than the opening exchange.
    private func isReal(_ session: GrokSession) -> Bool {
        !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.messageCount > 2
    }

    func isOpen(_ session: GrokSession) -> Bool {
        tabs.contains { tabMatches($0, sessionID: session.id, cwd: session.cwd) }
    }

    func isActive(_ session: GrokSession) -> Bool {
        guard let selectedTab else { return false }
        return tabMatches(selectedTab, sessionID: session.id, cwd: session.cwd)
    }

    func shouldWarnBeforeDeleting(_ session: GrokSession) -> Bool {
        tabs.contains {
            tabMatches($0, sessionID: session.id, cwd: session.cwd)
                && $0.shouldWarnBeforeStopping
        }
    }

    func isRunning(_ session: GrokSession) -> Bool {
        tabs.contains {
            tabMatches($0, sessionID: session.id, cwd: session.cwd) && $0.isRunning
        }
    }

    func sessionKey(_ session: GrokSession) -> String {
        Self.entryKey(.init(sessionID: session.id, cwd: session.cwd))
    }

    /// A tab's label. New sessions start out named after their folder; once the CLI
    /// writes a summary for them, the store supplies the real conversation name.
    func title(for tab: TerminalTab) -> String {
        if let id = tab.sessionID,
            let session = store.sessions.first(where: {
                $0.id == id && Self.samePath($0.cwd, tab.workingDirectory.path)
            }),
            !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return session.title
        }
        return tab.title
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(in directory: URL, model: String? = nil, effort: String? = nil) -> TerminalTab? {
        guard settings.executableExists else {
            showError(title: "Grok CLI is unavailable", message: "Choose it in Settings, then try again.")
            return nil
        }
        guard Self.isUsableDirectory(directory) else {
            showError(title: "Folder is unavailable", message: "Choose another folder.")
            return nil
        }
        let spec = GrokLaunchSpec(
            executable: settings.executableURL,
            workingDirectory: directory,
            mode: .new(sessionID: UUID()),
            model: (model ?? settings.model).nilIfEmpty,
            reasoningEffort: (effort ?? settings.effort).nilIfEmpty
        )
        return add(spec)
    }

    /// Opens `session`, focusing the tab that already has it when there is one.
    func open(_ session: GrokSession) {
        if let existing = tabs.first(where: {
            tabMatches($0, sessionID: session.id, cwd: session.cwd)
        }) {
            select(existing.id)
            return
        }
        guard settings.executableExists else {
            showError(title: "Grok CLI is unavailable", message: "Choose it in Settings, then try again.")
            return
        }
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        guard Self.isUsableDirectory(workingDirectory) else {
            showError(
                title: "Folder is unavailable",
                message: "Restore the folder, then try again."
            )
            return
        }
        let spec = GrokLaunchSpec(
            executable: settings.executableURL,
            workingDirectory: workingDirectory,
            mode: .resume(sessionID: session.id),
            model: settings.model.nilIfEmpty,
            reasoningEffort: settings.effort.nilIfEmpty
        )
        let tab = add(spec)
        tab.sessionTitle = session.title
    }

    @discardableResult
    private func add(_ spec: GrokLaunchSpec) -> TerminalTab {
        let tabID = UUID()
        let tab = TerminalTab(id: tabID, spec: tagged(spec, tabID: tabID), settings: settings)
        tab.onUnseenActivityChange = { [weak self] in self?.refreshDockIndicator() }
        tabs.append(tab)
        selectedTabID = tab.id
        if !isRestoringTabs { clearDeferredSelection() }
        if !isRestoringTabs { rememberDefaultDirectory(spec.workingDirectory) }
        let id = tab.id
        tab.start(isSelected: { [weak self] in
            self?.selectedTabID == id && NSApp.isActive
        })
        attachBridge(to: tab)
        if !isRestoringTabs { persistOpenTabs() }
        return tab
    }

    /// Reopens the same conversation in place so the tab does not jump or lose selection.
    func restartTab(id: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard settings.executableExists else {
            showError(title: "Grok CLI is unavailable", message: "Choose it in Settings, then try again.")
            return
        }
        let old = tabs[index]
        // `.new` tabs already have a UUID the CLI wrote a session directory for.
        guard let sessionID = old.sessionID else { return }
        let wasSelected = selectedTabID == old.id
        tabBridge?.noteTabClosed(id: old.id)
        old.terminateAndWait()
        let tab = replacementTab(for: old, sessionID: sessionID)
        tabs[index] = tab
        if wasSelected { selectedTabID = tab.id }
        persistOpenTabs()
    }

    /// Builds a fresh process for a stopped tab without changing its position,
    /// title, per-tab launch options, or current selection.
    private func replacementTab(for old: TerminalTab, sessionID: String) -> TerminalTab {
        var spec = old.spec
        spec.executable = settings.executableURL
        spec.mode = .resume(sessionID: sessionID)
        spec.bridgeTabID = nil
        spec.bridgeSocketPath = nil
        let tabID = UUID()
        let tab = TerminalTab(id: tabID, spec: tagged(spec, tabID: tabID), settings: settings)
        tab.onUnseenActivityChange = { [weak self] in self?.refreshDockIndicator() }
        tab.sessionTitle = old.sessionTitle
        tab.restoreUnseenActivity(from: old)
        let newID = tab.id
        tab.start(isSelected: { [weak self] in
            self?.selectedTabID == newID && NSApp.isActive
        })
        attachBridge(to: tab)
        return tab
    }

    func closeTab(_ id: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabBridge?.noteTabClosed(id: id)
        // Do not let a quick reopen overlap two Grok processes on one session.
        tabs[index].terminateAndWait()
        tabs.remove(at: index)
        if selectedTabID == id {
            clearDeferredSelection()
            let next = min(index, tabs.count - 1)
            if tabs.indices.contains(next) {
                select(tabs[next].id)
            } else {
                selectedTabID = nil
            }
        }
        refreshDockIndicator()
        persistOpenTabs()
    }

    /// User-facing close: warn when the agent is mid-turn so a click does not kill work.
    func requestCloseTab(_ id: TerminalTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.shouldWarnBeforeStopping {
            let alert = NSAlert()
            alert.messageText = "This session is still working."
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        closeTab(id)
    }

    func closeSelectedTab() {
        if let selectedTabID { requestCloseTab(selectedTabID) }
    }

    func select(_ id: TerminalTab.ID) {
        selectedTabID = id
        clearDeferredSelection()
        tabs.first { $0.id == id }?.clearUnseenActivity()
        refreshDockIndicator()
        persistOpenTabs()
        DispatchQueue.main.async { [weak self] in
            self?.tabs.first { $0.id == id }?.controller.focus()
        }
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    func cycleTab(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    func closeAllTabs() {
        for tab in tabs {
            tabBridge?.noteTabClosed(id: tab.id)
            tab.terminateAndWait()
        }
        tabs.removeAll()
        selectedTabID = nil
        deferredOpenTabs.removeAll()
        clearDeferredSelection()
        refreshDockIndicator()
        persistOpenTabs()
    }

    /// Quit path: no `grok` process may outlive the app, and there is no run loop
    /// left to finish an asynchronous kill. Does not persist — the last user
    /// mutation already wrote the tabs that should come back next launch.
    func closeAllTabsAndWait() {
        stopTabMessaging()
        for tab in tabs { tab.terminateAndWait() }
        tabs.removeAll()
        selectedTabID = nil
        refreshDockIndicator()
    }

    // MARK: - Tab messaging

    /// Moves the Grok registration, listener, and saved switch as one operation.
    /// Tabs already open keep their original environment, so only new tabs can message.
    func setTabMessaging(enabled: Bool) async throws {
        guard !isTabMessagingChangeInProgress else {
            throw TabMessagingChangeError.inProgress
        }
        guard enabled != settings.isTabMessagingEnabled else { return }
        isTabMessagingChangeInProgress = true
        tabMessagingError = nil
        defer { finishTabMessagingChange() }

        do {
            if enabled {
                try startTabMessaging()
                do {
                    try await installTabMessagingRegistration()
                } catch {
                    stopTabMessaging()
                    throw error
                }
            } else {
                // Remove the global entry before stopping the working local server.
                // A failed removal therefore leaves all three states consistently on.
                try await removeTabMessagingRegistration()
                stopTabMessaging()
            }
            settings.isTabMessagingEnabled = enabled
        } catch {
            let text = error.localizedDescription
            tabMessagingError = text
            Self.bridgeLog.error("Tab messaging change failed: \(text, privacy: .public)")
            throw error
        }
    }

    /// Repairs an absolute helper path after the app moves and refuses a half-on state.
    private func reconcileTabMessaging() async {
        guard !isTabMessagingChangeInProgress else { return }
        isTabMessagingChangeInProgress = true
        defer { finishTabMessagingChange() }
        guard settings.isTabMessagingEnabled else {
            stopTabMessaging()
            return
        }
        do {
            try startTabMessaging()
        } catch {
            // A second Sigil may own the socket and the shared registration.
            // Do not remove or disable that working copy.
            tabMessagingError = error.localizedDescription
            Self.bridgeLog.error(
                "Tab messaging could not start: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        do {
            try await installTabMessagingRegistration()
            tabMessagingError = nil
        } catch {
            let installError = error
            stopTabMessaging()
            do {
                // If the helper path could not be repaired, remove the old global
                // entry before showing the switch as off.
                try await removeTabMessagingRegistration()
                settings.isTabMessagingEnabled = false
                tabMessagingError = installError.localizedDescription
            } catch {
                // Cleanup also failed, so keep the desired setting visible and
                // tell the user the registration still needs repair.
                tabMessagingError =
                    TabMessagingRepairError(
                        installError: installError, cleanupError: error
                    ).localizedDescription
            }
            let repairMessage = self.tabMessagingError ?? installError.localizedDescription
            Self.bridgeLog.error("Tab messaging repair failed: \(repairMessage, privacy: .public)")
        }
    }

    private func startTabMessaging() throws {
        if tabBridge?.isListening == true { return }
        let bridge = TabBridge(model: self)
        do {
            try bridge.start()
            tabBridge = bridge
            isTabMessagingAvailable = true
        } catch BridgeServer.Error.alreadyInUse {
            tabBridge = nil
            isTabMessagingAvailable = false
            throw TabMessagingChangeError.socketInUse
        } catch {
            tabBridge = nil
            isTabMessagingAvailable = false
            throw error
        }
    }

    private func installTabMessagingRegistration() async throws {
        guard let binary = BridgeRegistration.bundledMCPBinary else {
            throw TabMessagingChangeError.helperMissing
        }
        let registration = BridgeRegistration(executable: settings.executableURL)
        try await Task.detached(priority: .userInitiated) {
            try registration.install(mcpBinary: binary)
        }.value
    }

    private func removeTabMessagingRegistration() async throws {
        let registration = BridgeRegistration(executable: settings.executableURL)
        try await Task.detached(priority: .userInitiated) {
            try registration.remove()
        }.value
    }

    private func stopTabMessaging() {
        tabBridge?.stop()
        tabBridge = nil
        isTabMessagingAvailable = false
    }

    private func finishTabMessagingChange() {
        isTabMessagingChangeInProgress = false
        guard tabMessagingNeedsReconcile else { return }
        tabMessagingNeedsReconcile = false
        Task { await reconcileTabMessaging() }
    }

    /// Stamps the tab's identity and the socket onto the launch, so the
    /// `sigil-mcp` server grok starts knows which tab it speaks for. Left off
    /// when messaging is unavailable, which also strips any inherited value.
    private func tagged(_ spec: GrokLaunchSpec, tabID: UUID) -> GrokLaunchSpec {
        guard isTabMessagingAvailable, let bridge = tabBridge else { return spec }
        var tagged = spec
        tagged.bridgeTabID = tabID.uuidString
        tagged.bridgeSocketPath = bridge.socketURL.path
        return tagged
    }

    private func attachBridge(to tab: TerminalTab) {
        let previous = tab.controller.onTerminate
        let id = tab.id
        tab.controller.onTerminate = { [weak self] code in
            previous?(code)
            self?.tabBridge?.noteTabExited(id: id)
        }
    }

    private static let bridgeLog = Logger(subsystem: "com.gl11tchy.sigil", category: "bridge")

    private func refreshDockIndicator() {
        NSApp.dockTile.badgeLabel = tabs.contains(where: \.hasUnseenActivity) ? "•" : nil
        NSApp.dockTile.display()
    }

    /// Clear the selected tab's badge once its contents are visible again.
    func appDidBecomeActive() {
        selectedTab?.clearUnseenActivity()
        refreshDockIndicator()
    }

    func executableConfigurationChanged() async {
        guard settings.executableExists else { return }
        restoreOpenTabs()
        if settings.isTabMessagingEnabled {
            if isTabMessagingChangeInProgress {
                tabMessagingNeedsReconcile = true
            } else {
                await reconcileTabMessaging()
            }
        }
    }

    // MARK: - Appearance

    func adjustFontSize(by delta: CGFloat) {
        settings.fontSize = min(32, max(8, settings.fontSize + delta))
        applyAppearance()
    }

    func resetFontSize() {
        settings.fontSize = 13
        applyAppearance()
    }

    func applyAppearance() {
        for tab in tabs {
            tab.controller.setFontSize(settings.fontSize)
            tab.controller.apply(theme: settings.theme)
        }
    }

    // MARK: - Session actions

    func revealInFinder(_ session: GrokSession) {
        guard Self.isUsableDirectory(URL(fileURLWithPath: session.cwd)) else {
            showError(title: "Folder is unavailable", message: "Restore the folder, then try again.")
            return
        }
        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd) else {
            showError(title: "Could not open Finder", message: "Try again.")
            return
        }
    }

    func copySessionID(_ session: GrokSession) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
    }

    /// Shows the thread list if it is hidden, then asks the search field for focus.
    func focusSidebarSearch() {
        if !isSidebarVisible { isSidebarVisible = true }
        searchFocusToken += 1
    }

    // MARK: - Find

    func toggleFindBar() {
        if isFindBarVisible {
            dismissFindBar()
        } else {
            guard selectedTab != nil else { return }
            isFindBarVisible = true
        }
    }

    func dismissFindBar() {
        selectedTab?.controller.clearFind()
        selectedTab?.controller.focus()
        isFindBarVisible = false
        findQuery = ""
        findMatchIndex = 0
        findMatchCount = 0
    }

    func applyFindQuery() {
        guard isFindBarVisible else { return }
        selectedTab?.controller.setFindQuery(findQuery)
        refreshFindCounts()
    }

    func findNextInTerminal() {
        selectedTab?.controller.findNext()
        refreshFindCounts()
    }

    func findPreviousInTerminal() {
        selectedTab?.controller.findPrevious()
        refreshFindCounts()
    }

    private func refreshFindCounts() {
        findMatchIndex = selectedTab?.controller.findMatchIndex ?? 0
        findMatchCount = selectedTab?.controller.findMatchCount ?? 0
    }

    /// Switching tabs hides the bar and clears find on the tab that had it.
    private func hideFindBarOnTabSwitch(previousID: TerminalTab.ID?) {
        guard isFindBarVisible else { return }
        if let previousID, let tab = tabs.first(where: { $0.id == previousID }) {
            tab.controller.clearFind()
        }
        isFindBarVisible = false
        findQuery = ""
        findMatchIndex = 0
        findMatchCount = 0
    }

    /// Closes any tab showing `session`, then moves its directory to the Trash.
    /// A permanent delete would be unrecoverable from here.
    @discardableResult
    func deleteConversation(_ session: GrokSession) -> Bool {
        let matchingTabs = tabs.filter {
            tabMatches($0, sessionID: session.id, cwd: session.cwd)
        }
        let stoppedTabs = matchingTabs.filter(\.isRunning)
        let selectionBeforeDelete = selectedTabID
        // Keep the tab objects and saved snapshot until Trash succeeds. If it
        // fails, restart the stopped processes and leave the user's layout intact.
        for tab in stoppedTabs {
            tabBridge?.noteTabClosed(id: tab.id)
            tab.terminateAndWait()
        }
        do {
            try trashConversation(session.directory)
            let removedIDs = Set(matchingTabs.map(\.id))
            for tab in matchingTabs where !stoppedTabs.contains(where: { $0.id == tab.id }) {
                tabBridge?.noteTabClosed(id: tab.id)
            }
            let selectedWasRemoved = selectedTabID.map(removedIDs.contains) ?? false
            let firstRemovedIndex = tabs.firstIndex { removedIDs.contains($0.id) }
            tabs.removeAll { removedIDs.contains($0.id) }
            deferredOpenTabs.removeAll {
                Self.entryMatches($0, sessionID: session.id, cwd: session.cwd)
            }
            if let deferredSelectedEntry,
                Self.entryMatches(deferredSelectedEntry, sessionID: session.id, cwd: session.cwd)
            {
                clearDeferredSelection()
            } else if deferredLegacySelectedSessionID == session.id {
                deferredLegacySelectedSessionID = nil
            }
            if selectedWasRemoved {
                let candidate = min(firstRemovedIndex ?? 0, max(tabs.count - 1, 0))
                if tabs.indices.contains(candidate) {
                    select(tabs[candidate].id)
                } else {
                    selectedTabID = nil
                }
            }
            refreshDockIndicator()
            persistOpenTabs()
            Task { await store.reload() }
            return true
        } catch {
            var replacementForSelection: TerminalTab.ID?
            for old in stoppedTabs {
                guard let sessionID = old.sessionID,
                    let index = tabs.firstIndex(where: { $0.id == old.id })
                else { continue }
                let replacement = replacementTab(for: old, sessionID: sessionID)
                tabs[index] = replacement
                if old.id == selectionBeforeDelete { replacementForSelection = replacement.id }
            }
            selectedTabID = replacementForSelection ?? selectionBeforeDelete
            persistOpenTabs()
            presentError(error)
            return false
        }
    }

    /// Writes `grok export <id>` to a file the user picks.
    ///
    /// The save panel stays on the main thread; the CLI itself runs off it so a
    /// long export cannot freeze the window.
    func exportTranscript(_ session: GrokSession) {
        exportTranscript(
            sessionID: session.id,
            title: session.title,
            workingDirectory: URL(fileURLWithPath: session.cwd)
        )
    }

    var canExportSelectedTranscript: Bool { selectedTab?.sessionID != nil }

    func exportSelectedTranscript() {
        guard let tab = selectedTab, let sessionID = tab.sessionID else { return }
        exportTranscript(
            sessionID: sessionID,
            title: title(for: tab),
            workingDirectory: tab.workingDirectory
        )
    }

    private func exportTranscript(sessionID: String, title: String, workingDirectory: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.transcriptFilename(for: title)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let executable = settings.executableURL
        Task {
            do {
                try await Self.runTranscriptExport(
                    executable: executable,
                    sessionID: sessionID,
                    output: url,
                    workingDirectory: workingDirectory
                )
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                presentError(error)
            }
        }
    }

    static func runTranscriptExport(
        executable: URL,
        sessionID: String,
        output: URL,
        workingDirectory: URL,
        timeout: Duration = .seconds(300)
    ) async throws {
        let task = Task.detached(priority: .userInitiated) {
            let temporaryOutput = output.deletingLastPathComponent().appendingPathComponent(
                ".\(output.deletingPathExtension().lastPathComponent).sigil-\(UUID().uuidString).md"
            )
            try? FileManager.default.removeItem(at: temporaryOutput)
            defer { try? FileManager.default.removeItem(at: temporaryOutput) }

            let process = Process()
            process.executableURL = executable
            process.arguments = ["export", sessionID, temporaryOutput.path]
            process.currentDirectoryURL = workingDirectory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let captured = TranscriptOutputCapture()
            let readerFinished = DispatchGroup()
            readerFinished.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readerFinished.leave() }
                do {
                    while let data = try pipe.fileHandleForReading.read(upToCount: 16_384),
                        !data.isEmpty
                    {
                        captured.append(data)
                    }
                } catch {
                    // Closing the handle is how the timeout path stops a child
                    // process that inherited the pipe.
                }
            }
            do {
                try process.run()
                try? pipe.fileHandleForWriting.close()
            } catch {
                try? pipe.fileHandleForWriting.close()
                try? pipe.fileHandleForReading.close()
                await waitForReader(readerFinished, handle: pipe.fileHandleForReading)
                throw error
            }
            let deadline = ContinuousClock.now + timeout
            while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            let timedOut = process.isRunning && ContinuousClock.now >= deadline
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(500))
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            await waitForReader(readerFinished, handle: pipe.fileHandleForReading)
            let text = captured.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if Task.isCancelled { throw CancellationError() }
            if timedOut {
                throw TranscriptExportError(status: nil, output: text, timedOut: true)
            }
            guard process.terminationStatus == 0 else {
                throw TranscriptExportError(
                    status: process.terminationStatus, output: text, timedOut: false)
            }

            guard FileManager.default.fileExists(atPath: temporaryOutput.path) else {
                throw TranscriptExportError(
                    status: nil,
                    output: "Export finished without creating a transcript.",
                    timedOut: false
                )
            }
            guard rename(temporaryOutput.path, output.path) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw POSIXError(code)
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func waitForReader(_ group: DispatchGroup, handle: FileHandle) async {
        await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable () -> Void = {
                let shouldResume = resumed.withLock { state in
                    guard !state else { return false }
                    state = true
                    return true
                }
                if shouldResume { continuation.resume() }
            }
            group.notify(queue: .global(qos: .utility), execute: finish)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                guard !resumed.withLock({ $0 }) else { return }
                try? handle.close()
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + 1, execute: finish)
            }
        }
    }

    private static func transcriptFilename(for title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\n\r\0")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Transcript" : String(cleaned.prefix(120))
        return base.lowercased().hasSuffix(".md") ? base : base + ".md"
    }

    // MARK: - Persistence

    /// Reopen saved tabs whose session directories still exist. Never starts a
    /// `.new` session: a launch must not create junk conversations on disk.
    func restoreOpenTabs() {
        if !didLoadOpenTabsSnapshot {
            didLoadOpenTabsSnapshot = true
            let snapshot = settings.openTabs
            deferredOpenTabs = snapshot.tabs
            if let selectedCWD = snapshot.selectedCWD, let selectedID = snapshot.selectedSessionID {
                deferredSelectedEntry = .init(sessionID: selectedID, cwd: selectedCWD)
                deferredLegacySelectedSessionID = nil
            } else {
                deferredSelectedEntry = nil
                deferredLegacySelectedSessionID = snapshot.selectedSessionID
            }
        }
        guard settings.executableExists else { return }
        let candidates = deferredOpenTabs
        deferredOpenTabs.removeAll()
        isRestoringTabs = true
        defer {
            isRestoringTabs = false
            persistOpenTabs()
        }
        var restoredSelection: TerminalTab.ID?
        for entry in candidates {
            if tabs.contains(where: {
                tabMatches($0, sessionID: entry.sessionID, cwd: entry.cwd)
            }) {
                continue
            }
            let directory = GrokPaths.sessionDirectory(cwd: entry.cwd, sessionID: entry.sessionID)
            let workingDirectory = URL(fileURLWithPath: entry.cwd)
            guard Self.isUsableDirectory(directory), Self.isUsableDirectory(workingDirectory) else {
                deferredOpenTabs.append(entry)
                continue
            }
            let spec = GrokLaunchSpec(
                executable: settings.executableURL,
                workingDirectory: workingDirectory,
                mode: .resume(sessionID: entry.sessionID),
                model: settings.model.nilIfEmpty,
                reasoningEffort: settings.effort.nilIfEmpty
            )
            let tab = add(spec)
            if deferredSelectedEntry.map({ Self.sameEntry($0, entry) }) == true
                || (deferredSelectedEntry == nil
                    && deferredLegacySelectedSessionID == entry.sessionID
                    && restoredSelection == nil)
            {
                restoredSelection = tab.id
            }
        }
        if let restoredSelection {
            select(restoredSelection)
        }
    }

    private func persistOpenTabs() {
        guard !isRestoringTabs else { return }
        var entries = tabs.compactMap { tab -> OpenTabsSnapshot.Entry? in
            guard let sessionID = tab.sessionID else { return nil }
            return OpenTabsSnapshot.Entry(sessionID: sessionID, cwd: tab.workingDirectory.path)
        }
        let liveKeys = Set(entries.map(Self.entryKey))
        entries.append(
            contentsOf: deferredOpenTabs.filter {
                !liveKeys.contains(Self.entryKey($0))
            }
        )
        let liveSelection = selectedTab.flatMap { tab -> OpenTabsSnapshot.Entry? in
            guard let sessionID = tab.sessionID else { return nil }
            return .init(sessionID: sessionID, cwd: tab.workingDirectory.path)
        }
        let exactSelection = deferredSelectedEntry ?? liveSelection
        settings.openTabs = OpenTabsSnapshot(
            tabs: entries,
            selectedSessionID: exactSelection?.sessionID ?? deferredLegacySelectedSessionID,
            selectedCWD: exactSelection?.cwd
        )
    }

    private func rememberDefaultDirectory(_ directory: URL) {
        if isEphemeral(path: directory.path) { return }
        settings.defaultDirectory = directory.path
    }

    private func tabMatches(_ tab: TerminalTab, sessionID: String, cwd: String) -> Bool {
        tab.sessionID == sessionID && Self.samePath(tab.workingDirectory.path, cwd)
    }

    private static func entryMatches(
        _ entry: OpenTabsSnapshot.Entry, sessionID: String, cwd: String
    ) -> Bool {
        entry.sessionID == sessionID && samePath(entry.cwd, cwd)
    }

    private static func sameEntry(
        _ lhs: OpenTabsSnapshot.Entry, _ rhs: OpenTabsSnapshot.Entry
    ) -> Bool {
        entryMatches(lhs, sessionID: rhs.sessionID, cwd: rhs.cwd)
    }

    private static func entryKey(_ entry: OpenTabsSnapshot.Entry) -> String {
        entry.sessionID + "\u{0}" + canonicalPath(entry.cwd)
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private static func canonicalPath(_ path: String) -> String {
        GrokPaths.canonicalPath(path)
    }

    private func clearDeferredSelection() {
        deferredSelectedEntry = nil
        deferredLegacySelectedSessionID = nil
    }

    func pickDirectory(startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? currentDirectory
        panel.prompt = "Open Session Here"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static var isSmokeTest: Bool {
        ProcessInfo.processInfo.environment["SIGIL_SMOKE_TEST"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--smoke-test")
    }

    private static func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func showError(title: String, message: String) {
        presentError(AppActionError(title: title, message: message))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum TabMessagingChangeError: Error, LocalizedError {
    case inProgress
    case helperMissing
    case socketInUse

    var errorDescription: String? {
        switch self {
        case .inProgress: return "Another tab messaging change is still running."
        case .helperMissing: return "This build has no sigil-mcp helper."
        case .socketInUse: return "Another copy of Sigil is already using tab messaging."
        }
    }
}

private struct TabMessagingRepairError: Error, LocalizedError {
    let installError: Error
    let cleanupError: Error

    var errorDescription: String? {
        "Could not repair tab messaging. \(installError.localizedDescription) "
            + "Cleanup also failed: \(cleanupError.localizedDescription)"
    }
}

private struct AppActionError: Error, LocalizedError {
    let title: String
    let message: String

    var errorDescription: String? { title }
    var failureReason: String? { message }
}

private struct TranscriptExportError: Error, LocalizedError, Sendable {
    let status: Int32?
    let output: String
    let timedOut: Bool

    var errorDescription: String? {
        if timedOut { return "Export did not finish within 5 minutes." }
        if !output.isEmpty { return output }
        if let status { return "Export failed with exit code \(status)." }
        return "Export failed."
    }
}

private final class TranscriptOutputCapture: @unchecked Sendable {
    private static let limit = 1_048_576
    private let lock = NSLock()
    private var data = Data()
    private var wasTruncated = false

    func append(_ additional: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, Self.limit - data.count)
        if remaining > 0 { data.append(additional.prefix(remaining)) }
        if additional.count > remaining { wasTruncated = true }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        var result = String(decoding: data, as: UTF8.self)
        if wasTruncated { result += "\n[output truncated]" }
        return result
    }
}
