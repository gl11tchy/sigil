import AppKit
import Darwin
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct SidebarCommandsTests {
    init() { _ = NSApplication.shared }
    @Test func focusedBulkArchiveUsesOneDirectionAndLeavesOtherChatsAlone() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        for id in ["a", "b", "c", "d"] { try fixture.writeListedSession(id: id, cwd: cwd.path) }
        await fixture.store.reload()
        let model = fixture.model()
        let sessions = fixture.store.sessions.sorted { $0.id < $1.id }
        #expect(sessions.count == 4)
        model.searchText = "Session"
        model.archive(sessions[0])
        let keys = sessions.map(model.sessionKey)
        model.sidebarCommandContext = .init(
            listFocused: true, keyboardRowID: keys[2], selection: Set(keys.prefix(3)), rowIDs: keys)

        model.renamingSessionKey = keys[0]
        #expect(!model.canArchiveCommand)
        #expect(!model.canPinCommand)
        model.performArchiveCommand()
        model.performPinCommand()
        #expect(!model.isArchived(sessions[1]))
        #expect(fixture.settings.pinnedConversations.isEmpty)
        model.renamingSessionKey = nil

        #expect(model.archiveCommandTitle == "Archive 3 Conversations")
        #expect(model.canArchiveCommand)
        model.performArchiveCommand()
        #expect(sessions.prefix(3).allSatisfy(model.isArchived))
        #expect(!model.isArchived(sessions[3]))
        #expect(model.archiveCommandTitle == "Unarchive 3 Conversations")
        model.performArchiveCommand()
        #expect(sessions.allSatisfy { !model.isArchived($0) })
    }

    @Test func mixedPinsPinEveryTargetAndAllPinnedTargetsUnpin() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        for id in ["a", "b"] { try fixture.writeListedSession(id: id, cwd: cwd.path) }
        await fixture.store.reload()
        let model = fixture.model()
        let sessions = fixture.store.sessions
        #expect(sessions.count == 2)
        model.pin(sessions[0])
        let keys = sessions.map(model.sessionKey)
        model.sidebarCommandContext = .init(listFocused: true, selection: Set(keys), rowIDs: keys)

        #expect(model.pinCommandTitle == "Pin 2 Conversations")
        model.performPinCommand()
        #expect(sessions.allSatisfy(model.isPinned))
        #expect(model.pinCommandTitle == "Unpin 2 Conversations")
        model.performPinCommand()
        #expect(sessions.allSatisfy { !model.isPinned($0) })
    }

    @Test(arguments: [false, true])
    func terminalArchiveTargetsTheSelectedTabAndRetainsTheStopPrompt(confirm: Bool) async throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "selected", cwd: cwd.path)
        try fixture.writeListedSession(id: "background", cwd: cwd.path)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(fixture.store.sessions.first { $0.id == "selected" })
        let background = try #require(fixture.store.sessions.first { $0.id == "background" })
        model.open(session)
        let tab = try #require(model.selectedTab)
        tab.noteTurnStarted()
        let backgroundKey = model.sessionKey(background)
        model.sidebarCommandContext = .init(
            listFocused: confirm, keyboardRowID: backgroundKey,
            selection: [backgroundKey], rowIDs: [backgroundKey])
        // Both an unfocused list and a hidden sidebar ignore stale selection.
        model.isSidebarVisible = !confirm
        var prompts: [StopWorkingPrompt] = []
        model.confirmStopWorking = {
            prompts.append($0)
            return confirm
        }

        #expect(model.canArchiveCommand)
        model.performArchiveCommand()
        #expect(prompts.map(\.action) == [.archive])
        #expect(prompts.first?.working == 1)
        #expect(model.isArchived(session) == confirm)
        #expect(!model.isArchived(background))
        #expect(model.tabs.contains { $0.id == tab.id } == !confirm)
    }

    @Test func cancellingBulkStopPreservesTheSelectionAndLiveTab() async throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        for id in ["a", "b"] { try fixture.writeListedSession(id: id, cwd: cwd.path) }
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let sessions = fixture.store.sessions
        model.open(try #require(sessions.first))
        let tab = try #require(model.selectedTab)
        tab.noteTurnStarted()
        let keys = sessions.map(model.sessionKey)
        let context = SidebarCommandContext(
            listFocused: true, keyboardRowID: keys.last, selection: Set(keys), rowIDs: keys)
        model.sidebarCommandContext = context
        var prompts = 0
        model.confirmStopWorking = { _ in
            prompts += 1
            return false
        }

        model.performArchiveCommand()
        #expect(prompts == 1)
        #expect(model.sidebarCommandContext == context)
        #expect(sessions.allSatisfy { !model.isArchived($0) })
        #expect(model.tabs.map(\.id) == [tab.id])
        #expect(tab.controller.isRunning)
    }

    @Test func archivingTheFocusedOpenRowKeepsListFocusUntilExplicitTabSelection() async throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        for id in ["a", "b"] { try fixture.writeListedSession(id: id, cwd: cwd.path) }
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let sessions = fixture.store.sessions.sorted { $0.id < $1.id }
        model.open(try #require(sessions.first))
        let archivedTab = try #require(model.selectedTab)
        model.open(try #require(sessions.last))
        let survivingTab = try #require(model.selectedTab)
        model.select(archivedTab.id)
        await flushFocusRequests()
        let row = SidebarOrganization.openTabRowID(archivedTab.id)
        model.sidebarCommandContext = .init(listFocused: true, keyboardRowID: row, rowIDs: [row])
        model.needsTerminalFocus = false

        archivedTab.noteTurnStarted()
        #expect(archivedTab.activity == .working)
        var prompts: [StopWorkingPrompt] = []
        model.confirmStopWorking = {
            prompts.append($0)
            return true
        }

        model.performArchiveCommand()
        #expect(prompts == [StopWorkingPrompt(action: .archive, working: 1, running: [])])
        // RootView also requests focus after selectedTabID changes.
        model.focusSelectedTerminal()
        await flushFocusRequests()
        #expect(model.isArchived(sessions[0]))
        #expect(model.selectedTabID == survivingTab.id)
        #expect(!model.needsTerminalFocus)

        model.select(survivingTab.id)
        await flushFocusRequests()
        #expect(model.needsTerminalFocus)
    }

    @Test func projectCommandsReusePinArchiveAndEmptyFolderRemoval() async throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "a", cwd: cwd.path)
        // The listed session lives in the fixture's temporary folder.
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first)
        #expect(project.sessions.map(\.id) == ["a"])
        model.sidebarCommandContext = .init(listFocused: true, keyboardRowID: project.id, rowIDs: [project.id])
        #expect(model.pinCommandTitle == "Pin Project")
        model.performPinCommand()
        #expect(model.isPinned(project))
        #expect(model.pinCommandTitle == "Unpin Project")
        #expect(model.archiveCommandTitle == "Archive Project")
        model.performArchiveCommand()
        #expect(project.sessions.allSatisfy(model.isArchived))
        #expect(!model.isPinned(project))

        let empty = try fixture.directory("empty")
        model.addProject(empty)
        let added = try #require(model.sidebarProjects.first { $0.cwd == empty.path })
        model.sidebarCommandContext = .init(listFocused: true, keyboardRowID: added.id, rowIDs: [added.id])
        #expect(model.archiveCommandTitle == "Remove Project")
        model.performArchiveCommand()
        #expect(!fixture.settings.addedProjects.contains { $0.path == empty.path })
    }

    @Test func noIdentityAndRenameDisableCommandsWithoutMutation() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        #expect(!model.canArchiveCommand)
        #expect(!model.canPinCommand)
        let cwd = try fixture.directory("project")
        let previousShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", fixture.executable.path, 1)
        defer {
            if let previousShell { setenv("SHELL", previousShell, 1) } else { unsetenv("SHELL") }
        }
        for provider in [CLIProvider.devin, .cursor, .kimi] {
            let tab = try #require(model.newTab(in: cwd, provider: provider))
            #expect(!model.canArchiveCommand)
            #expect(!model.canPinCommand)
            model.performArchiveCommand()
            model.performPinCommand()
            #expect(model.tabs.map(\.id) == [tab.id])
            model.closeAllTabsAndWait()
        }
        model.renamingSessionKey = "rename"
        #expect(!model.canArchiveCommand)
        #expect(!model.canPinCommand)
        #expect(fixture.settings.archivedConversations.isEmpty)
        #expect(fixture.settings.pinnedConversations.isEmpty)
    }

    @Test func editingAndCompositionKeepTheirInput() throws {
        let editor = NSTextView()
        #expect(!AppModel.canOrganizeConversation(renaming: false, responder: editor, hasSheet: false))
        #expect(!AppModel.canOrganizeConversation(renaming: true, responder: nil, hasSheet: false))
        #expect(!AppModel.canOrganizeConversation(renaming: false, responder: nil, hasSheet: true))
        let terminal = TerminalController(theme: .sigilDark, fontSize: 13).view
        #expect(AppModel.canOrganizeConversation(renaming: false, responder: terminal, hasSheet: false))
        let input = try #require(terminal as? any NSTextInputClient)
        input.setMarkedText(
            "composing", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        #expect(!AppModel.canOrganizeConversation(renaming: false, responder: terminal, hasSheet: false))
    }

    private func flushFocusRequests() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
