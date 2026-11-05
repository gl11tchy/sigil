import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

/// The sidebar and the phone list only chats started in Sigil. Chats that
/// other apps wrote to the same history stay hidden unless turned on.
@MainActor
@Suite(.serialized)
struct SigilOnlyHistoryTests {
    private func session(_ id: String, cwd: String, provider: CLIProvider = .claudeCode) -> GrokSession {
        GrokSession(
            id: id, cwd: cwd, summary: "chat \(id)", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), messageCount: 4, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: URL(fileURLWithPath: cwd), provider: provider,
            hasObservedMessages: true)
    }

    private func model(
        sessions: [GrokSession], defaults: UserDefaults, loadError: String? = nil
    ) async -> (AppModel, AppSettings) {
        _ = NSApplication.shared
        let store = SessionStore(
            root: FileManager.default.temporaryDirectory, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: sessions, cache: [:], loadError: loadError) })
        await store.reload()
        let settings = AppSettings(defaults: defaults)
        settings.showWorktreeSessions = true
        let model = AppModel(
            settings: settings, store: store, presentError: { _ in },
            panel: RightPanel(
                defaults: defaults,
                notesStore: ConversationNotesStore(
                    root: FileManager.default.temporaryDirectory.appendingPathComponent("SigilOnlyNotes-\(UUID())"))),
            pairingStore: InMemoryRemotePairingStore(), providerInstallations: [:])
        return (model, settings)
    }

    @Test func listsOnlyChatsSigilStartedUntilOtherAppsAreTurnedOn() async throws {
        let suite = "SigilOnlyHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mine = session("11111111-1111-4111-8111-111111111111", cwd: "/Users/someone/app")
        let other = session("22222222-2222-4222-8222-222222222222", cwd: "/Users/someone/elsewhere")
        let (model, settings) = await model(sessions: [mine, other], defaults: defaults)
        settings.recordSigilConversations([mine.id])

        #expect(model.sidebarSessions.map(\.id) == [mine.id])
        let reply = await RemoteCommands.execute(.init(challenge: "test", sequence: 1, action: "chats"), model: model)
        #expect(reply.chats?.map(\.id) == [mine.id])
        #expect(AppSettings(defaults: defaults).isSigilConversation(mine.id))

        settings.showOtherAppSessions = true
        #expect(Set(model.sidebarSessions.map(\.id)) == [mine.id, other.id])
    }

    @Test func firstScanAddsSavedTabsAndSigilWorktreeChats() async throws {
        let suite = "SigilOnlyHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = session("33333333-3333-4333-8333-333333333333", cwd: "/Users/someone/app")
        let worktree = session(
            "44444444-4444-4444-8444-444444444444",
            cwd: SigilWorktree.root.appendingPathComponent("%2FUsers%2Fsomeone%2Fapp/abcd1234").path)
        let other = session("55555555-5555-4555-8555-555555555555", cwd: "/Users/someone/app")
        let (model, settings) = await model(sessions: [saved, worktree, other], defaults: defaults)
        settings.openTabs = .init(
            tabs: [.init(sessionID: saved.nativeSessionID, cwd: saved.cwd, provider: .claudeCode)],
            selectedSessionID: nil)

        model.seedSigilConversations()

        #expect(settings.sigilConversationsSeeded)
        #expect(settings.isSigilConversation(saved.id))
        #expect(settings.isSigilConversation(worktree.id))
        #expect(!settings.isSigilConversation(other.id))
    }

    @Test func incompleteHistorySeedsKnownChatsAndRetriesRecoveredWorktreeChats() async throws {
        let suite = "SigilOnlyHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Sigil-REA1264-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // This is only a synthetic cwd string; no folder or history is read under the worktree root.
        let recovered = session(
            "44444444-4444-4444-8444-444444444444",
            cwd: SigilWorktree.root.appendingPathComponent("%2Ftmp%2Fgenerated-project/abcd1234").path)
        let known = session("33333333-3333-4333-8333-333333333333", cwd: "/tmp/generated-project")
        let store = SessionStore(
            root: root, timing: SessionStoreTiming(),
            scanOperation: { _, _, forced in
                .init(
                    sessions: forced.ignoresGrokCache ? [known, recovered] : [known], cache: [:], loadError: nil,
                    coverage: .init(
                        notices: forced.ignoresGrokCache ? [:] : [root.path: "Generated incomplete history"]))
            })
        defer { store.stop() }
        await store.scan(ignoringCache: false)
        let settings = AppSettings(defaults: defaults)
        settings.showWorktreeSessions = true
        settings.openTabs = .init(
            tabs: [.init(sessionID: known.nativeSessionID, cwd: known.cwd, provider: .claudeCode)],
            selectedSessionID: nil)
        let model = AppModel(
            settings: settings, store: store, presentError: { _ in },
            panel: RightPanel(
                defaults: defaults, notesStore: ConversationNotesStore(root: root.appendingPathComponent("notes"))),
            pairingStore: InMemoryRemotePairingStore(), providerInstallations: [:])
        defer { model.closeAllTabsAndWait() }
        model.seedSigilConversations()
        #expect(settings.isSigilConversation(known.id))
        #expect(!settings.sigilConversationsSeeded)
        await store.reload()
        model.seedSigilConversations()
        #expect(settings.sigilConversationsSeeded)
        #expect(settings.isSigilConversation(recovered.id))
        #expect(model.sidebarSessions.contains { $0.id == recovered.id })
    }

    @Test func twoCopiesRecordingChatsKeepBoth() throws {
        let suite = "SigilOnlyHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults)
        let second = AppSettings(defaults: defaults)

        first.recordSigilConversations(["a"])
        second.recordSigilConversations(["b"])

        #expect(AppSettings(defaults: defaults).isSigilConversation("a"))
        #expect(AppSettings(defaults: defaults).isSigilConversation("b"))
    }

    @Test func seedingWaitsForAScanWithoutErrors() async throws {
        let suite = "SigilOnlyHistoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = NSApplication.shared
        let store = SessionStore(
            root: FileManager.default.temporaryDirectory, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: [], cache: [:], loadError: "History is unavailable.") })
        await store.reload()
        let settings = AppSettings(defaults: defaults)
        let model = AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore())

        model.seedSigilConversations()

        #expect(!settings.sigilConversationsSeeded)
    }

    @Test(arguments: ["pin", "archive", "name", "color"])
    func legacyOwnershipSurvivesAnAlreadyCompletedOriginalSeed(_ category: String) async throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "session.sigilConversationsSeeded")
        let owned = session("legacy-\(category)", cwd: "/tmp/generated-rea1229")
        let outside = session("outside", cwd: owned.cwd, provider: .codex)
        switch category {
        case "pin", "archive":
            defaults.set(
                try JSONEncoder().encode([OpenTabsSnapshot.Entry(sessionID: owned.id, cwd: owned.cwd)]),
                forKey: category == "pin" ? "sidebar.pinnedConversations" : "sidebar.archivedConversations")
        case "name":
            defaults.set(
                try JSONEncoder().encode([ConversationName(sessionID: owned.id, cwd: owned.cwd, name: "My chat")]),
                forKey: "sidebar.conversationNames")
        default:
            defaults.set(
                try JSONEncoder().encode([TabColorRecord(sessionID: owned.id, cwd: owned.cwd, color: .violet)]),
                forKey: "tabs.colors")
        }
        let (model, settings) = await model(sessions: [owned, outside], defaults: defaults)
        defer { model.closeAllTabsAndWait() }

        model.seedSigilConversations()

        #expect(settings.isSigilConversation(owned.id))
        #expect(AppSettings(defaults: defaults).isSigilConversation(owned.id))
        #expect(defaults.bool(forKey: "session.sigilConversationsSeeded2"))
        #expect(!settings.isSigilConversation(outside.id))
        if category == "archive" {
            #expect(model.archivedCount == 1)
            settings.focusedProjectPath = SidebarOrganization.archivedID
        }
        #expect(model.sidebarSessions.map(\.id) == [owned.id])
        if category == "pin" { #expect(model.pinnedSessions().map(\.id) == [owned.id]) }
    }

    @Test(arguments: ["pin", "archive", "name", "color"])
    func futureOwnershipSurvivesTurningOtherAppsOff(_ category: String) async throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "session.sigilConversationsSeeded")
        defaults.set(true, forKey: "session.sigilConversationsSeeded2")
        let owned = session("future-\(category)", cwd: "/tmp/generated-rea1229")
        let outside = session("outside", cwd: owned.cwd, provider: .codex)
        let (model, settings) = await model(sessions: [owned, outside], defaults: defaults)
        defer { model.closeAllTabsAndWait() }
        settings.showOtherAppSessions = true
        switch category {
        case "pin": model.pin(owned)
        case "archive": model.archive(owned)
        case "name": model.rename(owned, to: "My chat")
        default:
            let tab = TerminalTab(
                spec: .init(
                    workingDirectory: URL(fileURLWithPath: owned.cwd),
                    mode: .resume(sessionID: owned.nativeSessionID), provider: owned.provider),
                settings: settings)
            model.setTabColor(tab, to: .violet)
        }
        settings.showOtherAppSessions = false

        #expect(settings.isSigilConversation(owned.id))
        #expect(AppSettings(defaults: defaults).isSigilConversation(owned.id))
        #expect(!settings.isSigilConversation(outside.id))
        if category == "archive" {
            #expect(model.archivedCount == 1)
            settings.focusedProjectPath = SidebarOrganization.archivedID
        }
        #expect(model.sidebarSessions.map(\.id) == [owned.id])
    }

    @Test func ownershipUnionsAllFourCategoriesWithoutReadableHistory() async throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "session.sigilConversationsSeeded")
        let cwd = "/tmp/generated-rea1229/missing-folder"
        let pins = [OpenTabsSnapshot.Entry(sessionID: "same", cwd: cwd)]
        let archives = [OpenTabsSnapshot.Entry(sessionID: "claudeCode:same", cwd: cwd)]
        let names = [ConversationName(sessionID: "codex:same", cwd: cwd, name: "My chat")]
        defaults.set(try JSONEncoder().encode(pins), forKey: "sidebar.pinnedConversations")
        defaults.set(try JSONEncoder().encode(archives), forKey: "sidebar.archivedConversations")
        defaults.set(try JSONEncoder().encode(names), forKey: "sidebar.conversationNames")
        let colors = try JSONSerialization.data(withJSONObject: [
            ["sessionID": "futureProvider:same", "cwd": cwd, "color": "future-color"]
        ])
        defaults.set(colors, forKey: "tabs.colors")
        defaults.set(
            try JSONEncoder().encode(["codex:unreadable", "opaque-legacy"]), forKey: "session.sigilConversations")
        let (model, settings) = await model(sessions: [], defaults: defaults, loadError: "Generated unreadable history")
        defer { model.closeAllTabsAndWait() }

        model.seedSigilConversations()

        let expected: Set<String> = [
            "same", "claudeCode:same", "codex:same", "futureProvider:same", "codex:unreadable", "opaque-legacy",
        ]
        #expect(Set(settings.sigilConversations) == expected)
        #expect(settings.sigilConversationsSeeded2)
        #expect(Set(AppSettings(defaults: defaults).sigilConversations) == expected)
        #expect(defaults.data(forKey: "tabs.colors") == colors)
        #expect(!settings.isSigilConversation("claudeCode:claudeCode:same"))
    }

    @Test(arguments: ["beforeWrite", "afterWrite", "acknowledgementOnly", "completion"])
    func failedPersistenceRetriesBeforeCompletingOwnershipMigration(_ failure: String) throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pins = [OpenTabsSnapshot.Entry(sessionID: "claudeCode:owned", cwd: "/tmp/generated-rea1229")]
        defaults.set(try JSONEncoder().encode(pins), forKey: "sidebar.pinnedConversations")
        let previous = try JSONEncoder().encode(["futureProvider:retained"])
        defaults.set(previous, forKey: "session.sigilConversations")
        var fail = true
        let settings = AppSettings(
            defaults: defaults,
            persistSigilOwnership: { defaults, values in
                let isList = values["session.sigilConversations"] != nil
                if fail, isList, failure == "beforeWrite" { return false }
                if fail, isList, failure == "acknowledgementOnly" { return true }
                for (key, value) in values { defaults.set(value, forKey: key) }
                if fail,
                    (isList && failure == "afterWrite")
                        || (values["session.sigilConversationsSeeded2"] != nil && failure == "completion")
                {
                    return false
                }
                return defaults.synchronize()
            })

        #expect(!settings.sigilConversationsSeeded2)
        #expect(!defaults.bool(forKey: "session.sigilConversationsSeeded2"))
        if failure == "beforeWrite" || failure == "acknowledgementOnly" {
            #expect(defaults.data(forKey: "session.sigilConversations") == previous)
        }
        fail = false
        #expect(settings.seedSigilConversationOwnership())
        #expect(settings.sigilConversationsSeeded2)
        #expect(defaults.bool(forKey: "session.sigilConversationsSeeded2"))
        #expect(
            Set(AppSettings(defaults: defaults).sigilConversations) == ["futureProvider:retained", "claudeCode:owned"])
    }

    @Test func ownershipMigrationIsIdempotentAcrossRelaunch() throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            try JSONEncoder().encode([ConversationName(sessionID: "codex:owned", cwd: "/tmp/generated", name: "Mine")]),
            forKey: "sidebar.conversationNames")
        var writes = 0
        let persist: (UserDefaults, [String: Any]) -> Bool = { defaults, values in
            writes += 1
            for (key, value) in values { defaults.set(value, forKey: key) }
            return defaults.synchronize()
        }
        let first = AppSettings(defaults: defaults, persistSigilOwnership: persist)
        let committedWrites = writes
        #expect(committedWrites > 0)
        #expect(first.seedSigilConversationOwnership())
        let relaunched = AppSettings(defaults: defaults, persistSigilOwnership: persist)
        #expect(relaunched.seedSigilConversationOwnership())
        #expect(relaunched.sigilConversations == ["codex:owned"])
        #expect(writes == committedWrites)
    }

    @Test func overlappingCopiesCannotLoseAnIdentityThroughTheCompatibilityList() throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var interleave = false
        var another: AppSettings?
        let first = AppSettings(
            defaults: defaults,
            persistSigilOwnership: { defaults, values in
                // The first copy already prepared its list. Let the second commit
                // before the first overwrites that list, reproducing a lost update.
                if interleave, values["session.sigilConversations"] != nil {
                    interleave = false
                    #expect(another?.recordSigilConversations(["codex:same"]) == true)
                }
                for (key, value) in values { defaults.set(value, forKey: key) }
                return defaults.synchronize()
            })
        another = AppSettings(defaults: defaults)
        #expect(first.recordSigilConversations(["retained"]))
        interleave = true
        #expect(first.recordSigilConversations(["claudeCode:same"]))
        let relaunched = AppSettings(defaults: defaults)
        #expect(Set(relaunched.sigilConversations) == ["retained", "claudeCode:same", "codex:same"])
        first.reloadSharedLists()
        another?.reloadSharedLists()
        #expect(Set(first.sigilConversations) == Set(relaunched.sigilConversations))
        #expect(Set(another?.sigilConversations ?? []) == Set(relaunched.sigilConversations))
    }

    @Test func completedMigrationStillRecoversAnotherCopiesOwnershipAndFailedActions() async throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, settings) = await model(sessions: [], defaults: defaults)
        defer { model.closeAllTabsAndWait() }
        #expect(settings.sigilConversationsSeeded2)
        let other = AppSettings(defaults: defaults)
        other.conversationNames = [.init(sessionID: "codex:other-copy", cwd: "/tmp/generated", name: "Mine")]
        settings.reloadSharedLists()
        #expect(settings.isSigilConversation("codex:other-copy"))

        var fail = false
        let failing = AppSettings(
            defaults: defaults,
            persistSigilOwnership: { defaults, values in
                guard !fail else { return false }
                for (key, value) in values { defaults.set(value, forKey: key) }
                return defaults.synchronize()
            })
        fail = true
        failing.pinnedConversations = [.init(sessionID: "claudeCode:retry", cwd: "/tmp/generated")]
        #expect(!failing.recordSigilConversations(["claudeCode:retry"]))
        #expect(failing.sigilConversationsSeeded2)
        // A new copy can recover the persisted ownership metadata even though
        // the initial migration marker was already complete before this failure.
        #expect(AppSettings(defaults: defaults).isSigilConversation("claudeCode:retry"))
        fail = false
        failing.reloadSharedLists()
        #expect(Set(failing.sigilConversations) == ["codex:other-copy", "claudeCode:retry"])
    }

    @Test func malformedOwnershipLedgerIsPreservedUntilAReadableRetry() throws {
        let suite = "SigilOnlyHistoryTests.REA1229.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prior = AppSettings(defaults: defaults)
        #expect(prior.recordSigilConversations(["claudeCode:recorded"]))
        defaults.set(false, forKey: "session.sigilConversationsSeeded2")
        let malformed = Data("not readable JSON".utf8)
        defaults.set(malformed, forKey: "session.sigilConversations")
        defaults.set(
            try JSONEncoder().encode([ConversationName(sessionID: "codex:owned", cwd: "/tmp/generated", name: "Mine")]),
            forKey: "sidebar.conversationNames")
        let settings = AppSettings(defaults: defaults)
        settings.reloadSharedLists()
        #expect(defaults.data(forKey: "session.sigilConversations") == malformed)
        #expect(!settings.sigilConversationsSeeded2)
        #expect(settings.isSigilConversation("claudeCode:recorded"))
        defaults.set(try JSONEncoder().encode(["futureProvider:unreadable"]), forKey: "session.sigilConversations")
        #expect(settings.seedSigilConversationOwnership())
        #expect(
            Set(settings.sigilConversations) == ["claudeCode:recorded", "codex:owned", "futureProvider:unreadable"])
    }

    @Test(arguments: [CLIProvider.grokBuild, .claudeCode, .codex])
    func tabOnlyRenameAndColorUseTheirProviderIdentity(_ provider: CLIProvider) throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(
            spec: .init(
                executable: fixture.executable, workingDirectory: folder, mode: .resume(sessionID: "same"),
                provider: provider),
            settings: fixture.settings)
        let id = try #require(tab.sessionID)
        model.renameTab(tab, to: tab.automaticTitle)
        model.setTabColor(tab, to: nil)
        #expect(!fixture.settings.isSigilConversation(id))
        model.renameTab(tab, to: "My task")
        #expect(fixture.settings.isSigilConversation(id))
        let colored = TerminalTab(
            spec: .init(
                executable: fixture.executable, workingDirectory: folder, mode: .resume(sessionID: "colored"),
                provider: provider),
            settings: fixture.settings)
        let coloredID = try #require(colored.sessionID)
        model.setTabColor(colored, to: .mint)
        #expect(fixture.settings.isSigilConversation(coloredID))
        model.resetTabName(tab)
        model.setTabColor(colored, to: nil)
        #expect(Set(AppSettings(defaults: fixture.defaults).sigilConversations) == [id, coloredID])
    }

    @Test func pendingNativeIdentityDoesNotBecomeAnOwnedConversation() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(
            spec: .init(
                executable: fixture.executable, workingDirectory: folder, mode: .new(sessionID: UUID()),
                provider: .codex),
            settings: fixture.settings)
        model.renameTab(tab, to: "My task")
        model.setTabColor(tab, to: .mint)
        #expect(tab.sessionID == nil)
        #expect(fixture.settings.sigilConversations.isEmpty)
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(fixture.settings.tabColors.isEmpty)
    }

    @Test func merelyOpeningAnOutsideChatDoesNotAddOwnership() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        try fixture.writeListedSession(id: "outside", cwd: folder.path)
        await fixture.store.reload()
        fixture.settings.sigilConversationsSeeded = true
        fixture.settings.showOtherAppSessions = false
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let outside = try #require(fixture.store.sessions.first)
        model.panel.notesStore.setNote("Generated note only", for: outside.id, cwd: outside.cwd)
        model.panel.notesStore.flushNow()
        #expect(model.panel.notesStore.isSaved(for: outside.id, cwd: outside.cwd))
        #expect(
            ConversationNotesStore(root: fixture.notesRoot).note(for: outside.id, cwd: outside.cwd)
                == "Generated note only")
        model.seedSigilConversations()
        #expect(!fixture.settings.isSigilConversation(outside.id))
        model.open(outside)
        #expect(model.tabs.count == 1)
        #expect(!fixture.settings.isSigilConversation(outside.id))
        #expect(!AppSettings(defaults: fixture.defaults).isSigilConversation(outside.id))
        model.closeAllTabsAndWait()
        model.seedSigilConversations()
        #expect(model.sidebarSessions.isEmpty)
        #expect(!fixture.settings.isSigilConversation(outside.id))
    }
}
