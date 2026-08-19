import AppKit
import Foundation
import SigilKit
import Observation
import UniformTypeIdentifiers

/// Window-level state: the open tabs, the session sidebar, and the actions the menus call.
@MainActor
@Observable
final class AppModel {

    let settings: AppSettings
    let store: SessionStore

    private(set) var tabs: [TerminalTab] = []
    var selectedTabID: TerminalTab.ID?
    var searchText: String = ""
    var isShowingNewSessionSheet = false
    /// The thread viewer can be collapsed for a full-width terminal.
    var isSidebarVisible = true
    /// Bumped by Find Conversations so the search field takes focus even when
    /// the sidebar just became visible, or already had it.
    private(set) var searchFocusToken = 0

    init(settings: AppSettings = AppSettings(), store: SessionStore = SessionStore()) {
        self.settings = settings
        self.store = store
    }

    func onAppear() {
        store.start()
        restoreOpenTabs()
    }

    var selectedTab: TerminalTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// The directory a new tab should open in: the current tab's, else the remembered one.
    var currentDirectory: URL {
        if let directory = selectedTab?.workingDirectory { return directory }
        let stored = settings.defaultDirectory
        if FileManager.default.fileExists(atPath: stored) {
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
            let open = openSessionIDs
            result = result.filter { isReal($0) || open.contains($0.id) }
        }
        if scopeToCurrentFolder {
            let folder = currentDirectory.resolvingSymlinksInPath().path
            result = result.filter { $0.cwd == folder }
        }
        return result
    }

    /// A session worth listing: it has a summary, or more than the opening exchange.
    private func isReal(_ session: GrokSession) -> Bool {
        !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.messageCount > 2
    }

    /// Session IDs currently open in a tab, so the sidebar can mark them.
    var openSessionIDs: Set<String> {
        Set(tabs.compactMap(\.sessionID))
    }

    /// The conversation on screen right now. The sidebar marks this one differently
    /// from the ones that are merely open in a background tab.
    var activeSessionID: String? { selectedTab?.sessionID }

    /// A tab's label. New sessions start out named after their folder; once the CLI
    /// writes a summary for them, the store supplies the real conversation name.
    func title(for tab: TerminalTab) -> String {
        if let id = tab.sessionID,
            let session = store.sessions.first(where: { $0.id == id }),
            !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return session.title
        }
        return tab.title
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(in directory: URL, model: String? = nil, effort: String? = nil) -> TerminalTab {
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
        if let existing = tabs.first(where: { $0.sessionID == session.id }) {
            select(existing.id)
            return
        }
        let spec = GrokLaunchSpec(
            executable: settings.executableURL,
            workingDirectory: URL(fileURLWithPath: session.cwd),
            mode: .resume(sessionID: session.id),
            model: settings.model.nilIfEmpty,
            reasoningEffort: settings.effort.nilIfEmpty
        )
        let tab = add(spec)
        tab.sessionTitle = session.title
    }

    @discardableResult
    private func add(_ spec: GrokLaunchSpec) -> TerminalTab {
        let tab = TerminalTab(spec: spec, settings: settings)
        tabs.append(tab)
        selectedTabID = tab.id
        rememberDefaultDirectory(spec.workingDirectory)
        let id = tab.id
        tab.start(isSelected: { [weak self] in self?.selectedTabID == id })
        persistOpenTabs()
        return tab
    }

    /// Reopens the same conversation in place so the tab does not jump or lose selection.
    func restartTab(id: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let old = tabs[index]
        // `.new` tabs already have a UUID the CLI wrote a session directory for.
        guard let sessionID = old.sessionID else { return }
        old.terminate()
        let spec = GrokLaunchSpec(
            executable: settings.executableURL,
            workingDirectory: old.workingDirectory,
            mode: .resume(sessionID: sessionID),
            model: settings.model.nilIfEmpty,
            reasoningEffort: settings.effort.nilIfEmpty
        )
        let tab = TerminalTab(spec: spec, settings: settings)
        tab.sessionTitle = old.sessionTitle
        tabs[index] = tab
        selectedTabID = tab.id
        let newID = tab.id
        tab.start(isSelected: { [weak self] in self?.selectedTabID == newID })
        persistOpenTabs()
    }

    func closeTab(_ id: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)
        if selectedTabID == id {
            let next = min(index, tabs.count - 1)
            selectedTabID = tabs.indices.contains(next) ? tabs[next].id : nil
        }
        persistOpenTabs()
    }

    /// User-facing close: warn when the agent is mid-turn so a click does not kill work.
    func requestCloseTab(_ id: TerminalTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.activity == .working {
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
        tabs.first { $0.id == id }?.hasUnseenActivity = false
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
        tabs.forEach { $0.terminate() }
        tabs.removeAll()
        selectedTabID = nil
        persistOpenTabs()
    }

    /// Quit path: no `grok` process may outlive the app, and there is no run loop
    /// left to finish an asynchronous kill. Does not persist — the last user
    /// mutation already wrote the tabs that should come back next launch.
    func closeAllTabsAndWait() {
        tabs.forEach { $0.terminateAndWait() }
        tabs.removeAll()
        selectedTabID = nil
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
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
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

    /// Closes any tab showing `session`, then moves its directory to the Trash.
    /// A permanent delete would be unrecoverable from here.
    func deleteConversation(_ session: GrokSession) {
        let openIDs = tabs.compactMap { tab -> TerminalTab.ID? in
            tab.sessionID == session.id ? tab.id : nil
        }
        for id in openIDs { closeTab(id) }
        do {
            try FileManager.default.trashItem(at: session.directory, resultingItemURL: nil)
            Task { await store.reload() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Writes `grok export <id>` to a file the user picks.
    ///
    /// The save panel stays on the main thread; the CLI itself runs off it so a
    /// long export cannot freeze the window.
    func exportTranscript(_ session: GrokSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let executable = settings.executableURL
        let sessionID = session.id
        Task {
            do {
                try await Self.runTranscriptExport(
                    executable: executable, sessionID: sessionID, output: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func runTranscriptExport(
        executable: URL, sessionID: String, output: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["export", sessionID, output.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw TranscriptExportError(status: process.terminationStatus)
            }
        }.value
    }

    // MARK: - Persistence

    /// Reopen saved tabs whose session directories still exist. Never starts a
    /// `.new` session: a launch must not create junk conversations on disk.
    private func restoreOpenTabs() {
        guard tabs.isEmpty, settings.executableExists else { return }
        let snapshot = settings.openTabs
        var restoredSelection: TerminalTab.ID?
        for entry in snapshot.tabs {
            let directory = GrokPaths.sessionDirectory(cwd: entry.cwd, sessionID: entry.sessionID)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let spec = GrokLaunchSpec(
                executable: settings.executableURL,
                workingDirectory: URL(fileURLWithPath: entry.cwd),
                mode: .resume(sessionID: entry.sessionID),
                model: settings.model.nilIfEmpty,
                reasoningEffort: settings.effort.nilIfEmpty
            )
            let tab = add(spec)
            if entry.sessionID == snapshot.selectedSessionID {
                restoredSelection = tab.id
            }
        }
        if let restoredSelection {
            select(restoredSelection)
        }
        persistOpenTabs()
    }

    private func persistOpenTabs() {
        let entries = tabs.compactMap { tab -> OpenTabsSnapshot.Entry? in
            guard let sessionID = tab.sessionID else { return nil }
            return OpenTabsSnapshot.Entry(sessionID: sessionID, cwd: tab.workingDirectory.path)
        }
        settings.openTabs = OpenTabsSnapshot(
            tabs: entries, selectedSessionID: selectedTab?.sessionID)
    }

    private func rememberDefaultDirectory(_ directory: URL) {
        if isEphemeral(path: directory.path) { return }
        settings.defaultDirectory = directory.path
    }

    func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentDirectory
        panel.prompt = "Open Session Here"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct TranscriptExportError: Error, LocalizedError, Sendable {
    let status: Int32
    var errorDescription: String? { "Export failed with exit code \(status)." }
}
