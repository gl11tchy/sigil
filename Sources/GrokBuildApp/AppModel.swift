import AppKit
import Foundation
import GrokBuildKit
import Observation

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

    init(settings: AppSettings = AppSettings(), store: SessionStore = SessionStore()) {
        self.settings = settings
        self.store = store
    }

    func onAppear() {
        store.start()
        if tabs.isEmpty, settings.executableExists {
            newTab(in: URL(fileURLWithPath: settings.defaultDirectory))
        }
    }

    var selectedTab: TerminalTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    /// The directory a new tab should open in: the current tab's, else the remembered one.
    var currentDirectory: URL {
        selectedTab?.workingDirectory ?? URL(fileURLWithPath: settings.defaultDirectory)
    }

    // MARK: - Sidebar

    /// Restrict the sidebar to conversations started in the current tab's folder.
    var scopeToCurrentFolder = false

    /// Conversations for the sidebar: newest first, one-shot noise filtered out,
    /// optionally scoped to the folder the current tab is working in.
    var sidebarSessions: [GrokSession] {
        var result = store.search(searchText)
        if !settings.showEmptySessions {
            result = result.filter(isReal)
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
        settings.defaultDirectory = spec.workingDirectory.path
        let id = tab.id
        tab.start(isSelected: { [weak self] in self?.selectedTabID == id })
        return tab
    }

    func closeTab(_ id: TerminalTab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminate()
        tabs.remove(at: index)
        if selectedTabID == id {
            let next = min(index, tabs.count - 1)
            selectedTabID = tabs.indices.contains(next) ? tabs[next].id : nil
        }
    }

    func closeSelectedTab() {
        if let selectedTabID { closeTab(selectedTabID) }
    }

    func select(_ id: TerminalTab.ID) {
        selectedTabID = id
        tabs.first { $0.id == id }?.hasUnseenActivity = false
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
    }

    /// Quit path: no `grok` process may outlive the app, and there is no run loop
    /// left to finish an asynchronous kill.
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

    /// Writes `grok export <id>` to a file the user picks.
    func exportTranscript(_ session: GrokSession) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.title).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let process = Process()
        process.executableURL = settings.executableURL
        process.arguments = ["export", session.id, url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSAlert(error: error).runModal()
        }
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
