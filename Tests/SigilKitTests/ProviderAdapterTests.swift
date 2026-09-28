import Foundation
import Testing

@testable import SigilKit

struct ProviderAdapterTests {
    private let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    @Test func nativeLaunchAndResumeNeverBecomeANewConversation() {
        let cwd = URL(fileURLWithPath: "/tmp/project")
        let claude = GrokLaunchSpec(workingDirectory: cwd, mode: .new(sessionID: id), provider: .claudeCode)
        #expect(claude.arguments() == ["--session-id", id.uuidString.lowercased()])
        let resume = GrokLaunchSpec(
            workingDirectory: cwd, mode: .resume(sessionID: id.uuidString), provider: .claudeCode)
        #expect(resume.arguments() == ["--resume", id.uuidString])
        let codex = GrokLaunchSpec(workingDirectory: cwd, mode: .resume(sessionID: id.uuidString), provider: .codex)
        #expect(codex.arguments() == ["resume", id.uuidString])
        #expect(
            GrokLaunchSpec(workingDirectory: cwd, mode: .continueLatest, provider: .codex).arguments() == [
                "resume", "--last",
            ])
    }

    @Test func identitySeparatesProviderAndProjectWithoutChangingGrokKeys() {
        let grok = ProviderSessionReference(provider: .grokBuild, sessionID: "same", cwd: "/tmp/a")
        let claude = ProviderSessionReference(provider: .claudeCode, sessionID: "same", cwd: "/tmp/a")
        let worktree = ProviderSessionReference(provider: .claudeCode, sessionID: "same", cwd: "/tmp/b")
        #expect(grok.sidebarID == "same")
        #expect(claude.sidebarID == "claudeCode:same")
        #expect(grok != claude)
        #expect(claude != worktree)
    }

    @Test func olderSnapshotDecodesAsGrokAndNewSnapshotRetainsProvider() throws {
        let old = try #require(
            OpenTabsSnapshot.decode(
                Data(#"{"tabs":[{"sessionID":"old","cwd":"/tmp"}],"selectedSessionID":"old"}"#.utf8)))
        #expect(old.tabs[0].provider == .grokBuild)
        let entry = OpenTabsSnapshot.Entry(sessionID: "native", cwd: "/tmp", provider: .codex)
        let snapshot = OpenTabsSnapshot(tabs: [entry], selectedSessionID: "native", selectedProvider: .codex)
        #expect(OpenTabsSnapshot.decode(try #require(snapshot.encode())) == snapshot)
    }

    @Test func capabilitiesDoNotFabricateParity() throws {
        #expect(CLIProvider.claudeCode.capabilities.history)
        #expect(CLIProvider.codex.capabilities.resume)
        #expect(!CLIProvider.claudeCode.capabilities.export)
        #expect(!CLIProvider.codex.capabilities.bridge)
        #expect(!CLIProvider.cursor.capabilities.history)
        #expect(CLIProvider.allCases.allSatisfy { !$0.capabilities.structuredApproval })
        let data = try JSONEncoder().encode(CLIProvider.codex.capabilities)
        #expect(try JSONDecoder().decode(ProviderCapabilities.self, from: data) == CLIProvider.codex.capabilities)
    }
}
