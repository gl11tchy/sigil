import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

/// The sidebar and the phone list only chats started in Sigil. Chats that
/// other apps wrote to the same history stay hidden unless turned on.
@MainActor
struct SigilOnlyHistoryTests {
    private func session(_ id: String, cwd: String, provider: CLIProvider = .claudeCode) -> GrokSession {
        GrokSession(
            id: id, cwd: cwd, summary: "chat \(id)", createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2), messageCount: 4, modelID: nil, agentName: nil,
            reasoningEffort: nil, directory: URL(fileURLWithPath: cwd), provider: provider,
            hasObservedMessages: true)
    }

    private func model(sessions: [GrokSession], defaults: UserDefaults) async -> (AppModel, AppSettings) {
        _ = NSApplication.shared
        let store = SessionStore(
            root: FileManager.default.temporaryDirectory, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in .init(sessions: sessions, cache: [:], loadError: nil) })
        await store.reload()
        let settings = AppSettings(defaults: defaults)
        settings.showWorktreeSessions = true
        let model = AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore())
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
        let (model, settings) = await model(sessions: [owned, outside], defaults: defaults)
        defer { model.closeAllTabsAndWait() }
        switch category {
        case "pin": settings.pinnedConversations = [.init(sessionID: owned.id, cwd: owned.cwd)]
        case "archive": settings.archivedConversations = [.init(sessionID: owned.id, cwd: owned.cwd)]
        case "name": settings.conversationNames = [.init(sessionID: owned.id, cwd: owned.cwd, name: "My chat")]
        default: settings.tabColors = [.init(sessionID: owned.id, cwd: owned.cwd, color: .violet)]
        }

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
}
