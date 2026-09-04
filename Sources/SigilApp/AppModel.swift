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
    /// The right-hand utility column: scratch shell, dev-server browser, notes.
    let panel = RightPanel()

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
    var isSidebarVisible = true {
        didSet {
            if Self.shouldClearRenameSelectAllOnSidebarHide(
                wasVisible: oldValue, isVisible: isSidebarVisible
            ) {
                renameSelectAllPending = false
            }
        }
    }
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
    @ObservationIgnored private let registrationRunner: BridgeRegistration.Runner
    @ObservationIgnored private let mcpBinaryOverride: URL?
    @ObservationIgnored private let tabMessagingSocketURL: URL
    @ObservationIgnored private let resolveCanonicalPath: @Sendable (String) -> String
    @ObservationIgnored private var canonicalPathCache: [String: String] = [:]
    @ObservationIgnored private var canonicalCacheTabCount = -1
    @ObservationIgnored private var canonicalCacheSessionCount = -1
    @ObservationIgnored private var canonicalCacheSessionStamp: Date?

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
        canonicalPath: (@Sendable (String) -> String)? = nil
    ) {
        self.settings = settings
        self.store = store
        self.trashConversation = trashConversation
        self.presentError = presentError
        self.registrationRunner = registrationRunner ?? BridgeRegistration.processRunner
        self.mcpBinaryOverride = mcpBinary
        self.tabMessagingSocketURL = tabMessagingSocketURL ?? BridgePaths.configuredSocket
        self.resolveCanonicalPath = canonicalPath ?? { GrokPaths.canonicalPath($0) }
    }

    func onAppear() async {
        guard !didAppear else { return }
        didAppear = true
        if Self.isSmokeTest { return }
        store.start()
        // Bind the local socket before restoring tabs so they inherit it.
        // Registration is add-or-update and can take seconds; do not wait on it.
        if settings.isTabMessagingEnabled {
            try? startTabMessaging()
        }
        applyAppearance()
        restoreOpenTabs()
        preparePanel()
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

    /// Restrict the sidebar to conversations started in the current tab's folder.
    var scopeToCurrentFolder = false
    /// Recents and Projects hide archived chats; this shows only those.
    var showingArchived = false
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
    /// Session key of the inline field currently in the tree. Nil if unmounted.
    var renameFieldMountedKey: String?
    /// Bumped on every mount/unmount so a stale blur task cannot commit after remount.
    var renameFieldMountGeneration = 0
    /// Select-all only for a fresh beginRename (F2, ⌘⇧R, row menu). Restore must not.
    var renameSelectAllPending = false

    /// Conversations for the sidebar: newest first, one-shot noise filtered out,
    /// optionally scoped to the folder the current tab is working in. Archived
    /// chats are hidden unless `showingArchived` is on.
    var sidebarSessions: [GrokSession] {
        var result = store.search(searchText) { title(for: $0) }
        if !settings.showEmptySessions {
            // A session you have open is always worth listing, even before the CLI
            // has written a summary for it. Otherwise the row marking the
            // conversation on screen is the one row the list refuses to show.
            result = result.filter { isReal($0) || isOpen($0) }
        }
        if !settings.showWorktreeSessions {
            result = result.filter { !isEphemeral(path: $0.cwd) || isOpen($0) }
        }
        if !settings.showSubagentSessions {
            result = result.filter { !$0.isSubagent || isOpen($0) }
        }
        if scopeToCurrentFolder {
            let folder = currentDirectory.resolvingSymlinksInPath().path
            result = result.filter { samePath($0.cwd, folder) }
        }
        if showingArchived {
            result = result.filter { isArchived($0) }
        } else {
            result = result.filter { !isArchived($0) }
        }
        return result
    }

    /// A session worth listing: it has a summary, a name the user chose, or more
    /// than the opening exchange.
    private func isReal(_ session: GrokSession) -> Bool {
        !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || session.messageCount > 2
            || hasCustomName(session)
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

    func isCurrentFolder(_ cwd: String) -> Bool {
        samePath(cwd, currentDirectory.path)
    }

    func activity(of session: GrokSession) -> TerminalTab.Activity? {
        tabs.first { tabMatches($0, sessionID: session.id, cwd: session.cwd) }?.activity
    }

    func isWorking(_ session: GrokSession) -> Bool {
        activity(of: session) == .working
    }

    func isWorking(_ project: SidebarProject) -> Bool {
        project.sessions.contains { isWorking($0) }
    }

    func isPinned(_ session: GrokSession) -> Bool {
        SidebarOrganization.contains(
            settings.pinnedConversations, session: session, samePath: samePath)
    }

    func pin(_ session: GrokSession) {
        unarchive(session)
        settings.pinnedConversations = SidebarOrganization.inserting(
            session, onto: settings.pinnedConversations, samePath: samePath)
    }

    func unpin(_ session: GrokSession) {
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
        settings.pinnedProjects = SidebarOrganization.inserting(
            project.cwd, onto: settings.pinnedProjects, samePath: samePath)
    }

    func unpin(_ project: SidebarProject) {
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

    func archive(_ session: GrokSession) {
        unpin(session)
        settings.archivedConversations = SidebarOrganization.inserting(
            session, onto: settings.archivedConversations, samePath: samePath)
    }

    func unarchive(_ session: GrokSession) {
        settings.archivedConversations = SidebarOrganization.removing(
            session, from: settings.archivedConversations, samePath: samePath)
    }

    func toggleArchive(_ session: GrokSession) {
        if isArchived(session) { unarchive(session) } else { archive(session) }
    }

    /// Archived conversations still on disk, in archive order.
    var archivedCount: Int {
        store.sessions.filter { isArchived($0) }.count
    }

    /// Pinned conversations still in the current sidebar filter, in pin order.
    func pinnedSessions(in project: SidebarProject? = nil) -> [GrokSession] {
        let pinned = SidebarOrganization.matching(
            sessions: sidebarSessions,
            entries: settings.pinnedConversations,
            samePath: samePath
        )
        guard let project else { return pinned }
        return pinned.filter { session in
            project.sessions.contains {
                $0.id == session.id && samePath($0.cwd, session.cwd)
            }
        }
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
        SidebarOrganization.projects(from: sidebarSessions, canonicalPath: canonicalPath)
    }

    var focusedProject: SidebarProject? {
        let path = settings.focusedProjectPath
        guard !path.isEmpty else { return nil }
        let focused = canonicalPath(path)
        return sidebarProjects.first { $0.id == focused || samePath($0.cwd, path) }
    }

    func openProject(_ project: SidebarProject) {
        settings.sidebarMode = .projects
        settings.focusedProjectPath = project.cwd
    }

    func leaveProject() {
        settings.focusedProjectPath = ""
    }

    /// Drops pins, archives, and names whose conversations are gone, after a successful scan.
    func pruneMissingPins() {
        guard !store.isLoading, store.loadError == nil else { return }
        let remainingPins = pruningMissing(settings.pinnedConversations)
        if remainingPins != settings.pinnedConversations {
            settings.pinnedConversations = remainingPins
        }
        let remainingProjectPins = pruningMissingProjects(settings.pinnedProjects)
        if remainingProjectPins != settings.pinnedProjects {
            settings.pinnedProjects = remainingProjectPins
        }
        let remainingArchives = pruningMissing(settings.archivedConversations)
        if remainingArchives != settings.archivedConversations {
            settings.archivedConversations = remainingArchives
        }
        let remainingNames = pruningMissingNames(settings.conversationNames)
        if remainingNames != settings.conversationNames {
            settings.conversationNames = remainingNames
        }
        if !settings.focusedProjectPath.isEmpty, focusedProject == nil {
            settings.focusedProjectPath = ""
        }
    }

    private func pruningMissing(_ entries: [OpenTabsSnapshot.Entry]) -> [OpenTabsSnapshot.Entry] {
        entries.filter { entry in
            store.sessions.contains { $0.id == entry.sessionID && samePath($0.cwd, entry.cwd) }
                || tabs.contains { tabMatches($0, sessionID: entry.sessionID, cwd: entry.cwd) }
        }
    }

    private func pruningMissingProjects(_ paths: [String]) -> [String] {
        paths.filter { path in
            store.sessions.contains { samePath($0.cwd, path) }
                || tabs.contains { samePath($0.workingDirectory.path, path) }
        }
    }

    private func pruningMissingNames(_ names: [ConversationName]) -> [ConversationName] {
        names.filter { record in
            store.sessions.contains { $0.id == record.sessionID && samePath($0.cwd, record.cwd) }
                || tabs.contains { tabMatches($0, sessionID: record.sessionID, cwd: record.cwd) }
        }
    }

    /// The deleted conversation still sits in `store` until the next scan.
    private func dropOrphanedProjectPin(for session: GrokSession) {
        let othersRemain =
            store.sessions.contains { $0.id != session.id && samePath($0.cwd, session.cwd) }
            || tabs.contains { samePath($0.workingDirectory.path, session.cwd) }
        if !othersRemain {
            settings.pinnedProjects = SidebarOrganization.removing(
                session.cwd, from: settings.pinnedProjects, samePath: samePath)
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

    func hasCustomName(_ session: GrokSession) -> Bool {
        customName(for: session) != nil
    }

    /// Empty, whitespace, or a name equal to the CLI title clears the override
    /// (a matching submit with no overlay is a no-op). Otherwise stores the name.
    func rename(_ session: GrokSession, to raw: String) {
        let next = ConversationNaming.setting(
            raw, on: session, onto: settings.conversationNames, samePath: samePath)
        guard Self.shouldPersistConversationNames(
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

    func resetName(_ session: GrokSession) {
        let live = freshSession(matching: session)
        if renamingSessionKey == sessionKey(live) {
            endRenameSession()
        }
        let next = ConversationNaming.removing(
            live, from: settings.conversationNames, samePath: samePath)
        guard Self.shouldPersistConversationNames(
            next: next, current: settings.conversationNames)
        else { return }
        settings.conversationNames = next
        applyNameToOpenTabs(live)
    }

    /// Single draft owner for a fresh key. prepareRename only hands off the
    /// surface — it must not rewrite `renameDraft`, or typing that lands
    /// before that task runs is clobbered.
    func beginRename(_ session: GrokSession) {
        isSidebarVisible = true
        let key = sessionKey(session)
        let isFreshKey = renamingSessionKey != key
        renameAlertDismissGeneration += 1
        if isFreshKey {
            renameAlertDidCommit = true
            renameDraft = title(for: session)
            showRenameAlert = false
            renameAlertSession = nil
            renameAlertIsPulsing = false
            renameAlertDidCommit = false
        }
        renameSelectAllPending = Self.shouldArmRenameSelectAllOnBegin(isFreshKey: isFreshKey)
        renamingSessionKey = key
    }

    func cancelRename() {
        endRenameSession()
    }

    func commitRename(_ session: GrokSession, to raw: String) {
        rename(session, to: raw)
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
        renameSelectAllPending = false
    }

    /// Snapshot the live draft before `endRenameSession` can wipe it. The
    /// alert's isPresented setter may cancel before this button action runs.
    /// Compare against the store's current session so a CLI summary rewrite
    /// while the alert is up cannot pin a stale title.
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

    /// Dismiss may fire before the Rename button. Wait a turn, then cancel
    /// only if this is still an uncommitted, visible-sidebar rename whose
    /// dismiss generation has not been poisoned by a newer beginRename.
    func deferCancelRenameAlert() async {
        let generation = renameAlertDismissGeneration
        await Task.yield()
        guard
            Self.shouldCancelRenameAlertAfterYield(
                isCancelled: Task.isCancelled,
                sidebarVisible: isSidebarVisible,
                didCommit: renameAlertDidCommit,
                stillRenaming: renamingSessionKey != nil,
                expectedGeneration: generation,
                currentGeneration: renameAlertDismissGeneration
            )
        else { return }
        cancelRename()
    }

    func noteRenameFieldMounted(_ mounted: Bool, key: String) {
        if mounted {
            guard Self.shouldApplyRenameFieldMount(
                mountKey: key,
                activeKey: renamingSessionKey,
                mountedKey: renameFieldMountedKey
            ) else { return }
            renameFieldMountedKey = key
            renameFieldMountGeneration += 1
        } else {
            guard Self.shouldApplyRenameFieldUnmount(
                unmountKey: key,
                activeKey: renamingSessionKey,
                mountedKey: renameFieldMountedKey
            ) else { return }
            renameFieldMountedKey = nil
            renameFieldMountGeneration += 1
        }
    }

    func consumeRenameSelectAll() -> Bool {
        let pending = renameSelectAllPending
        renameSelectAllPending = false
        return pending
    }

    func clearRenameSelectAllPending() {
        renameSelectAllPending = false
    }

    /// Inline editor only. No-ops if this row is no longer the active rename
    /// (Reset Name, cancel, or another row started). Compare against the live
    /// store session so a CLI summary rewrite cannot pin a stale title.
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

    /// Same-key F2/⌘⇧R must not re-arm select-all; a late select would wipe typing.
    static func shouldArmRenameSelectAllOnBegin(isFreshKey: Bool) -> Bool {
        isFreshKey
    }

    /// Focus steal may suppress blur-commit; the select-all wait must not.
    static func shouldSuppressBlurCommitDuringRenameSelectAllWait() -> Bool {
        false
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

    /// The conversation on screen, when the store knows it. Menu-bar Rename uses this.
    func sessionForSelectedTab() -> GrokSession? {
        guard let tab = selectedTab, let id = tab.sessionID else { return nil }
        return store.sessions.first {
            $0.id == id && samePath($0.cwd, tab.workingDirectory.path)
        }
    }

    /// A tab's label. New sessions start out named after their folder; once the CLI
    /// writes a summary for them, the store supplies the conversation name. A
    /// user-chosen name wins even when the CLI has not written a summary yet.
    func title(for tab: TerminalTab) -> String {
        if let id = tab.sessionID,
            let session = store.sessions.first(where: {
                $0.id == id && samePath($0.cwd, tab.workingDirectory.path)
            })
        {
            if hasCustomName(session) { return title(for: session) }
            if !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return session.title
            }
        }
        return tab.title
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
            reasoningEffort: (effort ?? settings.effort).nilIfEmpty,
            themeName: settings.theme.grokThemeName
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
            reasoningEffort: settings.effort.nilIfEmpty,
            themeName: settings.theme.grokThemeName
        )
        let tab = add(spec)
        tab.sessionTitle = title(for: session)
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
        panel.closeShellAndWait()
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
        try await Task.detached(priority: .userInitiated) {
            let registration = BridgeRegistration(executable: executable, runner: runner)
            try registration.install(mcpBinary: helper)
        }.value
    }

    private func removeTabMessagingRegistration() async throws {
        let executable = settings.executableURL
        let runner = registrationRunner
        try await Task.detached(priority: .userInitiated) {
            let registration = BridgeRegistration(executable: executable, runner: runner)
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
        guard let app = NSApp else { return }
        app.dockTile.badgeLabel = tabs.contains(where: \.hasUnseenActivity) ? "•" : nil
        app.dockTile.display()
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

    // MARK: - Right panel

    /// Shows `mode` in the panel, or hides the panel when that tool is already up.
    func showPanel(_ mode: RightPanelMode) {
        panel.toggle(mode, in: currentDirectory)
        preparePanel()
    }

    /// Opens or closes the panel on whatever tool it last showed.
    func togglePanel() {
        panel.toggle(nil, in: currentDirectory)
        preparePanel()
    }

    /// Kills the scratch shell and starts a new one in the current folder.
    func restartPanelShell() {
        panel.restartShell(
            in: currentDirectory, theme: settings.theme, fontSize: settings.fontSize)
    }

    /// Starts whatever the visible tool needs, with the app's own theme and size.
    private func preparePanel() {
        guard panel.isVisible else { return }
        if panel.mode == .shell {
            panel.startShellIfNeeded(
                in: currentDirectory, theme: settings.theme, fontSize: settings.fontSize)
        } else {
            panel.prepare(in: currentDirectory)
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
            Task { await store.reload() }
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

    /// Writes `grok export <id>` to a file the user picks.
    ///
    /// The save panel stays on the main thread; the CLI itself runs off it so a
    /// long export cannot freeze the window.
    func exportTranscript(_ session: GrokSession) {
        exportTranscript(
            sessionID: session.id,
            title: title(for: session),
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
                reasoningEffort: settings.effort.nilIfEmpty,
                themeName: settings.theme.grokThemeName
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
        }
    }

    private func persistOpenTabs() {
        guard !isRestoringTabs else { return }
        var entries = tabs.compactMap { tab -> OpenTabsSnapshot.Entry? in
            guard let sessionID = tab.sessionID else { return nil }
            return OpenTabsSnapshot.Entry(sessionID: sessionID, cwd: tab.workingDirectory.path)
        }
        let liveKeys = Set(entries.map { entryKey($0) })
        entries.append(
            contentsOf: deferredOpenTabs.filter {
                !liveKeys.contains(entryKey($0))
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
        tab.sessionID == sessionID && samePath(tab.workingDirectory.path, cwd)
    }

    private func entryMatches(
        _ entry: OpenTabsSnapshot.Entry, sessionID: String, cwd: String
    ) -> Bool {
        entry.sessionID == sessionID && samePath(entry.cwd, cwd)
    }

    private func sameEntry(
        _ lhs: OpenTabsSnapshot.Entry, _ rhs: OpenTabsSnapshot.Entry
    ) -> Bool {
        entryMatches(lhs, sessionID: rhs.sessionID, cwd: rhs.cwd)
    }

    private func entryKey(_ entry: OpenTabsSnapshot.Entry) -> String {
        entry.sessionID + "\u{0}" + canonicalPath(entry.cwd)
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    private func canonicalPath(_ path: String) -> String {
        let tabCount = tabs.count
        let sessionCount = store.sessions.count
        let stamp = store.sessions.first?.updatedAt
        if tabCount != canonicalCacheTabCount
            || sessionCount != canonicalCacheSessionCount
            || stamp != canonicalCacheSessionStamp
        {
            canonicalPathCache.removeAll(keepingCapacity: true)
            canonicalCacheTabCount = tabCount
            canonicalCacheSessionCount = sessionCount
            canonicalCacheSessionStamp = stamp
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
