import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct TabRenameTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func renamingAConversationFromTheTabUsesTheSidebarName() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: folder.path, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        let tab = TerminalTab(spec: spec(folder: folder, sessionID: "s1"), settings: fixture.settings)

        model.renameTab(tab, to: "Auth rewrite")
        #expect(model.title(for: session) == "Auth rewrite")
        #expect(model.title(for: tab) == "Auth rewrite")
        #expect(model.hasCustomTabName(tab))

        model.renameTab(tab, to: "CLI summary")
        #expect(!model.hasCustomName(session))
        #expect(model.title(for: tab) == "CLI summary")
        #expect(!model.hasCustomTabName(tab))

        model.renameTab(tab, to: "Auth rewrite")
        model.renameTab(tab, to: "  \n")
        #expect(model.title(for: session) == "CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)
    }

    @Test func aTabCanBeNamedBeforeTheStoreListsIt() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(spec: spec(folder: folder, sessionID: "s1"), settings: fixture.settings)

        #expect(model.title(for: tab) == "project")
        model.renameTab(tab, to: "Ship it")
        #expect(model.title(for: tab) == "Ship it")
        #expect(fixture.settings.conversationNames.count == 1)

        model.renameTab(tab, to: "project")
        #expect(model.title(for: tab) == "project")
        #expect(fixture.settings.conversationNames.isEmpty)
    }

    @Test func anotherAgentKeepsANameOnlyOnThatTab() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(
            spec: GrokLaunchSpec(
                workingDirectory: folder, mode: .new(sessionID: UUID()), provider: .cursor),
            settings: fixture.settings)

        #expect(model.title(for: tab) == "Cursor · project")
        model.renameTab(tab, to: "Auth")
        #expect(model.title(for: tab) == "Auth")
        #expect(model.hasCustomTabName(tab))
        #expect(fixture.settings.conversationNames.isEmpty)

        model.renameTab(tab, to: "Cursor · project")
        #expect(model.title(for: tab) == "Cursor · project")
        #expect(!model.hasCustomTabName(tab))

        model.renameTab(tab, to: "Auth")
        model.resetTabName(tab)
        #expect(model.title(for: tab) == "Cursor · project")
    }

    @Test func colorIsSavedWithTheConversationAndNotWithItsCopy() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let one = try fixture.directory("one")
        let two = try fixture.directory("two")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let first = TerminalTab(spec: spec(folder: one, sessionID: "same"), settings: fixture.settings)
        let second = TerminalTab(
            spec: spec(folder: two, sessionID: "same"), settings: fixture.settings)

        model.setTabColor(first, to: .mint)
        model.setTabColor(second, to: .amber)
        model.setTabColor(first, to: .mint)
        #expect(model.tabColor(for: first) == .mint)
        #expect(model.tabColor(for: second) == .amber)
        #expect(fixture.settings.tabColors.count == 2)

        let reloaded = AppSettings(defaults: fixture.defaults)
        #expect(reloaded.tabColors.count == 2)
        #expect(
            TabColors.color(
                sessionID: "same", cwd: one.path, in: reloaded.tabColors,
                samePath: { $0 == $1 }) == .mint)

        model.setTabColor(first, to: nil)
        #expect(model.tabColor(for: first) == nil)
        #expect(model.tabColor(for: second) == .amber)
    }

    @Test func aClaudeTabSavesItsColorWithTheSession() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let id = UUID()
        let tab = TerminalTab(
            spec: GrokLaunchSpec(
                workingDirectory: folder, mode: .new(sessionID: id), provider: .claudeCode),
            settings: fixture.settings)

        model.setTabColor(tab, to: .violet)
        #expect(model.tabColor(for: tab) == .violet)
        #expect(
            fixture.settings.tabColors
                == [
                    TabColorRecord(
                        sessionID: "claudeCode:\(id.uuidString.lowercased())",
                        cwd: folder.path,
                        color: .violet)
                ])
    }

    @Test func anotherAgentColorStaysOnThatTab() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(
            spec: GrokLaunchSpec(
                workingDirectory: folder, mode: .new(sessionID: UUID()), provider: .cursor),
            settings: fixture.settings)

        model.setTabColor(tab, to: .violet)
        #expect(model.tabColor(for: tab) == .violet)
        #expect(fixture.settings.tabColors.isEmpty)
        model.setTabColor(tab, to: nil)
        #expect(model.tabColor(for: tab) == nil)
    }

    @Test func deletingAConversationDropsItsColor() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: folder.path, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model(trashConversation: { _ in })
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        let tab = TerminalTab(spec: spec(folder: folder, sessionID: "s1"), settings: fixture.settings)
        model.setTabColor(tab, to: .magenta)
        #expect(model.deleteConversation(session))
        #expect(fixture.settings.tabColors.isEmpty)
    }

    @Test func anOpenTabKeepsItsColorAfterTheSessionFileIsGone() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: folder.path, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.open(session)
        let tab = try #require(model.selectedTab)
        model.setTabColor(tab, to: .cyan)
        try FileManager.default.removeItem(at: session.directory)
        await fixture.store.reload()
        model.pruneMissingPins()
        #expect(model.tabColor(for: tab) == .cyan)

        model.closeTab(tab.id)
        model.pruneMissingPins()
        #expect(fixture.settings.tabColors.isEmpty)
    }

    @Test func aCodexTabKeepsTheNameAndColorItHadBeforeItsChatId() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let native = UUID().uuidString.lowercased()
        let script = ScriptedSessions()
        script.sessions = [
            GrokSession(
                id: native, cwd: folder.path, summary: "CLI summary",
                createdAt: .now, updatedAt: .now, messageCount: 1,
                modelID: nil, agentName: nil, reasoningEffort: nil,
                directory: folder, provider: .codex)
        ]
        let store = SessionStore(
            root: fixture.store.root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in
                SessionScanner.Result(sessions: script.sessions, cache: [:], loadError: nil)
            })
        try FileManager.default.createDirectory(at: fixture.store.root, withIntermediateDirectories: true)
        await store.reload()

        let model = fixture.model(store: store)
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(
            spec: GrokLaunchSpec(
                workingDirectory: folder, mode: .new(sessionID: UUID()), provider: .codex),
            settings: fixture.settings)
        model.renameTab(tab, to: "Auth")
        model.setTabColor(tab, to: .amber)
        model.adoptLearnedCodexSession(tab, session: script.sessions[0])

        #expect(model.title(for: tab) == "Auth")
        #expect(model.tabColor(for: tab) == .amber)
        #expect(model.hasCustomTabName(tab))
        #expect(
            fixture.settings.conversationNames
                == [ConversationName(sessionID: "codex:\(native)", cwd: folder.path, name: "Auth")])
        #expect(
            fixture.settings.tabColors
                == [TabColorRecord(sessionID: "codex:\(native)", cwd: folder.path, color: .amber)])
    }

    @Test func aSecondCopyKeepsAColorItDidNotSet() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let first = fixture.model()
        let secondSettings = AppSettings(defaults: fixture.defaults)
        let second = fixture.model(settings: secondSettings)
        defer {
            first.closeAllTabsAndWait()
            second.closeAllTabsAndWait()
        }
        let kept = TerminalTab(spec: spec(folder: folder, sessionID: "kept"), settings: fixture.settings)
        let added = TerminalTab(spec: spec(folder: folder, sessionID: "added"), settings: secondSettings)

        first.setTabColor(kept, to: .mint)
        let data = try #require(fixture.defaults.data(forKey: "tabs.colors"))
        var rows = try #require(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        rows.append(["sessionID": "bad", "cwd": folder.path, "color": "nope"])
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: rows), forKey: "tabs.colors")
        second.setTabColor(added, to: .amber)

        #expect(
            secondSettings.tabColors
                == [
                    TabColorRecord(sessionID: "added", cwd: folder.path, color: .amber),
                    TabColorRecord(sessionID: "kept", cwd: folder.path, color: .mint),
                ])
    }

    @Test func aSecondCopyKeepsANameItDidNotSet() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let first = fixture.model()
        let secondSettings = AppSettings(defaults: fixture.defaults)
        let second = fixture.model(settings: secondSettings)
        defer {
            first.closeAllTabsAndWait()
            second.closeAllTabsAndWait()
        }
        let kept = TerminalTab(spec: spec(folder: folder, sessionID: "kept"), settings: fixture.settings)
        let added = TerminalTab(spec: spec(folder: folder, sessionID: "added"), settings: secondSettings)

        first.renameTab(kept, to: "Kept")
        second.renameTab(added, to: "Added")
        #expect(
            secondSettings.conversationNames
                == [
                    ConversationName(sessionID: "added", cwd: folder.path, name: "Added"),
                    ConversationName(sessionID: "kept", cwd: folder.path, name: "Kept"),
                ])

        first.resetTabName(kept)
        #expect(
            fixture.settings.conversationNames
                == [ConversationName(sessionID: "added", cwd: folder.path, name: "Added")])
    }

    @Test(arguments: ["claudeCode", "codex"])
    func aNativeColorStaysWhenItsHistoryCannotBeRead(provider: String) async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        try FileManager.default.createDirectory(at: fixture.store.root, withIntermediateDirectories: true)
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let native = "\(provider):\(UUID().uuidString.lowercased())"
        fixture.settings.tabColors = [
            TabColorRecord(sessionID: native, cwd: folder.path, color: .cyan)
        ]

        model.pruneMissingPins()
        #expect(fixture.settings.tabColors.map(\.sessionID) == [native])
    }

    @Test func aStoredUnknownColorIsSkipped() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let data = Data(
            #"[{"sessionID":"a","cwd":"/tmp/sigil","color":"mint"},{"sessionID":"b","cwd":"/tmp/sigil","color":"nope"}]"#
                .utf8)
        fixture.defaults.set(data, forKey: "tabs.colors")
        let settings = AppSettings(defaults: fixture.defaults)
        #expect(settings.tabColors == [TabColorRecord(sessionID: "a", cwd: "/tmp/sigil", color: .mint)])
    }

    private final class ScriptedSessions: @unchecked Sendable {
        var sessions: [GrokSession] = []
    }

    private func spec(folder: URL, sessionID: String) -> GrokLaunchSpec {
        GrokLaunchSpec(
            workingDirectory: folder,
            mode: .resume(sessionID: sessionID),
            provider: .grokBuild
        )
    }
}
