import Foundation
import Testing

@testable import SigilKit

struct ConversationNamingTests {

    @Test func displayedTitlePrefersCustomName() {
        let session = session(id: "s1", cwd: "/tmp/project", summary: "CLI summary")
        #expect(
            ConversationNaming.displayedTitle(for: session, customName: "Auth rewrite")
                == "Auth rewrite")
        #expect(
            ConversationNaming.displayedTitle(for: session, customName: nil) == "CLI summary")
        #expect(
            ConversationNaming.displayedTitle(for: session, customName: "  ") == "CLI summary")
    }

    @Test func emptySummaryFallsBackUntilNamed() {
        let session = session(id: "s1", cwd: "/tmp/diablomaxxing", summary: "")
        #expect(session.title == "Untitled session in diablomaxxing")
        #expect(
            ConversationNaming.displayedTitle(for: session, customName: "Keep me") == "Keep me")
        #expect(
            ConversationNaming.displayedTitle(for: session, customName: nil)
                == "Untitled session in diablomaxxing")
    }

    @Test func settingEmptyOrWhitespaceRemovesTheName() {
        let session = session(id: "s1", cwd: "/tmp/project", summary: "CLI summary")
        var names: [ConversationName] = []
        names = ConversationNaming.setting("Auth rewrite", on: session, onto: names, samePath: ==)
        #expect(ConversationNaming.name(for: session, in: names, samePath: ==) == "Auth rewrite")

        names = ConversationNaming.setting("  \n", on: session, onto: names, samePath: ==)
        #expect(ConversationNaming.name(for: session, in: names, samePath: ==) == nil)
        #expect(names.isEmpty)

        names = ConversationNaming.setting("Auth rewrite", on: session, onto: names, samePath: ==)
        names = ConversationNaming.setting("", on: session, onto: names, samePath: ==)
        #expect(names.isEmpty)
        #expect(
            ConversationNaming.displayedTitle(
                for: session,
                customName: ConversationNaming.name(for: session, in: names, samePath: ==)
            ) == "CLI summary")
    }

    @Test func customNameSurvivesADifferentSummary() {
        let original = session(id: "s1", cwd: "/tmp/project", summary: "CLI summary")
        let names = ConversationNaming.setting(
            "Auth rewrite", on: original, onto: [], samePath: ==)
        let rewritten = session(id: "s1", cwd: "/tmp/project", summary: "Totally new CLI summary")
        #expect(rewritten.title == "Totally new CLI summary")
        #expect(
            ConversationNaming.displayedTitle(
                for: rewritten,
                customName: ConversationNaming.name(for: rewritten, in: names, samePath: ==)
            ) == "Auth rewrite")
    }

    @Test func identityIsSessionIDAndWorkingDirectory() {
        let one = session(id: "same", cwd: "/tmp/one", summary: "One")
        let two = session(id: "same", cwd: "/tmp/two", summary: "Two")
        var names: [ConversationName] = []
        names = ConversationNaming.setting("Alpha", on: one, onto: names, samePath: ==)
        #expect(ConversationNaming.name(for: one, in: names, samePath: ==) == "Alpha")
        #expect(ConversationNaming.name(for: two, in: names, samePath: ==) == nil)
        #expect(ConversationNaming.displayedTitle(for: two, customName: nil) == "Two")
    }

    @Test func namesRoundTripThroughJSON() throws {
        let names = [
            ConversationName(sessionID: "s1", cwd: "/tmp/project", name: "Auth rewrite")
        ]
        let data = try JSONEncoder().encode(names)
        let decoded = try JSONDecoder().decode([ConversationName].self, from: data)
        #expect(decoded == names)
    }

    @Test func searchUsesTheDisplayedTitle() {
        let session = session(id: "s1", cwd: "/tmp/project", summary: "CLI summary")
        #expect(
            SessionScanner.matches(session, query: "Auth", displayedTitle: "Auth rewrite"))
        #expect(!SessionScanner.matches(session, query: "Auth"))
        #expect(SessionScanner.matches(session, query: "CLI"))
        #expect(
            SessionScanner.matches(session, query: "CLI", displayedTitle: "Auth rewrite"))
    }
}

private func session(id: String, cwd: String, summary: String) -> GrokSession {
    GrokSession(
        id: id,
        cwd: cwd,
        summary: summary,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: URL(fileURLWithPath: cwd).appendingPathComponent(id)
    )
}
