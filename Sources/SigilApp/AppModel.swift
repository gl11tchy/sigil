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
    typealias ConfirmStopWorking = (StopWorkingPrompt) -> Bool

    let settings: AppSettings
    let store: SessionStore
    /// The right-hand utility column: scratch shell and per-conversation notes.
    let panel: RightPanel
    let remoteControl: RemoteControl
    @ObservationIgnored private let kimiKeyStore: any KimiKeyStore
    /// True while the Keychain holds a Kimi API key.
    private(set) var hasKimiAPIKey = false

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
    var isShowingTabList = false
    private(set) var pendingSessionDirectory: URL?
    /// Find-in-terminal bar for the selected tab.
    var isFindBarVisible = false
    /// True when a tab was selected while the main window could not take focus.
    var needsTerminalFocus = false
    /// True when the panel shell was opened before its view reached the window.
    @ObservationIgnored private var needsPanelShellFocus = false
    private let transcriptExports = TranscriptExports()
    /// Grok tabs that kept the old theme because they were busy or held messages.
    @ObservationIgnored private var themeRestartsWhenSettled: Set<TerminalTab.ID> = []
    var findQuery = ""
    var findMatchIndex = 0
    var findMatchCount = 0
    /// The thread viewer can be collapsed for a full-width terminal.
    var isSidebarVisible = true {
        didSet {
            if Self.shouldClearRenameSelectAllOnSidebarHide(
                wasVisible: oldValue, isVisible: isSidebarVisible
            ) {
                clearRenameSelectAllPending()
            }
            if oldValue, !isSidebarVisible { refocusTerminalAfterHiding(.sidebar) }
        }
    }
    /// Set by the sidebar and its divider from their SwiftUI focus, so hiding
    /// the sidebar moves focus only when it leaves with the column.
    @ObservationIgnored var isSidebarFocused = false
    @ObservationIgnored var isSidebarDividerFocused = false
    /// Bumped by Find Conversations so the search field takes focus even when
    /// the sidebar just became visible, or already had it.
    private(set) var searchFocusToken = 0
    /// The last token the sidebar acted on, so a remount does not replay it.
    @ObservationIgnored private var consumedSearchFocusToken = 0

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
    /// Shown before a close, archive or shell restart stops work still running.
    @ObservationIgnored
    var confirmStopWorking: ConfirmStopWorking = { $0.runModal() }
    /// True while the stop prompt is up. Its modal loop still runs main-queue
    /// work, so a theme relaunch waits rather than replace the tab in question.
    @ObservationIgnored private var isAskingToStop = false
    @ObservationIgnored private let registrationRunner: BridgeRegistration.Runner
    @ObservationIgnored private let mcpBinaryOverride: URL?
    @ObservationIgnored private let tabMessagingSocketURL: URL
    @ObservationIgnored private let resolveCanonicalPath: @Sendable (String) -> String
    @ObservationIgnored private var canonicalPathCache: [String: String] = [:]
    @ObservationIgnored private var canonicalCacheTabCount = -1
    @ObservationIgnored private var canonicalCacheSessionCount = -1
    /// Refreshes what a crash report would say Sigil was doing. Observation
    /// ignores it: nothing in the UI reads it.
    @ObservationIgnored private var crashStateTask: Task<Void, Never>?
    /// Shared-list entries another running copy added, with the store's scan
    /// count when this copy first read them. See `awaitsScan`.
    @ObservationIgnored private var sharedArrivals: [String: Int] = [:]
    private(set) var providerInstallations: [CLIProvider: ProviderInstallation] = [:]
    private(set) var checkingProviders: Set<CLIProvider> = []
    typealias ProviderProbe = @Sendable (CLIProvider, URL?) async -> ProviderInstallation
    @ObservationIgnored private let providerProbe: ProviderProbe
    @ObservationIgnored private var providerCheckGeneration = UUID()

    init(
        settings: AppSettings = AppSettings(),
        store: SessionStore = SessionStore(),
        trashConversation: @escaping TrashConversation = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        },
        presentError: @escaping ErrorPresenter = { error in
            NSAlert(error: error).runModal()
        },
        // Optional defaults, coalesced below: Swift 6.1.2 (CI) segfaults in
        // SILGen when these closures/URLs are default argument expressions.
        registrationRunner: BridgeRegistration.Runner? = nil,
        mcpBinary: URL? = nil,
        tabMessagingSocketURL: URL? = nil,
        canonicalPath: (@Sendable (String) -> String)? = nil,
        panel: RightPanel? = nil,
        pairingStore: (any RemotePairingStore)? = nil,
        kimiKeyStore: (any KimiKeyStore)? = nil,
        providerInstallations: [CLIProvider: ProviderInstallation] = [:],
        providerProbe: ProviderProbe? = nil
    ) {
        self.settings = settings
        self.store = store
        self.panel = panel ?? RightPanel()
        self.providerInstallations = providerInstallations
        self.providerProbe =
            providerProbe ?? { provider, executable in
                await Task.detached(priority: .utility) {
                    ProviderInstallation.detect(provider: provider, configuredExecutable: executable)
                }.value
            }
        if let pairingStore {
            self.remoteControl = RemoteControl(store: pairingStore)
        } else if Self.isRunningAutomatedTests {
            self.remoteControl = RemoteControl(store: InMemoryRemotePairingStore())
        } else {
            self.remoteControl = RemoteControl(
                store: KeychainRemotePairingStore(), notifications: DistributedNotificationCenter.default())
        }
        self.trashConversation = trashConversation
        self.presentError = presentError
        self.registrationRunner = registrationRunner ?? BridgeRegistration.processRunner
        self.mcpBinaryOverride = mcpBinary
        self.tabMessagingSocketURL = tabMessagingSocketURL ?? BridgePaths.configuredSocket
        self.resolveCanonicalPath = canonicalPath ?? { GrokPaths.canonicalPath($0) }
        self.kimiKeyStore =
            kimiKeyStore ?? (Self.isRunningAutomatedTests ? InMemoryKimiKeyStore() : KeychainKimiKeyStore())
        hasKimiAPIKey = self.kimiKeyStore.load() != nil
    }

    /// Stores a Kimi Platform API key in the Keychain. Returns false when it was not stored.
    @discardableResult
    func saveKimiAPIKey(_ key: String) -> Bool {
        guard let key = key.nilIfEmpty else { return false }
        let saved = kimiKeyStore.save(key)
        hasKimiAPIKey = kimiKeyStore.load() != nil
        return saved
    }

    func removeKimiAPIKey() {
        kimiKeyStore.clear()
        hasKimiAPIKey = kimiKeyStore.load() != nil
    }

    /// Variables a Kimi Code tab needs for the chosen sign-in. Nil when an
    /// API-key sign-in has no key to pass.
    private func providerEnvironment(for provider: CLIProvider) -> [String: String]? {
        guard provider == .kimi, settings.kimiSignIn == .apiKey else { return [:] }
        guard let key = kimiKeyStore.load() else { return nil }
        return KimiCode.apiKeyEnvironment(key: key, model: settings.kimiModel)
    }

    /// Whether `provider` has a sign-in to start with. Never shows an alert.
    func hasSignIn(_ provider: CLIProvider) -> Bool {
        providerEnvironment(for: provider) != nil
    }

    /// False, after saying why, when `provider` has no sign-in to start with.
    /// New Session asks before it makes a worktree.
    func canSignIn(_ provider: CLIProvider) -> Bool {
        guard providerEnvironment(for: provider) == nil else { return true }
        showError(
            title: "Kimi API key is missing",
            message: "Add it in Settings, or sign in with a Kimi account.")
        return false
    }

    func onAppear() async {
        guard !didAppear else { return }
        didAppear = true
        if !Self.isRunningAutomatedTests { startCrashStateRefresh() }
        if Self.isSmokeTest { return }
        observeStoreForHousekeeping()
        store.start()
        if !Self.isRunningAutomatedTests {
            Task { [weak self] in await self?.refreshProviderInstallations() }
        }
        // Bind the local socket before restoring tabs so they inherit it.
        // Registration is add-or-update and can take seconds; do not wait on it.
        if settings.isTabMessagingEnabled {
            try? startTabMessaging()
        }
        applyAppearance()
        restoreOpenTabs()
        preparePanel()
        if !Self.isRunningAutomatedTests {
            remoteControl.resumeIfPaired(model: self)
        }
        await reconcileTabMessaging()
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

    /// Where the rename UI should live after a key or visibility change.
    enum RenameSurface: Equatable, Sendable {
        case none
        case inline
        case prompt
    }

    /// After a focus steal: wait for the field, fall through to select-all,
    /// blur-commit on timeout, or stop.
    enum RenameFocusStealFollowUp: Equatable, Sendable {
        case selectAll
        case wait
        case miss
        case abort
    }

    /// `.task` identity for prepareRename. Token bumps on beginRename so a
    /// same-key F2/⌘⇧R re-runs prepare even when the session key is unchanged.
    struct RenamePrepareTaskID: Hashable {
        var key: String?
        var token: Int
    }

    var sidebarSurface: SidebarSurface {
        SidebarOrganization.surface(focusedPath: settings.focusedProjectPath)
    }
    /// Session key (`id` + cwd) of the row being renamed. Nil when idle.
    /// Lives on the model so ⌘B can hide the sidebar without dropping the draft.
    var renamingSessionKey: String?
    /// In-progress rename text. Shared by the inline field and the fallback alert.
    var renameDraft = ""
    var showRenameAlert = false
    var renameAlertSession: GrokSession?
    var renameAlertDidCommit = false
    /// True between the off and on edges of a forceRepresent pulse.
    var renameAlertIsPulsing = false
    /// Bumped on beginRename so a deferred click-out cancel cannot tear down
    /// a newer rename after the yield.
    var renameAlertDismissGeneration = 0
    var preparedRenameKey: String?
    var preparedRenameSurface: RenameSurface = .none
    /// Bumped on beginRename so prepareRename re-runs for a same-key F2/⌘⇧R.
    private(set) var renamePrepareToken = 0
    var renamePrepareTaskID: RenamePrepareTaskID {
        RenamePrepareTaskID(key: renamingSessionKey, token: renamePrepareToken)
    }
    /// Session key of the inline field currently in the tree. Nil if unmounted.
    var renameFieldMountedKey: String?
    /// Bumped on every mount/unmount so a stale blur task cannot commit after remount.
    var renameFieldMountGeneration = 0
    /// Select-all only for a fresh beginRename (F2, ⌘⇧R, row menu). Restore must not.
    var renameSelectAllPending = false
    /// Draft at arm time. Select-all is skipped if the user already edited.
    var renameSelectAllBaseline: String?
    /// Displayed title at fresh begin. Unedited Return/blur is a no-op even if
    /// the CLI summary moved. Same-key begin must not clear this.
    var renameCommitBaseline: String?
    /// Where keyboard focus goes when an inline rename ends.
    enum RenameReturnFocus { case list, terminal }
    /// Set by each beginRename: ⌘⇧R starts from the terminal and returns there;
    /// F2 and the row menu start from the list.
    private(set) var renameReturnFocus: RenameReturnFocus = .list

    /// Conversations for the sidebar, one-shot noise filtered out.
    /// An empty query stays newest first. Archived chats stay hidden unless
    /// Archived is open. A search ranks the closest title first and includes
    /// every folder.
    var sidebarSessions: [GrokSession] {
        sidebarSessions(index: sidebarIndex())
    }

    /// Archives and names grouped by chat id, built once per sidebar pass so
    /// each chat is one lookup, not a scan of every entry.
    private struct SidebarIndex {
        var archived: ConversationIndex<OpenTabsSnapshot.Entry>
        var names: ConversationIndex<ConversationName>
    }

    private func sidebarIndex() -> SidebarIndex {
        SidebarIndex(
            archived: ConversationIndex(settings.archivedConversations, sessionID: \.sessionID, cwd: \.cwd),
            names: ConversationIndex(settings.conversationNames, sessionID: \.sessionID, cwd: \.cwd)
        )
    }

    private func sidebarSessions(index: SidebarIndex) -> [GrokSession] {
        var result = store.search(searchText) { self.title(for: $0, in: index) }
            .filter { passesSidebarFilters($0, in: index) }
        if !SidebarOrganization.isSearching(searchText) {
            if sidebarSurface == .archived {
                result = result.filter { isArchived($0, in: index) }
            } else {
                result = result.filter { !isArchived($0, in: index) }
            }
        }
        return result
    }

    /// The empty, worktree and subagent filters. Shared by the list and the
    /// Archived count so the count never includes rows the list hides.
    /// `index` is the pass's name lookup; without one, names are scanned.
    private func passesSidebarFilters(_ session: GrokSession, in index: SidebarIndex? = nil) -> Bool {
        // A session you have open is always worth listing, even before the CLI
        // has written a summary for it. Otherwise the row marking the
        // conversation on screen is the one row the list refuses to show.
        if !settings.showEmptySessions, !(isReal(session, in: index) || isOpen(session)) {
            return false
        }
        if !settings.showWorktreeSessions, isEphemeral(path: session.cwd), !isOpen(session) {
            return false
        }
        if !settings.showSubagentSessions, session.isSubagent, !isOpen(session) {
            return false
        }
        if !settings.showOtherAppSessions, !settings.isSigilConversation(session.id), !isOpen(session) {
            return false
        }
        return true
    }

    /// A session worth listing: it has a summary, a name the user chose, or more
    /// than the opening exchange.
    private func isReal(_ session: GrokSession, in index: SidebarIndex?) -> Bool {
        !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.messageCount > 2 || session.hasObservedMessages
            || (index.map { customName(for: session, in: $0) != nil } ?? hasCustomName(session))
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
        entryKey(.init(sessionID: session.id, cwd: session.cwd))
    }

    func activity(of session: GrokSession) -> TerminalTab.Activity? {
        tabs.first { tabMatches($0, sessionID: session.id, cwd: session.cwd) }?.activity
    }

    func hasUnseenActivity(of session: GrokSession) -> Bool {
        tabs.first { tabMatches($0, sessionID: session.id, cwd: session.cwd) }?.hasUnseenActivity
            ?? false
    }

    func isWorking(_ session: GrokSession) -> Bool {
        activity(of: session) == .working
    }

    func isWorking(_ project: SidebarProject) -> Bool {
        project.sessions.contains { isWorking($0) }
            || tabs.contains { $0.activity == .working && inProject($0.workingDirectory.path, project.cwd) }
    }

    func isPinned(_ session: GrokSession) -> Bool {
        SidebarOrganization.contains(
            settings.pinnedConversations, session: session, samePath: samePath)
    }

    func pin(_ session: GrokSession) {
        settings.reloadSharedLists()
        unarchive(session)
        settings.pinnedConversations = SidebarOrganization.inserting(
            session, onto: settings.pinnedConversations, samePath: samePath)
    }

    func unpin(_ session: GrokSession) {
        settings.reloadSharedLists()
        settings.pinnedConversations = SidebarOrganization.removing(
            session, from: settings.pinnedConversations, samePath: samePath)
    }

    func togglePin(_ session: GrokSession) {
        if isPinned(session) { unpin(session) } else { pin(session) }
    }

    func isPinned(_ project: SidebarProject) -> Bool {
        SidebarOrganization.contains(settings.pinnedProjects, path: project.cwd, samePath: samePath)
    }

    func pin(_ project: SidebarProject) {
        settings.reloadSharedLists()
        settings.pinnedProjects = SidebarOrganization.inserting(
            project.cwd, onto: settings.pinnedProjects, samePath: samePath)
    }

    func unpin(_ project: SidebarProject) {
        settings.reloadSharedLists()
        settings.pinnedProjects = SidebarOrganization.removing(
            project.cwd, from: settings.pinnedProjects, samePath: samePath)
    }

    func togglePin(_ project: SidebarProject) {
        if isPinned(project) { unpin(project) } else { pin(project) }
    }

    func isArchived(_ session: GrokSession) -> Bool {
        SidebarOrganization.contains(
            settings.archivedConversations, session: session, samePath: samePath)
    }

    private func isArchived(_ session: GrokSession, in index: SidebarIndex) -> Bool {
        index.archived.contains(sessionID: session.id, cwd: session.cwd, samePath: samePath)
    }

    func archive(_ session: GrokSession) {
        archive(session, confirmIfWorking: true)
    }

    private func archive(_ session: GrokSession, confirmIfWorking: Bool) {
        let matching = tabs.filter { tabMatches($0, sessionID: session.id, cwd: session.cwd) }
        if confirmIfWorking, let prompt = StopWorkingPrompt(action: .archive, stopping: matching),
            !confirmStop(prompt)
        {
            return
        }
        archiveWithoutAsking([session])
    }

    /// Archives `sessions` and closes their tabs, writing each setting once
    /// however many sessions there are.
    private func archiveWithoutAsking(_ sessions: [GrokSession]) {
        settings.reloadSharedLists()
        var pinned = settings.pinnedConversations
        var archived = settings.archivedConversations
        for session in sessions {
            pinned = SidebarOrganization.removing(session, from: pinned, samePath: samePath)
            archived = SidebarOrganization.inserting(session, onto: archived, samePath: samePath)
        }
        settings.pinnedConversations = pinned
        settings.archivedConversations = archived
        stopAndWait(
            tabs.filter { tab in
                sessions.contains { tabMatches(tab, sessionID: $0.id, cwd: $0.cwd) }
            })
        for session in sessions {
            while let index = tabs.firstIndex(where: {
                tabMatches($0, sessionID: session.id, cwd: session.cwd)
            }) {
                removeTab(at: index)
            }
            dropDeferred(matching: session)
        }
        refreshDockIndicator()
        persistOpenTabs()
    }

    func unarchive(_ session: GrokSession) {
        settings.reloadSharedLists()
        settings.archivedConversations = SidebarOrganization.removing(
            session, from: settings.archivedConversations, samePath: samePath)
    }

    func toggleArchive(_ session: GrokSession) {
        if isArchived(session) { unarchive(session) } else { archive(session) }
    }

    /// Archives a multi-selection with at most one working-session prompt.
    func archive(_ sessions: [GrokSession]) {
        let matching = tabs.filter { tab in
            sessions.contains { tabMatches(tab, sessionID: $0.id, cwd: $0.cwd) }
        }
        if let prompt = StopWorkingPrompt(action: .archive, stopping: matching),
            !confirmStop(prompt)
        {
            return
        }
        archiveWithoutAsking(sessions)
    }

    func unarchive(_ sessions: [GrokSession]) {
        for session in sessions { unarchive(session) }
    }

    func archive(_ project: SidebarProject) {
        let projectTabs = tabs.filter {
            $0.capabilities.archive && inProject($0.workingDirectory.path, project.cwd)
        }
        if let prompt = StopWorkingPrompt(action: .archive, stopping: projectTabs),
            !confirmStop(prompt)
        {
            return
        }
        unpin(project)
        removeAddedProject(project.cwd)
        stopAndWait(projectTabs)
        archiveWithoutAsking(store.sessions.filter { inProject($0.cwd, project.cwd) })
        for tab in projectTabs {
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) { removeTab(at: index) }
        }
        dropDeferred(inProjectPath: project.cwd)
        refreshDockIndicator()
        persistOpenTabs()
        if focusedProject.map({ samePath($0.cwd, project.cwd) }) == true {
            leaveProject()
        }
    }

    func unarchive(_ project: SidebarProject) {
        for session in store.sessions where inProject(session.cwd, project.cwd) {
            unarchive(session)
        }
    }

    /// Archived conversations the Archived list will show.
    var archivedCount: Int {
        archivedCount(index: sidebarIndex())
    }

    private func archivedCount(index: SidebarIndex) -> Int {
        store.sessions.filter { isArchived($0, in: index) && passesSidebarFilters($0, in: index) }.count
    }

    /// Pinned conversations still in the current sidebar filter, in pin order.
    func pinnedSessions(in project: SidebarProject? = nil) -> [GrokSession] {
        SidebarOrganization.pinned(
            sessions: sidebarSessions,
            entries: settings.pinnedConversations,
            in: project,
            samePath: samePath
        )
    }

    func unpinnedSessions(from sessions: [GrokSession]) -> [GrokSession] {
        SidebarOrganization.without(
            sessions: sessions,
            entries: settings.pinnedConversations,
            samePath: samePath
        )
    }

    /// Pinned folders still in the current sidebar filter, in pin order.
    func pinnedProjects() -> [SidebarProject] {
        SidebarOrganization.matching(
            projects: sidebarProjects,
            paths: settings.pinnedProjects,
            samePath: samePath
        )
    }

    func unpinnedProjects() -> [SidebarProject] {
        SidebarOrganization.without(
            projects: sidebarProjects,
            paths: settings.pinnedProjects,
            samePath: samePath
        )
    }

    var sidebarProjects: [SidebarProject] {
        sidebarProjects(from: sidebarSessions)
    }

    /// Folders grouped from `sessions`, plus added folders with no chat yet.
    private func sidebarProjects(from sessions: [GrokSession]) -> [SidebarProject] {
        let projects = SidebarOrganization.projects(from: sessions, canonicalPath: canonicalPath)
        // A search ranks by match and Archived lists only archived chats.
        guard !SidebarOrganization.isSearching(searchText), sidebarSurface != .archived else {
            return projects
        }
        return SidebarOrganization.merging(
            added: settings.addedProjects, into: projects, canonicalPath: canonicalPath)
    }

    /// Adds a folder to Projects before it has a chat. A Sigil worktree adds its project.
    func addProject(_ directory: URL) {
        let path = SigilWorktree.projectPath(of: directory.path) ?? directory.path
        settings.reloadSharedLists()
        var added = settings.addedProjects
        added.removeAll { samePath($0.path, path) }
        added.insert(AddedProject(path: path, addedAt: Date()), at: 0)
        settings.addedProjects = added
    }

    func chooseProjectToAdd() {
        if let directory = pickDirectory(prompt: "Add Project") { addProject(directory) }
    }

    private func removeAddedProject(_ path: String) {
        settings.reloadSharedLists()
        let added = settings.addedProjects.filter { !samePath($0.path, path) }
        if added != settings.addedProjects { settings.addedProjects = added }
    }

    /// An added folder with no conversations at all, hidden ones included.
    /// Removing it drops only the folder entry, never a chat.
    func isRemovableOnly(_ project: SidebarProject) -> Bool {
        isAddedProject(project.cwd) && !store.sessions.contains { inProject($0.cwd, project.cwd) }
    }

    /// The row's archive control: removal for a chatless added folder.
    func archiveOrRemove(_ project: SidebarProject) {
        if isRemovableOnly(project) { removeProject(project) } else { archive(project) }
    }

    /// Drops an added folder and closes every tab in it, whatever the CLI.
    func removeProject(_ project: SidebarProject) {
        let projectTabs = tabs.filter { inProject($0.workingDirectory.path, project.cwd) }
        if let prompt = StopWorkingPrompt(action: .closeTab, stopping: projectTabs),
            !confirmStop(prompt)
        {
            return
        }
        unpin(project)
        removeAddedProject(project.cwd)
        stopAndWait(projectTabs)
        for tab in projectTabs {
            if let index = tabs.firstIndex(where: { $0.id == tab.id }) { removeTab(at: index) }
        }
        refreshDockIndicator()
        persistOpenTabs()
        if focusedProject.map({ samePath($0.cwd, project.cwd) }) == true {
            leaveProject()
        }
    }

    /// The selected tab runs in this folder, whatever the CLI.
    func hasSelectedTab(in project: SidebarProject) -> Bool {
        selectedTab.map { inProject($0.workingDirectory.path, project.cwd) } ?? false
    }

    private func isAddedProject(_ path: String) -> Bool {
        settings.addedProjects.contains { samePath($0.path, path) }
    }

    var focusedProject: SidebarProject? {
        focusedProject(in: { sidebarProjects })
    }

    /// `projects` are the folders grouped from `sidebarSessions`. They are
    /// only read when a folder is open.
    private func focusedProject(in projects: () -> [SidebarProject]) -> SidebarProject? {
        let path = settings.focusedProjectPath
        guard !path.isEmpty,
            path != SidebarOrganization.recentsID,
            path != SidebarOrganization.archivedID
        else { return nil }
        let focused = canonicalPath(path)
        return projects().first { $0.id == focused || samePath($0.cwd, path) }
            ?? project(at: path, from: store.sessions)
            ?? SidebarOrganization.merging(
                added: settings.addedProjects.filter { samePath($0.path, path) },
                into: [], canonicalPath: canonicalPath
            ).first
    }

    private func project(at path: String, from sessions: [GrokSession]) -> SidebarProject? {
        let focused = canonicalPath(path)
        return SidebarOrganization.projects(from: sessions, canonicalPath: canonicalPath)
            .first { $0.id == focused || samePath($0.cwd, path) }
    }

    /// Chats in the open project, or the full sidebar list.
    var focusedSidebarSessions: [GrokSession] {
        SidebarOrganization.sessions(sidebarSessions, in: focusedProject, samePath: samePath)
    }

    /// Everything a sidebar snapshot reads apart from the file system. Equal
    /// inputs build an equal snapshot.
    private struct SidebarInputs: Equatable {
        var sessions: [GrokSession]
        var searchText: String
        var focusedProjectPath: String
        var pinnedConversations: [OpenTabsSnapshot.Entry]
        var pinnedProjects: [String]
        var addedProjects: [AddedProject]
        var archivedConversations: [OpenTabsSnapshot.Entry]
        var conversationNames: [ConversationName]
        var showEmptySessions: Bool
        var showWorktreeSessions: Bool
        var showSubagentSessions: Bool
        var tabIDs: [UUID]
    }

    private func sidebarInputs() -> SidebarInputs {
        SidebarInputs(
            sessions: store.sessions,
            searchText: searchText,
            focusedProjectPath: settings.focusedProjectPath,
            pinnedConversations: settings.pinnedConversations,
            pinnedProjects: settings.pinnedProjects,
            addedProjects: settings.addedProjects,
            archivedConversations: settings.archivedConversations,
            conversationNames: settings.conversationNames,
            showEmptySessions: settings.showEmptySessions,
            showWorktreeSessions: settings.showWorktreeSessions,
            showSubagentSessions: settings.showSubagentSessions,
            tabIDs: tabs.map(\.id)
        )
    }

    /// The last snapshot built and the inputs it was built from.
    @ObservationIgnored private var lastSidebarSnapshot: (inputs: SidebarInputs, snapshot: SidebarSnapshot)?
    /// Snapshots built so far. Tests read it to prove events reuse one.
    @ObservationIgnored private(set) var sidebarSnapshotBuildCount = 0

    /// Event-time row order (arrow keys, row-list cleanup): the last snapshot
    /// while none of its inputs has changed, else a new one. A render always
    /// builds its own, so worktree and symlink checks stay fresh on screen.
    func eventSidebarSnapshot() -> SidebarSnapshot {
        if let last = lastSidebarSnapshot, last.inputs == sidebarInputs() {
            return last.snapshot
        }
        return sidebarSnapshot()
    }

    /// Every list one sidebar render reads, from a single search and grouping.
    func sidebarSnapshot() -> SidebarSnapshot {
        let inputs = sidebarInputs()
        let snapshot = buildSidebarSnapshot()
        sidebarSnapshotBuildCount += 1
        lastSidebarSnapshot = (inputs, snapshot)
        return snapshot
    }

    private func buildSidebarSnapshot() -> SidebarSnapshot {
        let index = sidebarIndex()
        let sessions = sidebarSessions(index: index)
        let projects = sidebarProjects(from: sessions)
        return SidebarSnapshot(
            listKind: SidebarOrganization.listKind(
                surface: sidebarSurface,
                isSearching: SidebarOrganization.isSearching(searchText)
            ),
            sessions: sessions,
            projects: projects,
            focusedProject: focusedProject(in: { projects }),
            pinnedConversations: settings.pinnedConversations,
            pinnedProjectPaths: settings.pinnedProjects,
            openTabRowIDs: tabs.map { SidebarOrganization.openTabRowID($0.id) },
            archivedCount: archivedCount(index: index),
            samePath: samePath,
            sessionKey: sessionKey
        )
    }

    /// Folder a new chat should start in: the open project, else the current tab.
    var newSessionDirectory: URL {
        if let project = focusedProject {
            return URL(fileURLWithPath: project.cwd)
        }
        if let project = SigilWorktree.projectPath(of: currentDirectory.path),
            Self.isUsableDirectory(URL(fileURLWithPath: project))
        {
            return URL(fileURLWithPath: project)
        }
        return currentDirectory
    }

    func openProject(_ project: SidebarProject) {
        settings.focusedProjectPath = project.cwd
    }

    func openRecents() {
        settings.focusedProjectPath = SidebarOrganization.recentsID
    }

    func openArchived() {
        settings.focusedProjectPath = SidebarOrganization.archivedID
    }

    func leaveProject() {
        settings.focusedProjectPath = ""
    }

    func requestNewSessionInProject(_ project: SidebarProject) {
        openProject(project)
        requestNewSession(in: URL(fileURLWithPath: project.cwd))
    }

    enum SidebarDismiss: Equatable {
        case closeTab(UUID)
        case delete
    }

    func sidebarDismiss(for session: GrokSession) -> SidebarDismiss {
        if let tab = tabs.first(where: { tabMatches($0, sessionID: session.id, cwd: session.cwd) }) {
            return .closeTab(tab.id)
        }
        return .delete
    }

    func performSidebarDismiss(_ session: GrokSession) {
        if case .closeTab(let id) = sidebarDismiss(for: session) {
            requestCloseTab(id)
        }
    }

    /// Drops pins, archives, and names whose conversations are gone, after a successful scan.
    func pruneMissingPins() {
        guard !store.isLoading, store.loadError == nil else { return }
        // A missing folder lists nothing without an error; that is no proof
        // the pinned chats are gone.
        guard FileManager.default.fileExists(atPath: store.root.path) else { return }
        let held = sharedListKeys()
        settings.reloadSharedLists()
        for key in sharedListKeys().subtracting(held) where sharedArrivals[key] == nil {
            sharedArrivals[key] = store.scanSequence
        }
        let remainingPins = pruningMissing(settings.pinnedConversations, list: "pin")
        if remainingPins != settings.pinnedConversations {
            settings.pinnedConversations = remainingPins
        }
        // Earlier builds added a Sigil worktree as its own project, which
        // could then be pinned or left open. Each becomes its project.
        let remainingAdded = SidebarOrganization.foldingWorktrees(
            settings.addedProjects, path: \.path,
            moving: { AddedProject(path: $1, addedAt: $0.addedAt) }, samePath: samePath
        ).filter { Self.isUsableDirectory(URL(fileURLWithPath: $0.path)) }
        if remainingAdded != settings.addedProjects {
            settings.addedProjects = remainingAdded
        }
        let remainingProjectPins = pruningMissingProjects(
            SidebarOrganization.foldingWorktrees(
                settings.pinnedProjects, path: { $0 }, moving: { $1 }, samePath: samePath))
        if remainingProjectPins != settings.pinnedProjects {
            settings.pinnedProjects = remainingProjectPins
        }
        if let project = SigilWorktree.projectPath(of: settings.focusedProjectPath) {
            settings.focusedProjectPath = project
        }
        let remainingArchives = pruningMissing(settings.archivedConversations, list: "archive")
        if remainingArchives != settings.archivedConversations {
            settings.archivedConversations = remainingArchives
        }
        let remainingNames = pruningMissingNames(settings.conversationNames)
        if remainingNames != settings.conversationNames {
            settings.conversationNames = remainingNames
        }
        let remainingColors = pruningMissingColors(settings.tabColors)
        if remainingColors != settings.tabColors {
            settings.tabColors = remainingColors
        }
        let focused = settings.focusedProjectPath
        if !focused.isEmpty,
            !SidebarOrganization.isSentinel(focused),
            !store.sessions.contains(where: { inProject($0.cwd, focused) }),
            !isAddedProject(focused)
        {
            settings.focusedProjectPath = ""
        }
        sharedArrivals = sharedArrivals.filter { $0.value >= store.appliedScanSequence }
        migrateLegacyPanelNotes()
    }

    /// One key per entry in the lists running copies share, tagged by list.
    private func sharedListKeys() -> Set<String> {
        Set(settings.pinnedConversations.map { sharedKey("pin", $0.sessionID, $0.cwd) })
            .union(settings.pinnedProjects.map { sharedKey("project", $0) })
            .union(settings.archivedConversations.map { sharedKey("archive", $0.sessionID, $0.cwd) })
            .union(settings.conversationNames.map { sharedKey("name", $0.sessionID, $0.cwd) })
            .union(settings.tabColors.map { sharedKey("color", $0.sessionID, $0.cwd) })
    }

    private func sharedKey(_ parts: String...) -> String {
        parts.joined(separator: "\u{0}")
    }

    /// True while the shown scan began before this copy read the entry from
    /// another copy. That copy may have created the conversation after the
    /// scan started, so a missing match is not yet proof the entry is stale.
    private func awaitsScan(_ key: String) -> Bool {
        guard let seen = sharedArrivals[key] else { return false }
        return store.appliedScanSequence <= seen
    }

    /// Pruning and legacy-note migration follow the store's own loading, not a
    /// view's `onChange`, so hiding the sidebar cannot skip them.
    private func observeStoreForHousekeeping() {
        withObservationTracking {
            _ = store.isLoading
            _ = store.sessions
            // A watcher rescan can clear an error without changing sessions.
            _ = store.loadError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.store.isLoading {
                    self.seedSigilConversations()
                    self.recordStartedCodexSessions()
                    self.pruneMissingPins()
                    // Native history is loaded asynchronously. A startup's
                    // first restoration attempt may precede the first scan.
                    if !self.deferredOpenTabs.isEmpty { self.restoreOpenTabs() }
                }
                self.observeStoreForHousekeeping()
            }
        }
    }

    /// Chats Sigil started before it kept a list: saved open tabs and chats
    /// in Sigil's own worktrees. Runs once, after the first scan.
    func seedSigilConversations() {
        // A scan with a read error may have missed chats; wait for a clean one.
        guard !settings.sigilConversationsSeeded, store.appliedScanSequence > 0, store.loadError == nil
        else { return }
        let saved = settings.openTabs.tabs.map {
            ProviderSessionReference(provider: $0.provider, sessionID: $0.sessionID, cwd: $0.cwd).sidebarID
        }
        let worktrees = store.sessions
            .filter { SigilWorktree.projectPath(of: $0.cwd) != nil && !$0.isSubagent }
            .map(\.id)
        settings.recordSigilConversations(saved + worktrees)
        settings.sigilConversationsSeeded = true
    }

    /// A Codex tab can be renamed and colored before its chat id exists.
    /// Those values move onto the chat once the id is known, or the next
    /// summary replaces the name and the color disappears.
    func adoptLearnedCodexSession(_ tab: TerminalTab, session: GrokSession) {
        let chosenName = tab.sessionTitle
        let chosenColor = tab.markColor
        tab.learnedSessionReference = ProviderSessionReference(
            provider: .codex, sessionID: session.nativeSessionID, cwd: tab.workingDirectory.path)
        if let chosenName, chosenName != tab.automaticTitle {
            renameTab(tab, to: chosenName)
        }
        if let chosenColor {
            setTabColor(tab, to: chosenColor)
            tab.markColor = nil
        }
    }

    /// Codex picks its own id for a new chat, so a new Codex tab is matched to
    /// the first Codex chat that appears in its folder after it launched. The
    /// tab then knows its chat, so the row shows as open and it can restore.
    private func recordStartedCodexSessions() {
        let waiting =
            tabs
            .filter { $0.spec.provider == .codex && $0.sessionReference == nil }
            .sorted { $0.launchedAt < $1.launchedAt }
        guard !waiting.isEmpty else { return }
        var claimed = Set(tabs.compactMap(\.sessionID))
        for tab in waiting {
            let folder = GrokPaths.canonicalPath(tab.workingDirectory.path)
            let match = store.sessions
                .filter {
                    $0.provider == .codex && !claimed.contains($0.id)
                        && !settings.isSigilConversation($0.id)
                        && $0.createdAt >= tab.launchedAt.addingTimeInterval(-5)
                        && GrokPaths.canonicalPath($0.cwd) == folder
                }
                .min { $0.createdAt < $1.createdAt }
            guard let match else { continue }
            adoptLearnedCodexSession(tab, session: match)
            claimed.insert(match.id)
            settings.recordSigilConversations([match.id])
            persistOpenTabs()
        }
    }

    /// One-time move of UserDefaults folder notes onto per-conversation files.
    /// Each folder note lands on the newest conversation the sidebar lists in
    /// that folder (an open one first); when that conversation already has a
    /// note the legacy text is appended, not dropped. Folders with no listed
    /// conversation yet, or whose note file could not be written, keep their
    /// entry for a later launch.
    func migrateLegacyPanelNotes() {
        let legacy = panel.legacyFolderNotes
        guard !legacy.isEmpty else { return }
        var remaining = legacy
        var moved: [String: GrokSession] = [:]
        for (folder, text) in legacy {
            let listed = store.sessions.filter {
                samePath($0.cwd, folder) && !isArchived($0) && passesSidebarFilters($0)
            }
            let newest = { (sessions: [GrokSession]) in
                sessions.max(by: { $0.updatedAt < $1.updatedAt })
            }
            guard !text.isEmpty,
                let session = newest(listed.filter { isOpen($0) }) ?? newest(listed)
            else { continue }
            let existing = panel.notes(forSessionID: session.id, cwd: session.cwd)
            let section = "\n\n---\n\n" + text
            // Skip only a note that is the legacy text, or one already ending
            // in a migrated copy of it. A mere substring match is not proof.
            if existing.isEmpty {
                panel.setNotes(text, forSessionID: session.id, cwd: session.cwd)
            } else if existing != text && !existing.hasSuffix(section) {
                panel.setNotes(existing + section, forSessionID: session.id, cwd: session.cwd)
            }
            moved[folder] = session
        }
        if !moved.isEmpty {
            // Persist before the legacy source goes away: a crash between a
            // debounced write and clearing UserDefaults would lose the note.
            panel.flushNotes()
            for (folder, session) in moved
            where panel.notesStore.isSaved(for: session.id, cwd: session.cwd) {
                remaining.removeValue(forKey: folder)
            }
            if remaining.count != legacy.count {
                panel.setLegacyFolderNotes(remaining)
            }
        }
    }

    private func pruningMissing(
        _ entries: [OpenTabsSnapshot.Entry], list: String
    ) -> [OpenTabsSnapshot.Entry] {
        entries.filter { entry in
            isNativeHistoryID(sidebarID(entry))
                || store.sessions.contains { $0.id == entry.sessionID && samePath($0.cwd, entry.cwd) }
                || tabs.contains { tabMatches($0, sessionID: entry.sessionID, cwd: entry.cwd) }
                || awaitsScan(sharedKey(list, entry.sessionID, entry.cwd))
        }
    }

    private func pruningMissingProjects(_ paths: [String]) -> [String] {
        paths.filter { path in
            store.sessions.contains { inProject($0.cwd, path) }
                || tabs.contains { inProject($0.workingDirectory.path, path) }
                || isAddedProject(path)
                || awaitsScan(sharedKey("project", path))
        }
    }

    private func isNativeHistoryID(_ id: String) -> Bool {
        [CLIProvider.claudeCode, .codex].contains { id.hasPrefix($0.rawValue + ":") }
    }

    private func pruningMissingNames(_ names: [ConversationName]) -> [ConversationName] {
        names.filter { record in
            isNativeHistoryID(record.sessionID)
                || store.sessions.contains { $0.id == record.sessionID && samePath($0.cwd, record.cwd) }
                || tabs.contains { tabMatches($0, sessionID: record.sessionID, cwd: record.cwd) }
                || awaitsScan(sharedKey("name", record.sessionID, record.cwd))
        }
    }

    private func pruningMissingColors(_ records: [TabColorRecord]) -> [TabColorRecord] {
        records.filter { record in
            isNativeHistoryID(record.sessionID)
                || store.sessions.contains { $0.id == record.sessionID && samePath($0.cwd, record.cwd) }
                || tabs.contains { tabMatches($0, sessionID: record.sessionID, cwd: record.cwd) }
                || awaitsScan(sharedKey("color", record.sessionID, record.cwd))
        }
    }

    /// The deleted conversation still sits in `store` until the next scan.
    private func dropOrphanedProjectPin(for session: GrokSession) {
        let othersRemain =
            store.sessions.contains { $0.id != session.id && inProject($0.cwd, session.projectPath) }
            || tabs.contains { inProject($0.workingDirectory.path, session.projectPath) }
        if !othersRemain {
            settings.reloadSharedLists()
            settings.pinnedProjects = SidebarOrganization.removing(
                session.projectPath, from: settings.pinnedProjects, samePath: samePath)
        }
    }

    /// Sidebar, tab, tooltip, and search label. A user-chosen name wins over the CLI summary.
    func title(for session: GrokSession) -> String {
        ConversationNaming.displayedTitle(for: session, customName: customName(for: session))
    }

    func customName(for session: GrokSession) -> String? {
        ConversationNaming.name(
            for: session, in: settings.conversationNames, samePath: samePath)
    }

    private func title(for session: GrokSession, in index: SidebarIndex) -> String {
        ConversationNaming.displayedTitle(for: session, customName: customName(for: session, in: index))
    }

    /// `customName(for:)` from the pass's index: the first record, normalized.
    private func customName(for session: GrokSession, in index: SidebarIndex) -> String? {
        index.names.first(sessionID: session.id, cwd: session.cwd, samePath: samePath)
            .flatMap { ConversationNaming.normalized($0.name) }
    }

    func hasCustomName(_ session: GrokSession) -> Bool {
        customName(for: session) != nil
    }

    /// Empty, whitespace, or a name equal to the CLI title clears the override
    /// (a matching submit with no overlay is a no-op). Otherwise stores the name.
    func rename(_ session: GrokSession, to raw: String) {
        settings.reloadSharedLists()
        let next = ConversationNaming.setting(
            raw, on: session, onto: settings.conversationNames, samePath: samePath)
        guard
            Self.shouldPersistConversationNames(
                next: next, current: settings.conversationNames)
        else { return }
        settings.conversationNames = next
        applyNameToOpenTabs(session)
    }

    /// Finder-style blur/Return that matches the CLI title with no overlay
    /// must not JSON-encode an unchanged list into UserDefaults.
    static func shouldPersistConversationNames(
        next: [ConversationName], current: [ConversationName]
    ) -> Bool {
        next != current
    }

    /// Unedited Return/blur is a no-op even if the CLI summary changed after
    /// beginRename. Nil baseline means this commit was not an in-session edit.
    static func shouldNoOpRenameCommit(draft: String, baseline: String?) -> Bool {
        guard let baseline else { return false }
        return draft == baseline
    }

    func resetName(_ session: GrokSession) {
        let live = freshSession(matching: session)
        if renamingSessionKey == sessionKey(live) {
            endRenameSession()
        }
        settings.reloadSharedLists()
        let next = ConversationNaming.removing(
            live, from: settings.conversationNames, samePath: samePath)
        guard
            Self.shouldPersistConversationNames(
                next: next, current: settings.conversationNames)
        else { return }
        settings.conversationNames = next
        applyNameToOpenTabs(live)
    }

    /// Single draft owner for a fresh key. prepareRename only hands off the
    /// surface — it must not rewrite `renameDraft`, or typing that lands
    /// before that task runs is clobbered.
    func beginRename(_ session: GrokSession, returnFocus: RenameReturnFocus = .list) {
        isSidebarVisible = true
        renameReturnFocus = returnFocus
        let key = sessionKey(session)
        let isFreshKey = renamingSessionKey != key
        renameAlertDismissGeneration += 1
        let representPrompt = Self.shouldRepresentRenamePromptOnSameKeyBegin(
            isFreshKey: isFreshKey,
            showRenameAlert: showRenameAlert,
            preparedSurface: preparedRenameSurface
        )
        if isFreshKey {
            // Keep didCommit true across teardown so the alert Binding cannot
            // treat this as a click-out (same as pulseRenameAlertOff).
            renameAlertDidCommit = true
            renameDraft = title(for: session)
            renameCommitBaseline = renameDraft
            showRenameAlert = false
            renameAlertSession = nil
            renameAlertIsPulsing = false
        }
        if Self.shouldArmRenameSelectAllOnBegin(isFreshKey: isFreshKey) {
            renameSelectAllPending = true
            renameSelectAllBaseline = renameDraft
        } else {
            clearRenameSelectAllPending()
        }
        if Self.shouldInvalidatePreparedRenameOnBegin() {
            preparedRenameKey = nil
            preparedRenameSurface = .none
            renamePrepareToken += 1
        }
        renamingSessionKey = key
        if representPrompt {
            revealRenameAlert(session)
        }
    }

    func cancelRename() {
        endRenameSession()
    }

    func commitRename(_ session: GrokSession, to raw: String) {
        if !Self.shouldNoOpRenameCommit(draft: raw, baseline: renameCommitBaseline) {
            rename(session, to: raw)
        }
        if renamingSessionKey == sessionKey(session) {
            endRenameSession()
        }
    }

    /// Drops in-progress rename UI. Not called when the sidebar hides — the
    /// draft must survive ⌘B and come back with the typed text.
    private func endRenameSession() {
        renamingSessionKey = nil
        renameDraft = ""
        showRenameAlert = false
        renameAlertSession = nil
        renameAlertDidCommit = false
        renameAlertIsPulsing = false
        preparedRenameKey = nil
        preparedRenameSurface = .none
        renameFieldMountedKey = nil
        renameFieldMountGeneration += 1
        clearRenameSelectAllPending()
        renameCommitBaseline = nil
    }

    /// Snapshot the live draft before `endRenameSession` can wipe it. The
    /// alert's isPresented setter may cancel before this button action runs.
    /// Unedited draft (equal to the begin-time baseline) is a no-op even if
    /// the CLI summary moved; an edited draft still matches the live title.
    func commitCapturedRename(_ session: GrokSession) {
        let snapshot = renameDraft
        renameAlertDidCommit = true
        commitRename(freshSession(matching: session), to: snapshot)
    }

    /// Store row for this id+cwd, or the snapshot if the session is gone.
    func freshSession(matching session: GrokSession) -> GrokSession {
        store.sessions.first { sessionKey($0) == sessionKey(session) } ?? session
    }

    /// ⌘B teardown leaves `showRenameAlert` true. Assigning true again is not
    /// a presentation change, so SwiftUI never re-shows the alert.
    static func shouldPulseRenameAlert(forceRepresent: Bool, currentlyShown: Bool) -> Bool {
        forceRepresent && currentlyShown
    }

    /// Off-edge of the pulse. `renameAlertDidCommit` stays true so the alert
    /// binding cannot cancel the live draft while we yield.
    func pulseRenameAlertOff() {
        renameAlertDidCommit = true
        renameAlertIsPulsing = true
        showRenameAlert = false
    }

    func revealRenameAlert(_ session: GrokSession?) {
        renameAlertSession = session
        showRenameAlert = true
        renameAlertIsPulsing = false
        renameAlertDidCommit = false
    }

    /// Sidebar hide and the forceRepresent pulse must not run the dismiss setter.
    static func shouldApplyRenameAlertPresentedChange(
        sidebarVisible: Bool, pulsing: Bool
    ) -> Bool {
        sidebarVisible && !pulsing
    }

    /// Dismiss may fire before the Rename button. `expectedGeneration` is the
    /// dismiss generation at schedule time (the Binding), not at Task entry —
    /// a later beginRename on this turn must not be cancelled.
    func deferCancelRenameAlert(expectedGeneration: Int) async {
        await Task.yield()
        guard
            Self.shouldCancelRenameAlertAfterYield(
                isCancelled: Task.isCancelled,
                sidebarVisible: isSidebarVisible,
                didCommit: renameAlertDidCommit,
                stillRenaming: renamingSessionKey != nil,
                expectedGeneration: expectedGeneration,
                currentGeneration: renameAlertDismissGeneration
            )
        else { return }
        cancelRename()
    }

    func noteRenameFieldMounted(_ mounted: Bool, key: String) {
        if mounted {
            guard
                Self.shouldApplyRenameFieldMount(
                    mountKey: key,
                    activeKey: renamingSessionKey,
                    mountedKey: renameFieldMountedKey
                )
            else { return }
            renameFieldMountedKey = key
            renameFieldMountGeneration += 1
        } else {
            guard
                Self.shouldApplyRenameFieldUnmount(
                    unmountKey: key,
                    activeKey: renamingSessionKey,
                    mountedKey: renameFieldMountedKey
                )
            else { return }
            renameFieldMountedKey = nil
            renameFieldMountGeneration += 1
        }
    }

    func consumeRenameSelectAll() -> Bool {
        let pending = renameSelectAllPending
        clearRenameSelectAllPending()
        return pending
    }

    func clearRenameSelectAllPending() {
        renameSelectAllPending = false
        renameSelectAllBaseline = nil
    }

    /// Inline editor only. No-ops if this row is no longer the active rename
    /// (Reset Name, cancel, or another row started). Unedited draft matches
    /// the begin-time baseline first; otherwise the live title.
    func commitInlineRename(_ session: GrokSession, to raw: String) {
        guard renamingSessionKey == sessionKey(session) else { return }
        commitRename(freshSession(matching: session), to: raw)
    }

    /// Blur of the inline field. Skipped when the row left the visible list,
    /// the sidebar is hidden (⌘B), or LazyVStack unmounted the field.
    func commitInlineBlur(
        _ session: GrokSession,
        to raw: String,
        mountGeneration: Int
    ) {
        guard
            Self.shouldCommitInlineBlur(
                keyMatches: renamingSessionKey == sessionKey(session),
                rowVisible: sidebarSessions.contains {
                    sessionKey($0) == sessionKey(session)
                },
                sidebarVisible: isSidebarVisible,
                fieldMounted: renameFieldMountedKey == sessionKey(session),
                expectedGeneration: mountGeneration,
                currentGeneration: renameFieldMountGeneration
            )
        else { return }
        commitRename(freshSession(matching: session), to: raw)
    }

    /// The fallback rename alert may set `isPresented` to false before the
    /// button action. Only cancel when that dismiss was not a completed commit.
    static func shouldCancelRenameAlert(didCommit: Bool) -> Bool {
        !didCommit
    }

    /// `expectedGeneration` is captured when the dismiss Task is scheduled.
    /// A later beginRename bumps the current generation and poisons this cancel.
    static func shouldCancelRenameAlertAfterYield(
        isCancelled: Bool,
        sidebarVisible: Bool,
        didCommit: Bool,
        stillRenaming: Bool,
        expectedGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        !isCancelled && sidebarVisible && !didCommit && stillRenaming
            && expectedGeneration == currentGeneration
    }

    /// The live rename's field may mark itself mounted even if another row
    /// still thinks it owns the flag.
    static func shouldApplyRenameFieldMount(
        mountKey: String, activeKey: String?, mountedKey: String?
    ) -> Bool {
        mountKey == activeKey && mountedKey != mountKey
    }

    /// Ignore unmounts that are not for the active key, or that do not match
    /// the field currently tracked as mounted.
    static func shouldApplyRenameFieldUnmount(
        unmountKey: String, activeKey: String?, mountedKey: String?
    ) -> Bool {
        unmountKey == activeKey && mountedKey == unmountKey
    }

    static func renameRowUsesButtonTrait(isRenaming: Bool) -> Bool {
        !isRenaming
    }

    static func renameRowOffersResetName(hasCustomName: Bool) -> Bool {
        hasCustomName
    }

    static func shouldCommitInlineBlur(
        keyMatches: Bool,
        rowVisible: Bool,
        sidebarVisible: Bool,
        fieldMounted: Bool,
        expectedGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        keyMatches && rowVisible && sidebarVisible && fieldMounted
            && expectedGeneration == currentGeneration
    }

    /// After the blur-task yield, skip if FocusState landed on the field.
    static func shouldCommitInlineBlurAfterYield(focusIsRename: Bool) -> Bool {
        !focusIsRename
    }

    static func shouldCancelPendingBlurCommit(focusIsRename: Bool) -> Bool {
        focusIsRename
    }

    static func shouldSelectRenameDraft(
        selectAllPending: Bool,
        isCancelled: Bool,
        isRenaming: Bool
    ) -> Bool {
        selectAllPending && !isCancelled && isRenaming
    }

    /// ⌘B restore must not select-all. LazyVStack recycle must not clear
    /// pending before the fresh begin can consume it.
    static func shouldClearRenameSelectAllOnSidebarHide(
        wasVisible: Bool, isVisible: Bool
    ) -> Bool {
        wasVisible && !isVisible
    }

    /// Fallback alert: select-all only on a fresh beginRename, never on ⌘B
    /// restore or any other remount that continues a typed draft.
    static func shouldSelectRenameAlertDraft(
        selectAllPending: Bool,
        isCancelled: Bool,
        isRenaming: Bool,
        forceRepresent: Bool
    ) -> Bool {
        !forceRepresent
            && shouldSelectRenameDraft(
                selectAllPending: selectAllPending,
                isCancelled: isCancelled,
                isRenaming: isRenaming
            )
    }

    /// After the alert select-all yield, consume only if this prepare is still
    /// the live prompt. `.task(id: visibleRowIDs)` is not cancelled on key
    /// change, so a stale prepare must not steal a newer beginRename's pending.
    static func shouldConsumeRenameAlertSelectAll(
        expectedKey: String?,
        currentKey: String?,
        currentSurface: RenameSurface,
        selectAllPending: Bool,
        isCancelled: Bool,
        forceRepresent: Bool
    ) -> Bool {
        shouldFinishPromptHandoff(
            isCancelled: isCancelled,
            expectedKey: expectedKey,
            currentKey: currentKey,
            currentSurface: currentSurface
        )
            && shouldSelectRenameAlertDraft(
                selectAllPending: selectAllPending,
                isCancelled: isCancelled,
                isRenaming: currentKey != nil,
                forceRepresent: forceRepresent
            )
    }

    /// Ready means the field editor is first responder and is editing the
    /// rename field. A leftover search or dormant editor is not ready.
    static func isRenameFieldEditorReady(
        fieldEditorExists: Bool,
        fieldEditorIsFirstResponder: Bool,
        isEditingRenameField: Bool
    ) -> Bool {
        fieldEditorExists && fieldEditorIsFirstResponder && isEditingRenameField
    }

    /// Alert draft is the rename field when the alert window is key and the
    /// editor string is the live draft. revealRenameAlert leaves the main
    /// window key, so a leftover search editor must not count.
    static func isEditingRenameAlertField(
        hasKeyWindow: Bool,
        keyWindowIsMain: Bool,
        keyWindowIsSheet: Bool,
        editorStringMatchesDraft: Bool
    ) -> Bool {
        guard hasKeyWindow, editorStringMatchesDraft else { return false }
        return keyWindowIsSheet || !keyWindowIsMain
    }

    /// Consume pending only when the rename field editor is ready so a
    /// leftover search or dormant editor cannot steal select-all.
    static func shouldConsumeRenameSelectAll(
        fieldEditorReady: Bool, selectAllPending: Bool
    ) -> Bool {
        fieldEditorReady && selectAllPending
    }

    /// Skip select-all when the user already edited past the armed draft.
    static func shouldSelectRenameDraftIfUnedited(
        currentDraft: String, baseline: String?
    ) -> Bool {
        guard let baseline else { return false }
        return currentDraft == baseline
    }

    /// Same-key F2/⌘⇧R must not re-arm select-all; a late select would wipe typing.
    static func shouldArmRenameSelectAllOnBegin(isFreshKey: Bool) -> Bool {
        isFreshKey
    }

    /// Clear prepared surface on every begin so a same-key F2 after dismiss
    /// is not treated as an already-configured prompt/inline handoff.
    static func shouldInvalidatePreparedRenameOnBegin() -> Bool {
        true
    }

    /// Click-out leaves the prompt prepared but hidden. Same-key begin must
    /// show it again without reseeding the draft.
    static func shouldRepresentRenamePromptOnSameKeyBegin(
        isFreshKey: Bool,
        showRenameAlert: Bool,
        preparedSurface: RenameSurface
    ) -> Bool {
        !isFreshKey && !showRenameAlert && preparedSurface == .prompt
    }

    /// One frame between retries. The first ready check is immediate.
    static let renameSelectAllRetryInterval: Duration = .milliseconds(16)

    /// Stop waiting so a never-ready editor cannot spin the MainActor.
    static let renameSelectAllRetryTimeout: Duration = .milliseconds(400)

    static func shouldContinueRenameSelectAllRetry(elapsed: Duration) -> Bool {
        elapsed < renameSelectAllRetryTimeout
    }

    /// A never-ready editor must drop the fresh-begin flag so a later remount
    /// or prompt→inline handoff cannot selectAll and wipe typed text.
    static func shouldClearRenameSelectAllOnRetryTimeout() -> Bool {
        true
    }

    static func shouldSelectRenameDraftOnRetryTimeout() -> Bool {
        false
    }

    /// Return commits the fallback alert, matching the inline field's onSubmit.
    static func renameAlertCommitUsesDefaultAction() -> Bool {
        true
    }

    /// ⌘B restore of an in-progress prompt. A fresh beginRename that merely
    /// opens a hidden sidebar is not a restore — select-all must still fire.
    static func shouldForcePromptRepresent(
        isRenaming: Bool,
        rowVisible: Bool,
        sidebarVisible: Bool,
        showRenameAlert: Bool,
        preparedSurface: RenameSurface
    ) -> Bool {
        isRenaming && !rowVisible && sidebarVisible
            && (showRenameAlert || preparedSurface == .prompt)
    }

    static func shouldPrepareRename(isCancelled: Bool) -> Bool {
        !isCancelled
    }

    /// Only a true forceRepresent restore may drop select-all. A cancelled
    /// sibling prepareRename must not wipe a newer beginRename's pending flag.
    static func shouldClearRenameSelectAllOnPrepare(
        forceRepresent: Bool, isCancelled: Bool
    ) -> Bool {
        forceRepresent && !isCancelled
    }

    static func renameSurface(
        isRenaming: Bool,
        sessionAvailable: Bool,
        rowVisible: Bool
    ) -> RenameSurface {
        guard isRenaming, sessionAvailable else { return .none }
        return rowVisible ? .inline : .prompt
    }

    /// List reshuffles must not re-arm the fallback alert. Only a key or
    /// surface change (or a fresh rename) should reconfigure.
    /// `forceReconfigure` is not a draft write — beginRename owns the draft.
    static func shouldReconfigureRename(
        previousKey: String?,
        previousSurface: RenameSurface,
        nextKey: String?,
        nextSurface: RenameSurface,
        forceReconfigure: Bool,
        forceRepresent: Bool = false
    ) -> Bool {
        if forceRepresent { return true }
        if forceReconfigure { return true }
        return previousKey != nextKey || previousSurface != nextSurface
    }

    /// After yielding to let the inline field mount, only steal focus if this
    /// handoff is still the live inline rename.
    static func shouldFinishInlineHandoff(
        isCancelled: Bool,
        expectedKey: String?,
        currentKey: String?,
        currentSurface: RenameSurface
    ) -> Bool {
        !isCancelled && expectedKey != nil && expectedKey == currentKey
            && currentSurface == .inline
    }

    /// After the forceRepresent pulse yield, only re-present the fallback
    /// alert if this task is still the live prompt rename. A sibling
    /// visibility task may have switched to inline during the wait.
    static func shouldFinishPromptHandoff(
        isCancelled: Bool,
        expectedKey: String?,
        currentKey: String?,
        currentSurface: RenameSurface
    ) -> Bool {
        !isCancelled && expectedKey != nil && expectedKey == currentKey
            && currentSurface == .prompt
    }

    /// After yielding to focus the inline field, skip if the row task was
    /// cancelled or the row is no longer renaming.
    static func shouldStealRenameFocusAfterYield(
        isCancelled: Bool,
        isRenaming: Bool
    ) -> Bool {
        !isCancelled && isRenaming
    }

    /// Return/Escape must not leave blur suppression armed for the next click-away.
    static func shouldClearBlurSuppressionAfterCommitOrAbandon() -> Bool {
        true
    }

    /// After the focus-steal wait times out, a still-live rename whose field
    /// is not focused is a stuck session — commit as if the field blurred.
    /// Two yields alone are not a miss.
    static func shouldCommitRenameIfFocusStealMissed(
        isRenaming: Bool, focusIsRename: Bool
    ) -> Bool {
        isRenaming && !focusIsRename
    }

    /// Wait with the same interval/timeout as select-all. Ready or `.rename`
    /// focus falls through immediately (F2/⌘⇧R stay instant). A miss is only
    /// a timeout while still renaming with focus off the field.
    static func renameFocusStealFollowUp(
        fieldEditorReady: Bool,
        focusIsRename: Bool,
        isCancelled: Bool,
        isRenaming: Bool,
        elapsed: Duration
    ) -> RenameFocusStealFollowUp {
        if fieldEditorReady || focusIsRename { return .selectAll }
        guard
            shouldStealRenameFocusAfterYield(
                isCancelled: isCancelled, isRenaming: isRenaming)
        else { return .abort }
        if shouldContinueRenameSelectAllRetry(elapsed: elapsed) { return .wait }
        return shouldCommitRenameIfFocusStealMissed(
            isRenaming: isRenaming, focusIsRename: focusIsRename)
            ? .miss : .abort
    }

    /// The conversation on screen, when the store knows it. Menu-bar Rename uses this.
    func sessionForSelectedTab() -> GrokSession? {
        guard let tab = selectedTab else { return nil }
        return session(for: tab)
    }

    /// The saved Grok chat behind `tab`, when the store knows it.
    func session(for tab: TerminalTab) -> GrokSession? {
        guard let id = tab.sessionID else { return nil }
        return store.sessions.first {
            $0.id == id && samePath($0.cwd, tab.workingDirectory.path)
        }
    }

    /// Output and status changes reach the phone through the remote stream.
    private func wireRemoteStream(_ tab: TerminalTab) {
        tab.onActivityChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.remoteControl.noteChange()
            self.remoteControl.noteTab(tab, model: self)
        }
        tab.controller.onRemoteOutput = { [weak self, weak tab] in
            guard let self, let tab else { return }
            if self.selectedTabID == tab.id { self.remoteControl.noteChange() }
            self.remoteControl.noteTab(tab, model: self)
        }
    }

    /// The phone's rename. Same rules as a right-click on the tab.
    func renameFromRemote(_ tab: TerminalTab, to name: String) {
        renameTab(tab, to: name)
    }

    /// The phone's archive: never asks, because a modal alert would block the
    /// remote loop. Returns false for a tab with no saved chat to archive.
    func archiveFromRemote(_ tab: TerminalTab) -> Bool {
        guard let session = session(for: tab) else { return false }
        archiveWithoutAsking([session])
        return true
    }

    /// A tab's label. New sessions start out named after their folder; once the CLI
    /// writes a summary for them, the store supplies the conversation name. A
    /// user-chosen name wins even when the CLI has not written a summary yet,
    /// and even when the store has not listed the session yet.
    func title(for tab: TerminalTab) -> String {
        if let id = tab.sessionID,
            let custom = ConversationNaming.name(
                sessionID: id,
                cwd: tab.workingDirectory.path,
                in: settings.conversationNames,
                samePath: samePath)
        {
            return custom
        }
        if let session = session(for: tab),
            !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return session.title
        }
        return tab.title
    }

    func tabColor(for tab: TerminalTab) -> TabColor? {
        if let id = tab.sessionID {
            return TabColors.color(
                sessionID: id,
                cwd: tab.workingDirectory.path,
                in: settings.tabColors,
                samePath: samePath)
        }
        return tab.markColor
    }

    func setTabColor(_ tab: TerminalTab, to color: TabColor?) {
        guard let id = tab.sessionID else {
            tab.markColor = color
            return
        }
        settings.reloadSharedLists()
        let next = TabColors.setting(
            color,
            sessionID: id,
            cwd: tab.workingDirectory.path,
            onto: settings.tabColors,
            samePath: samePath)
        guard next != settings.tabColors else { return }
        settings.tabColors = next
    }

    func hasCustomTabName(_ tab: TerminalTab) -> Bool {
        if let id = tab.sessionID {
            return ConversationNaming.name(
                sessionID: id,
                cwd: tab.workingDirectory.path,
                in: settings.conversationNames,
                samePath: samePath) != nil
        }
        guard let local = tab.sessionTitle, !local.isEmpty else { return false }
        return local != automaticTitle(for: tab)
    }

    /// Empty, whitespace, or the automatic title clears a user name.
    /// A Grok conversation keeps the name the sidebar uses.
    func renameTab(_ tab: TerminalTab, to raw: String) {
        if let session = session(for: tab) {
            rename(session, to: raw)
            return
        }
        if let id = tab.sessionID {
            let next = ConversationNaming.setting(
                raw,
                sessionID: id,
                cwd: tab.workingDirectory.path,
                cliTitle: automaticTitle(for: tab),
                onto: settings.conversationNames,
                samePath: samePath)
            guard next != settings.conversationNames else { return }
            settings.conversationNames = next
            return
        }
        let trimmed = ConversationNaming.normalized(raw)
        tab.sessionTitle = (trimmed == nil || trimmed == automaticTitle(for: tab)) ? nil : trimmed
    }

    func resetTabName(_ tab: TerminalTab) {
        if let session = session(for: tab) {
            resetName(session)
            return
        }
        if let id = tab.sessionID {
            let next = ConversationNaming.removing(
                sessionID: id,
                cwd: tab.workingDirectory.path,
                from: settings.conversationNames,
                samePath: samePath)
            if next != settings.conversationNames {
                settings.conversationNames = next
            }
            return
        }
        tab.sessionTitle = nil
    }

    /// The tab's own default label. Not a user name and not a CLI summary.
    private func automaticTitle(for tab: TerminalTab) -> String {
        tab.automaticTitle
    }

    private func clearTabColor(_ session: GrokSession) {
        settings.reloadSharedLists()
        let next = TabColors.removing(
            sessionID: session.id,
            cwd: session.cwd,
            from: settings.tabColors,
            samePath: samePath)
        guard next != settings.tabColors else { return }
        settings.tabColors = next
    }

    /// Same label `open` writes: the sidebar name, including the empty-summary
    /// fallback. A nil `sessionTitle` would fall through to the folder name.
    private func applyNameToOpenTabs(_ session: GrokSession) {
        let nextTitle = title(for: session)
        for tab in tabs where tabMatches(tab, sessionID: session.id, cwd: session.cwd) {
            tab.sessionTitle = nextTitle
        }
    }

    // MARK: - Tabs

    func requestNewSession(in directory: URL? = nil) {
        pendingSessionDirectory = directory ?? newSessionDirectory
        isShowingNewSessionSheet = true
        if !Self.isRunningAutomatedTests {
            Task { [weak self] in await self?.refreshProviderInstallations() }
        }
    }

    /// CLI lookup and version checks never block window drawing or input.
    func refreshProviderInstallations() async {
        let generation = UUID()
        providerCheckGeneration = generation
        let executable = settings.executableURL
        let probe = providerProbe
        // A prior result does not authorize launches while its replacement is pending.
        checkingProviders = Set(CLIProvider.allCases)
        providerInstallations.removeAll()
        defer {
            if providerCheckGeneration == generation { checkingProviders.removeAll() }
        }
        let found = await withTaskGroup(of: (CLIProvider, ProviderInstallation).self) { group in
            for provider in CLIProvider.allCases {
                group.addTask {
                    let result = await probe(provider, provider == .grokBuild ? executable : nil)
                    return (provider, result)
                }
            }
            var result: [CLIProvider: ProviderInstallation] = [:]
            for await (provider, installation) in group { result[provider] = installation }
            return result
        }
        guard providerCheckGeneration == generation, !Task.isCancelled else { return }
        // Publish together: restoration must keep saved order, not probe completion
        // order, including when a history scan finishes while checks are in flight.
        providerInstallations = found
        checkingProviders.removeAll()
        if !deferredOpenTabs.isEmpty { restoreOpenTabs() }
    }

    /// Shared by desktop, phone, and restoration. An absent result is unknown,
    /// never permission to launch. Existing open tabs remain usable during checks.
    func providerLaunchProblem(_ provider: CLIProvider) -> String? {
        if provider == .grokBuild, !settings.executableExists {
            return "Restore the Grok CLI on your Mac, then try again."
        }
        guard !checkingProviders.contains(provider), let installation = providerInstallations[provider] else {
            return "Checking \(provider.name)… Try again shortly."
        }
        guard installation.isAvailable else {
            return installation.problem ?? "\(provider.name) is unavailable."
        }
        return nil
    }

    private func canLaunchProvider(_ provider: CLIProvider) -> Bool {
        guard let problem = providerLaunchProblem(provider) else { return true }
        showError(title: "\(provider.name) is unavailable", message: problem)
        return false
    }

    /// ⇧⌘N: choose the folder first, then open the new-session sheet on it.
    func requestNewSessionInFolder(choose: () -> URL?) {
        guard let folder = choose() else { return }
        requestNewSession(in: folder)
    }

    @discardableResult
    func newTab(
        in directory: URL, model: String? = nil, effort: String? = nil, fastMode: Bool = false,
        provider: CLIProvider = .grokBuild
    ) -> TerminalTab? {
        guard canLaunchProvider(provider) else { return nil }
        guard Self.isUsableDirectory(directory) else {
            showError(title: "Folder is unavailable", message: "Choose another folder.")
            return nil
        }
        guard canSignIn(provider), let providerEnvironment = providerEnvironment(for: provider) else {
            return nil
        }
        // Settings holds Grok's defaults. Another CLI keeps its own unless the caller names one.
        let isGrok = provider == .grokBuild
        let spec = GrokLaunchSpec(
            executable: isGrok ? settings.executableURL : nil,
            workingDirectory: directory,
            mode: .new(sessionID: UUID()),
            model: (model ?? (isGrok ? settings.model : "")).nilIfEmpty,
            reasoningEffort: (effort ?? (isGrok ? settings.effort : "")).nilIfEmpty,
            fastMode: fastMode,
            themeName: settings.theme.grokThemeName,
            themeVariables: settings.theme.grokThemeEnvironment,
            providerEnvironment: providerEnvironment,
            provider: provider
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
        guard canLaunchProvider(session.provider) else { return }
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        guard Self.isUsableDirectory(workingDirectory) else {
            showError(
                title: "Folder is unavailable",
                message: "Restore the folder, then try again."
            )
            return
        }
        let spec = GrokLaunchSpec(
            executable: session.provider == .grokBuild ? settings.executableURL : nil,
            workingDirectory: workingDirectory,
            mode: .resume(sessionID: session.nativeSessionID),
            model: session.provider == .grokBuild ? settings.model.nilIfEmpty : nil,
            reasoningEffort: session.provider == .grokBuild ? settings.effort.nilIfEmpty : nil,
            themeName: settings.theme.grokThemeName,
            themeVariables: settings.theme.grokThemeEnvironment,
            provider: session.provider, sessionFile: session.provider == .grokBuild ? nil : session.directory
        )
        let tab = add(spec)
        tab.sessionTitle = title(for: session)
    }

    @discardableResult
    private func add(_ spec: GrokLaunchSpec) -> TerminalTab {
        let tabID = UUID()
        let tab = TerminalTab(id: tabID, spec: tagged(spec, tabID: tabID), settings: settings)
        tab.onUnseenActivityChange = { [weak self] in self?.refreshDockIndicator() }
        tab.onSettle = { [weak self, weak tab] in
            if let self, let tab { self.restartForThemeWhenSettled(tab) }
        }
        wireRemoteStream(tab)
        // Only a chat this tab creates; opening an existing chat does not make it Sigil's.
        if case .new = spec.mode, let sessionID = tab.sessionID { settings.recordSigilConversations([sessionID]) }
        tabs.append(tab)
        selectedTabID = tab.id
        if !isRestoringTabs { clearDeferredSelection() }
        if !isRestoringTabs { rememberDefaultDirectory(spec.workingDirectory) }
        // Grok writes a session the sidebar finds. Other CLIs do not, so
        // record their folder or it never shows up in Projects.
        if !isRestoringTabs, spec.provider != .grokBuild, !isEphemeral(path: spec.workingDirectory.path) {
            addProject(spec.workingDirectory)
        }
        // Opened by hand now, so closing it must not bring the saved entry back.
        if !isRestoringTabs, let sessionID = tab.sessionID {
            deferredOpenTabs.removeAll {
                entryMatches($0, sessionID: sessionID, cwd: spec.workingDirectory.path)
            }
        }
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
        let old = tabs[index]
        guard old.spec.provider != .codex || old.sessionReference != nil else {
            showError(
                title: "Open this conversation from history",
                message: "This tab's Codex session ID is not known. Find the conversation in the sidebar.")
            return
        }
        guard canLaunchProvider(old.spec.provider) else { return }
        // `.new` tabs already have a UUID the CLI wrote a session directory for.
        guard old.spec.provider != .grokBuild || old.sessionID != nil else { return }
        guard Self.isUsableDirectory(old.workingDirectory) else {
            showError(
                title: "Folder is unavailable",
                message: "Restore the folder, then try again."
            )
            return
        }
        guard canSignIn(old.spec.provider) else { return }
        let wasSelected = selectedTabID == old.id
        tabBridge?.noteTabClosed(id: old.id)
        old.terminateAndWait()
        let tab = replacementTab(for: old, sessionID: old.sessionID)
        tabs[index] = tab
        if wasSelected { selectedTabID = tab.id }
        persistOpenTabs()
    }

    /// Builds a fresh process for a stopped tab without changing its position,
    /// title, per-tab launch options, or current selection.
    private func replacementTab(for old: TerminalTab, sessionID: String?) -> TerminalTab {
        var spec = old.spec
        if spec.provider == .grokBuild, let sessionID {
            spec.executable = settings.executableURL
            if case .new = old.spec.mode,
                let directory = old.spec.sessionDirectory,
                !Self.isUsableDirectory(directory)
            {
                spec.mode = old.spec.mode
            } else {
                spec.mode = .resume(sessionID: sessionID)
            }
            spec.themeName = settings.theme.grokThemeName
            spec.themeVariables = settings.theme.grokThemeEnvironment
        }
        if spec.provider != .grokBuild, let reference = old.sessionReference {
            spec.mode = .resume(sessionID: reference.sessionID)
        }
        // A restart follows the current Kimi sign-in, not the one it started with.
        spec.providerEnvironment = providerEnvironment(for: spec.provider) ?? [:]
        spec.bridgeTabID = nil
        spec.bridgeSocketPath = nil
        let tabID = UUID()
        let tab = TerminalTab(id: tabID, spec: tagged(spec, tabID: tabID), settings: settings)
        tab.onUnseenActivityChange = { [weak self] in self?.refreshDockIndicator() }
        tab.onSettle = { [weak self, weak tab] in
            if let self, let tab { self.restartForThemeWhenSettled(tab) }
        }
        wireRemoteStream(tab)
        tab.sessionTitle = old.sessionTitle
        tab.markColor = old.markColor
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
        removeTab(at: index)
        refreshDockIndicator()
        persistOpenTabs()
    }

    /// Everything closing a tab does except writing the open-tab list.
    private func removeTab(at index: Int) {
        let id = tabs[index].id
        tabBridge?.noteTabClosed(id: id)
        remoteControl.forgetTab(id)
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
    }

    /// Stops several tabs against one shared deadline. Every child gets SIGTERM
    /// first, so a child that ignores it does not make the next one wait.
    private func stopAndWait(_ stopping: [TerminalTab]) {
        for tab in stopping { tab.terminate() }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        for tab in stopping {
            // A short floor still reaps a child killed after the deadline.
            tab.terminateAndWait(timeout: max(deadline - .now, .milliseconds(100)))
        }
    }

    /// User-facing close: warn when the agent is mid-turn so a click does not kill work.
    func requestCloseTab(_ id: TerminalTab.ID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if let prompt = StopWorkingPrompt(action: .closeTab, stopping: [tab]),
            !confirmStop(prompt)
        {
            return
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
        focusSelectedTerminal()
    }

    func focusSelectedTerminal() {
        guard let tab = selectedTab else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, self.selectedTab?.id == tab.id else { return }
            guard !self.isFindBarVisible, !self.isShowingNewSessionSheet else { return }
            guard let window = tab.controller.view.window, window.isKeyWindow,
                window.attachedSheet == nil
            else {
                self.needsTerminalFocus = true
                return
            }
            self.needsTerminalFocus = false
            tab.controller.focus()
        }
    }

    /// Selection can precede AppKit attachment, after the window already became
    /// key. Retry that pending request when its actual terminal view arrives.
    func terminalViewDidAttach(tabID: TerminalTab.ID) {
        guard needsTerminalFocus, selectedTab?.id == tabID else { return }
        focusSelectedTerminal()
    }

    /// Hiding a column removes its views. When one of them had focus, the
    /// window would be left with no first responder and every key would beep.
    private func refocusTerminalAfterHiding(_ column: KeyboardFocus.Column) {
        guard let view = selectedTab?.controller.view, let window = view.window else { return }
        let focus = KeyboardFocus.classify(
            window.firstResponder, in: window, sessionView: view,
            panelShellView: panel.shell?.view,
            sidebarHasFocus: isSidebarFocused || isSidebarDividerFocused)
        if focus.needsTerminalAfterHiding(column) { focusSelectedTerminal() }
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

    /// Quit path: no `grok` process may outlive the app, and there is no run loop
    /// left to finish an asynchronous kill. Does not persist — the last user
    /// mutation already wrote the tabs that should come back next launch.
    func closeAllTabsAndWait() {
        remoteControl.stop()
        stopTabMessaging()
        panel.closeShellAndWait()
        panel.flushNotes()
        transcriptExports.stopAll()
        stopAndWait(tabs)
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
                // The registration is shared, so only the copy holding the socket
                // may remove it; taking the socket throws while another copy has it.
                try startTabMessaging()
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

    /// Starts the local listener and registers (or updates) the helper when the
    /// saved switch is on. `grok mcp add` rewrites a stale absolute helper path
    /// after the app bundle moves.
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
            // Keep the local server and the user's setting. A pre-existing
            // registration must not be deleted because this run's install failed.
            tabMessagingError = error.localizedDescription
            Self.bridgeLog.error(
                "Tab messaging registration failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func startTabMessaging() throws {
        if tabBridge?.isListening == true { return }
        let bridge = TabBridge(model: self, socketURL: tabMessagingSocketURL)
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

    /// `grok mcp add` is add-or-update (verified grok 1.0.5). Re-running it after
    /// the app moves rewrites the registered helper path. Do not skip merely
    /// because a server named `sigil` already exists.
    private func installTabMessagingRegistration() async throws {
        let executable = settings.executableURL
        let runner = registrationRunner
        guard let helper = mcpBinaryOverride ?? BridgeRegistration.bundledMCPBinary else {
            throw TabMessagingChangeError.helperMissing
        }
        try await Self.runOffCooperativePool {
            let registration = BridgeRegistration(executable: executable, runner: runner)
            try registration.install(mcpBinary: helper)
        }
    }

    private func removeTabMessagingRegistration() async throws {
        let executable = settings.executableURL
        let runner = registrationRunner
        try await Self.runOffCooperativePool {
            let registration = BridgeRegistration(executable: executable, runner: runner)
            try registration.remove()
        }
    }

    /// `grok mcp` waits on semaphores for up to about a minute. A Swift task
    /// would park one of the few cooperative-pool threads for that long.
    private nonisolated static func runOffCooperativePool(
        _ work: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
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
        guard spec.provider == .grokBuild, isTabMessagingAvailable, let bridge = tabBridge else { return spec }
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
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = tabs.contains(where: \.hasUnseenActivity) ? "•" : nil
        app.dockTile.display()
    }

    /// How often the snapshot a crash report carries is brought up to date.
    /// Often enough to catch the turn that killed the app, seldom enough that
    /// reading the terminal buffer costs nothing anyone can feel.
    static let crashStateInterval: Duration = .seconds(5)
    /// Tabs listed in that snapshot before it says how many more there were.
    static let crashStateTabLimit = 12
    /// Bytes a single name or path may take in that snapshot.
    static let crashStateFieldLimit = 120

    private func startCrashStateRefresh() {
        guard crashStateTask == nil else { return }
        crashStateTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                CrashReporter.updateState(self.crashState())
                try? await Task.sleep(for: Self.crashStateInterval)
            }
        }
    }

    /// What Sigil was doing, in the form a crash report keeps in memory. A
    /// backtrace says where the app died; this says what the user was doing
    /// when it happened, which is the half that makes a report answerable.
    func crashState() -> String {
        var lines = ["tabs open: \(tabs.count)"]
        let selected = selectedTab
        for tab in tabs.prefix(Self.crashStateTabLimit) {
            let marker = tab.id == selected?.id ? "*" : "-"
            let activity = Self.describe(tab.activity)
            // A conversation name is the user's own text and a path can be any
            // length, so bound both: one long tab should not be able to push
            // the others out of the report. The name is cut from the end and
            // the path from the front, which is the useful half of each.
            let name = CrashReporter.head(of: title(for: tab), bytes: Self.crashStateFieldLimit)
            let path = CrashReporter.tail(
                of: tab.workingDirectory.path, bytes: Self.crashStateFieldLimit)
            lines.append("\(marker) \(name) [\(activity)] \(path)")
        }
        if tabs.count > Self.crashStateTabLimit {
            lines.append("  and \(tabs.count - Self.crashStateTabLimit) more")
        }
        // Each section is bounded in bytes against its own budget, so the tab
        // list keeps its head and the terminal keeps its tail. Trimming the
        // finished snapshot as a whole would drop the tab list first.
        var state = CrashReporter.head(
            of: lines.joined(separator: "\n"), bytes: CrashReporter.tabListCapacity)
        if let selected {
            let name = CrashReporter.head(
                of: title(for: selected), bytes: Self.crashStateFieldLimit)
            let tail = CrashReporter.tail(
                of: selected.controller.crashSnapshot(), bytes: CrashReporter.terminalTailCapacity)
            state += "\n\nterminal tail — \(name):\n"
            state += tail.isEmpty ? "(nothing on screen)" : tail
        }
        return state
    }

    /// The activity name, plus the exit code when the child reported one.
    static func describe(_ activity: TerminalTab.Activity) -> String {
        guard case .exited(let code?) = activity else { return activity.statusName }
        return "\(activity.statusName) \(code)"
    }

    /// Help ▸ Reveal Crash Logs. Selects the newest report when there is one,
    /// so the user lands on the file to attach rather than a folder to search.
    func revealCrashLogs() {
        let directory = CrashLog.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let newest = CrashLog.mostRecentReport(in: directory) {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    /// Clear the selected tab's badge once its contents are visible again.
    func appDidBecomeActive() {
        selectedTab?.clearUnseenActivity()
        refreshDockIndicator()
        retryPendingTerminalFocus()
    }

    /// A panel shell opened while the sheet was up takes focus once it closes.
    func newSessionSheetDidClose() {
        if needsPanelShellFocus { focusPanelShell() } else { focusSelectedTerminal() }
    }

    func windowDidBecomeKey() {
        if needsPanelShellFocus { focusPanelShell() } else { retryPendingTerminalFocus() }
    }

    private func retryPendingTerminalFocus() {
        guard needsTerminalFocus else { return }
        focusSelectedTerminal()
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

    // MARK: - Right panel

    /// Shows `mode` in the panel, or hides the panel when that tool is already up.
    func showPanel(_ mode: RightPanelMode) {
        let wasVisible = panel.isVisible
        let wasShell = wasVisible && panel.mode == .shell
        panel.toggle(mode)
        preparePanel()
        // Switching away from the shell removes its view, just as hiding does.
        let isShell = panel.isVisible && panel.mode == .shell
        if wasVisible, !panel.isVisible || (wasShell && !isShell) {
            refocusTerminalAfterHiding(.panel)
        }
        requestPanelShellFocusIfShown()
    }

    /// Opens or closes the panel on whatever tool it last showed.
    func togglePanel() {
        let wasVisible = panel.isVisible
        panel.toggle(nil)
        preparePanel()
        if wasVisible, !panel.isVisible { refocusTerminalAfterHiding(.panel) }
        requestPanelShellFocusIfShown()
    }

    /// Kills the scratch shell and starts a new one in the current folder.
    func restartPanelShell() {
        if let prompt = StopWorkingPrompt(
            action: .restartShell, stopping: [], panelJob: panel.shellHasForegroundJob),
            !confirmStop(prompt)
        {
            return
        }
        panel.restartShell(
            in: currentDirectory, theme: settings.theme, fontSize: settings.fontSize)
        panel.shell?.optionAsMetaKey = settings.optionAsMetaKey
        requestPanelShellFocusIfShown()
    }

    /// Opening the shell means typing into it, not into the tab behind it.
    private func requestPanelShellFocusIfShown() {
        needsPanelShellFocus = panel.isVisible && panel.mode == .shell
        focusPanelShell()
    }

    /// Moves focus into the panel shell once its view is in the window. The
    /// panel calls this again when a new shell view appears.
    func focusPanelShell() {
        guard needsPanelShellFocus else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsPanelShellFocus, !self.isShowingNewSessionSheet,
                self.panel.isVisible, self.panel.mode == .shell, let shell = self.panel.shell,
                let window = shell.view.window, window.attachedSheet == nil
            else { return }
            self.needsPanelShellFocus = false
            shell.focus()
        }
    }

    /// Starts whatever the visible tool needs, with the app's own theme and size.
    private func preparePanel() {
        guard panel.isVisible, panel.mode == .shell else { return }
        panel.startShellIfNeeded(
            in: currentDirectory, theme: settings.theme, fontSize: settings.fontSize)
        panel.shell?.optionAsMetaKey = settings.optionAsMetaKey
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

    /// The View menu turns each font item off where it would do nothing.
    var canIncreaseFontSize: Bool { settings.fontSize < 32 }
    var canDecreaseFontSize: Bool { settings.fontSize > 8 }
    var canResetFontSize: Bool { settings.fontSize != 13 }

    func applyAppearance() {
        // Sheets, alerts, menus, and the Settings window are system-rendered;
        // they follow the app appearance, so the shell picks it, not macOS.
        NSApp.appearance = NSAppearance(named: settings.theme.isDark ? .darkAqua : .aqua)
        for tab in tabs {
            tab.controller.setFontSize(settings.fontSize)
            tab.controller.apply(theme: settings.theme)
        }
        panel.shell?.setFontSize(settings.fontSize)
        panel.shell?.apply(theme: settings.theme)
    }

    func applyOptionAsMetaKey() {
        for tab in tabs {
            tab.controller.optionAsMetaKey = settings.optionAsMetaKey
        }
        panel.shell?.optionAsMetaKey = settings.optionAsMetaKey
    }

    /// The Grok TUI reads `GROK_THEME` when the process starts. Recolouring
    /// SwiftTerm only changes the frame around it, so idle tabs are relaunched.
    /// A tab that is mid-turn is left alone so a theme click does not kill work.
    func applyTheme() {
        applyAppearance()
        let name = settings.theme.grokThemeName
        let vars = settings.theme.grokThemeEnvironment
        for tab in tabs where tab.spec.provider == .grokBuild {
            if tab.spec.themeName == name, tab.spec.themeVariables == vars { continue }
            // A relaunch would drop queued messages and fail pending questions.
            if tab.shouldWarnBeforeStopping || !tab.bridgeInbox.isEmpty {
                themeRestartsWhenSettled.insert(tab.id)
                continue
            }
            restartTab(id: tab.id)
        }
    }

    /// Asks before stopping work, then lets any theme relaunch that came due
    /// during the prompt run against the answer.
    private func confirmStop(_ prompt: StopWorkingPrompt) -> Bool {
        isAskingToStop = true
        defer {
            isAskingToStop = false
            for tab in tabs where themeRestartsWhenSettled.contains(tab.id) {
                restartForThemeWhenSettled(tab)
            }
        }
        return confirmStopWorking(prompt)
    }

    /// A tab that kept the old theme because it was busy relaunches on the new
    /// one once it settles, unless the theme was changed back meanwhile.
    private func restartForThemeWhenSettled(_ tab: TerminalTab) {
        guard themeRestartsWhenSettled.contains(tab.id) else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self, let tab, !self.isAskingToStop, self.tabs.contains(where: { $0 === tab }),
                !tab.shouldWarnBeforeStopping, tab.bridgeInbox.isEmpty
            else { return }
            self.themeRestartsWhenSettled.remove(tab.id)
            let theme = self.settings.theme
            guard
                tab.spec.themeName != theme.grokThemeName
                    || tab.spec.themeVariables != theme.grokThemeEnvironment
            else { return }
            self.restartTab(id: tab.id)
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
        NSPasteboard.general.setString(session.nativeSessionID, forType: .string)
    }

    /// Shows the thread list if it is hidden, then asks the search field for focus.
    func focusSidebarSearch() {
        if !isSidebarVisible { isSidebarVisible = true }
        searchFocusToken += 1
    }

    /// True once per Find Conversations request. The sidebar asks on mount and
    /// on each new token; only a request it has not acted on moves focus.
    func consumeSearchFocusRequest() -> Bool {
        guard searchFocusToken > consumedSearchFocusToken else { return false }
        consumedSearchFocusToken = searchFocusToken
        return true
    }

    // MARK: - Find

    /// Bumped by Cmd-F while the bar is open so its field takes focus again.
    private(set) var findFocusToken = 0

    /// Cmd-F opens the bar, or refocuses it; Escape and the close button dismiss it.
    func showFindBar() {
        guard selectedTab != nil else { return }
        if isFindBarVisible {
            findFocusToken += 1
        } else {
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
    func deleteConversation(_ session: GrokSession, reload: Bool = true) -> Bool {
        guard session.provider.capabilities.delete else { return false }
        let matchingTabs = tabs.filter {
            tabMatches($0, sessionID: session.id, cwd: session.cwd)
        }
        let stoppedTabs = matchingTabs.filter(\.isRunning)
        let tabsToRestore = matchingTabs.filter { tab in
            if tab.isRunning { return true }
            if case .exited(nil) = tab.activity { return true }
            return false
        }
        let selectionBeforeDelete = selectedTabID
        // Keep the tab objects and saved snapshot until Trash succeeds. If it
        // fails, relaunch tabs we stopped, and tabs whose process never started.
        for tab in stoppedTabs {
            tabBridge?.noteTabClosed(id: tab.id)
            tab.terminateAndWait()
        }
        do {
            try trashConversation(session.directory)
            unpin(session)
            unarchive(session)
            resetName(session)
            clearTabColor(session)
            panel.deleteNotes(forSessionID: session.id, cwd: session.cwd)
            // A same-ID conversation in another folder may still be waiting to
            // adopt the flat-layout note; when in doubt, keep the file.
            let flatNoteShared = store.sessions.contains {
                $0.id == session.id && !samePath($0.cwd, session.cwd)
            }
            if !flatNoteShared {
                panel.deleteFlatNotes(forSessionID: session.id)
            }
            let removedIDs = Set(matchingTabs.map(\.id))
            for tab in matchingTabs where !stoppedTabs.contains(where: { $0.id == tab.id }) {
                tabBridge?.noteTabClosed(id: tab.id)
            }
            let selectedWasRemoved = selectedTabID.map(removedIDs.contains) ?? false
            let firstRemovedIndex = tabs.firstIndex { removedIDs.contains($0.id) }
            tabs.removeAll { removedIDs.contains($0.id) }
            dropOrphanedProjectPin(for: session)
            deferredOpenTabs.removeAll {
                entryMatches($0, sessionID: session.id, cwd: session.cwd)
            }
            if let deferredSelectedEntry,
                entryMatches(deferredSelectedEntry, sessionID: session.id, cwd: session.cwd)
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
            if reload { Task { await store.reload() } }
            return true
        } catch {
            var replacementForSelection: TerminalTab.ID?
            for old in tabsToRestore {
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

    /// Trashes a multi-selection one conversation at a time; each delete keeps
    /// its own tab-restore-on-failure path. Returns how many went.
    @discardableResult
    func deleteConversations(_ sessions: [GrokSession]) -> Int {
        var deleted = 0
        for session in sessions where deleteConversation(session, reload: false) { deleted += 1 }
        // One rescan for the whole selection, not one per chat.
        if deleted > 0 { Task { await store.reload() } }
        return deleted
    }

    /// Writes `grok export <id>` to a file the user picks.
    ///
    /// The save panel stays on the main thread; the CLI itself runs off it so a
    /// long export cannot freeze the window.
    func exportTranscript(_ session: GrokSession) {
        guard session.provider.capabilities.export else { return }
        exportTranscript(
            sessionID: session.id,
            title: title(for: session),
            workingDirectory: URL(fileURLWithPath: session.cwd)
        )
    }

    var canExportSelectedTranscript: Bool {
        selectedTab.map { $0.spec.provider.capabilities.export && $0.sessionID != nil } ?? false
    }

    func exportSelectedTranscript() {
        guard let tab = selectedTab, tab.spec.provider.capabilities.export, let sessionID = tab.nativeSessionID else {
            return
        }
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
        startTranscriptExport(sessionID: sessionID, output: url, workingDirectory: workingDirectory)
    }

    func startTranscriptExport(sessionID: String, output url: URL, workingDirectory: URL) {
        let executable = settings.executableURL
        let exports = transcriptExports
        let id = UUID()
        Task {
            defer { exports.remove(id) }
            do {
                try await Self.runTranscriptExport(
                    executable: executable,
                    sessionID: sessionID,
                    output: url,
                    workingDirectory: workingDirectory,
                    onStart: { exports.add(id, process: $0, temporaryOutput: $1) }
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
        timeout: Duration = .seconds(300),
        onStart: (@Sendable (Process, URL) -> Void)? = nil
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
                onStart?(process, temporaryOutput)
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
            let stopDeadline = ContinuousClock.now + .seconds(2)
            while process.isRunning, ContinuousClock.now < stopDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            await waitForReader(readerFinished, handle: pipe.fileHandleForReading)
            guard !process.isRunning else {
                throw TranscriptExportError(
                    status: nil,
                    output: "Could not stop the transcript export.",
                    timedOut: false
                )
            }
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
            guard Darwin.rename(temporaryOutput.path, output.path) == 0 else {
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
                deferredSelectedEntry = .init(
                    sessionID: selectedID, cwd: selectedCWD, provider: snapshot.selectedProvider ?? .grokBuild)
                deferredLegacySelectedSessionID = nil
            } else {
                deferredSelectedEntry = nil
                deferredLegacySelectedSessionID = snapshot.selectedSessionID
            }
        }
        // Native paths come from the initial history scan. Starting Grok first
        // would reorder a mixed saved snapshot before those paths can be known.
        // A completed (even failed) scan lets genuinely missing entries defer
        // individually without holding back the available conversations.
        if store.appliedScanSequence == 0, deferredOpenTabs.contains(where: { $0.provider != .grokBuild }) {
            return
        }
        let candidates = deferredOpenTabs
        let previousSelection = selectedTabID
        let hadSavedSelection = deferredSelectedEntry != nil || deferredLegacySelectedSessionID != nil
        deferredOpenTabs.removeAll()
        isRestoringTabs = true
        defer {
            isRestoringTabs = false
            persistOpenTabs()
        }
        var restoredSelection: TerminalTab.ID?
        for entry in candidates {
            if tabs.contains(where: {
                tabMatches($0, sessionID: sidebarID(entry), cwd: entry.cwd)
            }) {
                continue
            }
            let known = store.sessions.first { $0.id == sidebarID(entry) && samePath($0.cwd, entry.cwd) }
            let directory =
                entry.provider == .grokBuild
                ? GrokPaths.sessionDirectory(cwd: entry.cwd, sessionID: entry.sessionID)
                : known?.directory
            let workingDirectory = URL(fileURLWithPath: entry.cwd)
            let historyExists = directory.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard historyExists, Self.isUsableDirectory(workingDirectory),
                providerLaunchProblem(entry.provider) == nil
            else {
                deferredOpenTabs.append(entry)
                continue
            }
            let spec = GrokLaunchSpec(
                executable: entry.provider == .grokBuild ? settings.executableURL : nil,
                workingDirectory: workingDirectory,
                mode: .resume(sessionID: entry.sessionID),
                model: entry.model.map(\.nilIfEmpty)
                    ?? (entry.provider == .grokBuild ? settings.model.nilIfEmpty : nil),
                reasoningEffort: entry.effort.map(\.nilIfEmpty)
                    ?? (entry.provider == .grokBuild ? settings.effort.nilIfEmpty : nil),
                themeName: settings.theme.grokThemeName,
                themeVariables: settings.theme.grokThemeEnvironment,
                provider: entry.provider, sessionFile: entry.provider == .grokBuild ? nil : directory
            )
            let tab = add(spec)
            if deferredSelectedEntry.map({ sameEntry($0, entry) }) == true
                || (deferredSelectedEntry == nil
                    && deferredLegacySelectedSessionID == entry.sessionID
                    && restoredSelection == nil)
            {
                restoredSelection = tab.id
            }
        }
        if let restoredSelection {
            select(restoredSelection)
        } else if !hadSavedSelection, let previousSelection, tabs.contains(where: { $0.id == previousSelection }) {
            select(previousSelection)
        }
    }

    private func persistOpenTabs() {
        guard !isRestoringTabs else { return }
        var entries = tabs.compactMap { tab -> OpenTabsSnapshot.Entry? in
            guard let sessionID = tab.nativeSessionID else { return nil }
            return OpenTabsSnapshot.Entry(
                sessionID: sessionID, cwd: tab.workingDirectory.path,
                model: tab.spec.model ?? "", effort: tab.spec.reasoningEffort ?? "", provider: tab.spec.provider)
        }
        let liveKeys = Set(entries.map { entryKey($0) })
        entries.append(
            contentsOf: deferredOpenTabs.filter {
                !liveKeys.contains(entryKey($0))
            }
        )
        let liveSelection = selectedTab.flatMap { tab -> OpenTabsSnapshot.Entry? in
            guard let sessionID = tab.nativeSessionID else { return nil }
            return .init(sessionID: sessionID, cwd: tab.workingDirectory.path, provider: tab.spec.provider)
        }
        let exactSelection = deferredSelectedEntry ?? liveSelection
        settings.openTabs = OpenTabsSnapshot(
            tabs: entries,
            selectedSessionID: exactSelection?.sessionID ?? deferredLegacySelectedSessionID,
            selectedCWD: exactSelection?.cwd, selectedProvider: exactSelection?.provider
        )
    }

    private func rememberDefaultDirectory(_ directory: URL) {
        if isEphemeral(path: directory.path) { return }
        settings.defaultDirectory = SigilWorktree.projectPath(of: directory.path) ?? directory.path
    }

    private func tabMatches(_ tab: TerminalTab, sessionID: String, cwd: String) -> Bool {
        tab.sessionID == sessionID && samePath(tab.workingDirectory.path, cwd)
    }

    private func entryMatches(
        _ entry: OpenTabsSnapshot.Entry, sessionID: String, cwd: String
    ) -> Bool {
        sidebarID(entry) == sessionID && samePath(entry.cwd, cwd)
    }

    private func sameEntry(
        _ lhs: OpenTabsSnapshot.Entry, _ rhs: OpenTabsSnapshot.Entry
    ) -> Bool {
        entryMatches(lhs, sessionID: sidebarID(rhs), cwd: rhs.cwd)
    }

    private func sidebarID(_ entry: OpenTabsSnapshot.Entry) -> String {
        ProviderSessionReference(provider: entry.provider, sessionID: entry.sessionID, cwd: entry.cwd).sidebarID
    }

    private func entryKey(_ entry: OpenTabsSnapshot.Entry) -> String {
        sidebarID(entry) + "\u{0}" + canonicalPath(entry.cwd)
    }

    /// True when `path` is `project` or a Sigil worktree made from it.
    private func inProject(_ path: String, _ project: String) -> Bool {
        samePath(SigilWorktree.projectPath(of: path) ?? path, project)
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func canonicalPath(_ path: String) -> String {
        let tabCount = tabs.count
        let sessionCount = store.sessions.count
        if tabCount != canonicalCacheTabCount || sessionCount != canonicalCacheSessionCount {
            canonicalPathCache.removeAll(keepingCapacity: true)
            canonicalCacheTabCount = tabCount
            canonicalCacheSessionCount = sessionCount
        }
        if let cached = canonicalPathCache[path] { return cached }
        let resolved = resolveCanonicalPath(path)
        canonicalPathCache[path] = resolved
        return resolved
    }

    private func clearDeferredSelection() {
        deferredSelectedEntry = nil
        deferredLegacySelectedSessionID = nil
    }

    private func dropDeferred(matching session: GrokSession) {
        deferredOpenTabs.removeAll {
            entryMatches($0, sessionID: session.id, cwd: session.cwd)
        }
        if let deferredSelectedEntry,
            entryMatches(deferredSelectedEntry, sessionID: session.id, cwd: session.cwd)
        {
            clearDeferredSelection()
        } else if deferredLegacySelectedSessionID == session.id {
            deferredLegacySelectedSessionID = nil
        }
    }

    private func dropDeferred(inProjectPath path: String) {
        deferredOpenTabs.removeAll { inProject($0.cwd, path) }
        if let deferredSelectedEntry, inProject(deferredSelectedEntry.cwd, path) {
            clearDeferredSelection()
        }
    }

    func pickDirectory(startingAt directory: URL? = nil, prompt: String = "Open Session Here") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory ?? currentDirectory
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static var isSmokeTest: Bool {
        ProcessInfo.processInfo.environment["SIGIL_SMOKE_TEST"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--smoke-test")
    }

    /// Swift Testing does not set XCTestConfigurationFilePath.
    private static var isRunningAutomatedTests: Bool {
        let info = ProcessInfo.processInfo
        return info.environment["XCTestConfigurationFilePath"] != nil
            || info.arguments.contains { $0.contains(".xctest") }
    }

    static func isUsableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    func showError(title: String, message: String) {
        presentError(AppActionError(title: title, message: message))
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum TabMessagingChangeError: Error, LocalizedError, Sendable {
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

private struct AppActionError: Error, LocalizedError {
    let title: String
    let message: String

    var errorDescription: String? { title }
    var recoverySuggestion: String? { message }
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
