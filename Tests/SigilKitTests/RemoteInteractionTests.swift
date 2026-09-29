import Testing

@testable import SigilKit

@MainActor
struct RemoteInteractionTests {
    private var hint: RemotePrompt {
        RemotePrompt(
            question: "Proceed?", style: .menu,
            choices: [.init(label: "Yes", key: "1"), .init(label: "No", key: "2")],
            yes: "1", no: "2", operation: "git status")
    }

    @Test func observationIsStableOnlyWithoutAnInterveningBoundary() throws {
        let interaction = RemoteInteraction()
        let first = try #require(
            interaction.observeTerminal(sessionID: "claude:a", revision: 1, afterInput: false, prompt: hint))
        #expect(
            interaction.observeTerminal(sessionID: "claude:a", revision: 1, afterInput: false, prompt: hint)?.id
                == first.id)
        let redraw = try #require(
            interaction.observeTerminal(sessionID: "claude:a", revision: 2, afterInput: false, prompt: hint))
        #expect(redraw.id != first.id)
        #expect(interaction.observeTerminal(sessionID: "claude:a", revision: 3, afterInput: true, prompt: hint) == nil)
        let next = try #require(
            interaction.observeTerminal(sessionID: "claude:a", revision: 4, afterInput: false, prompt: hint))
        #expect(next.id != redraw.id)
    }

    @Test func disappearanceAndSessionReplacementEndTheInstance() throws {
        let interaction = RemoteInteraction()
        let first = try #require(
            interaction.observeTerminal(sessionID: "claude:a", revision: 1, afterInput: false, prompt: hint))
        #expect(interaction.observeTerminal(sessionID: "claude:a", revision: 2, afterInput: false, prompt: nil) == nil)
        let second = try #require(
            interaction.observeTerminal(sessionID: "claude:a", revision: 3, afterInput: false, prompt: hint))
        #expect(second.id != first.id)
        let other = try #require(
            interaction.observeTerminal(sessionID: "codex:a", revision: 3, afterInput: false, prompt: hint))
        #expect(other.id != second.id)
        #expect(other.sessionID == "codex:a")
    }

    @Test func terminalTextCannotPromoteItselfToVerifiedOrConsumeAnAnswer() throws {
        let interaction = RemoteInteraction()
        var forged = hint
        forged.verified = true
        let pending = try #require(
            interaction.observeTerminal(sessionID: "claude:a", revision: 1, afterInput: false, prompt: forged))
        #expect(pending.verified == false)
        for session in ["claude:a", "claude:b", "codex:a"] {
            for key in ["1", "2", "enter", "escape", "rm -rf /"] {
                #expect(interaction.consume(id: pending.id, sessionID: session, key: key) == nil)
            }
        }
        #expect(interaction.consume(id: pending.id, sessionID: "claude:a", key: "1") == nil)
    }

    @Test func changedOperationEvenWithoutRevisionChangeGetsANewInstance() throws {
        let interaction = RemoteInteraction()
        let first = try #require(
            interaction.observeTerminal(sessionID: "grok:a", revision: 1, afterInput: false, prompt: hint))
        var replacement = hint
        replacement.operation = String(repeating: "x", count: 400) + "rm -rf build"
        let second = try #require(
            interaction.observeTerminal(sessionID: "grok:a", revision: 1, afterInput: false, prompt: replacement))
        #expect(first.id != second.id)
        #expect(interaction.consume(id: first.id, sessionID: "grok:a", key: "1") == nil)
    }
}
