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

        #expect(model.title(for: tab) == "Cursor")
        model.renameTab(tab, to: "Auth")
        #expect(model.title(for: tab) == "Auth")
        #expect(model.hasCustomTabName(tab))
        #expect(fixture.settings.conversationNames.isEmpty)

        model.renameTab(tab, to: "Cursor")
        #expect(model.title(for: tab) == "Cursor")
        #expect(!model.hasCustomTabName(tab))

        model.renameTab(tab, to: "Auth")
        model.resetTabName(tab)
        #expect(model.title(for: tab) == "Cursor")
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

    @Test func anotherAgentColorStaysOnThatTab() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = TerminalTab(
            spec: GrokLaunchSpec(
                workingDirectory: folder, mode: .new(sessionID: UUID()), provider: .claudeCode),
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

    private func spec(folder: URL, sessionID: String) -> GrokLaunchSpec {
        GrokLaunchSpec(
            workingDirectory: folder,
            mode: .resume(sessionID: sessionID),
            provider: .grokBuild
        )
    }
}
