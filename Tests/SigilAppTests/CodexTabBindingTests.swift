import Darwin
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
@MainActor
struct CodexTabBindingTests {
    @Test func newConversationAmbiguityInvalidatesAnEarlierAutomaticLiveBinding() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.newTab()
        let first = try await fixture.prompt(tab)
        await fixture.store.reload()
        await fixture.awaitBinding()
        #expect(tab.nativeSessionID == first)
        let firstTaskID = try #require(fixture.model.taskID(for: tab))
        let next = UUID().uuidString.lowercased()
        tab.controller.send(text: "\(first) \(next)\r")
        #expect(await waitUntil { tab.controller.bufferText().contains("HELD=\(next)") })
        await fixture.store.reload()
        await fixture.awaitBinding()
        #expect(tab.sessionReference == nil)
        #expect(fixture.source.settings.openTabs.tabs.isEmpty)
        #expect(fixture.source.settings.isSigilConversation("codex:\(first)"))
        let chosen = try #require(
            fixture.model.codexLinkCandidates(for: tab).first(where: { $0.nativeSessionID == next }))
        #expect(await fixture.model.linkCodexSession(chosen, to: tab.id))
        await fixture.awaitBinding()
        #expect(tab.nativeSessionID == next)
        let nextTaskID = try #require(fixture.model.taskID(for: tab))
        #expect(nextTaskID != firstTaskID)
        #expect(fixture.model.taskLedger.entries.first(where: { $0.taskID == firstTaskID })?.conversationID == first)
        #expect(fixture.model.taskLedger.entries.first(where: { $0.taskID == nextTaskID })?.conversationID == next)
    }

    @Test func anOutsideWriterNeverBindsAWaitingTabOrEnablesRestart() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.newTab()
        let native = UUID().uuidString.lowercased()
        let input = Pipe()
        let outside = Process()
        outside.executableURL = URL(fileURLWithPath: "/bin/sh")
        outside.arguments = [
            "-c", "exec 3>\"$1\"; printf '%s\\n' \"$2\" >&3; printf ready >\"$3\"; read -r done", "outside",
            fixture.file(native).path, String(decoding: try fixture.data(native), as: UTF8.self),
            fixture.codexHome.appendingPathComponent("outside.ready").path,
        ]
        outside.environment = ["PATH": "/usr/bin:/bin", "CODEX_HOME": fixture.codexHome.path]
        outside.standardInput = input
        outside.standardOutput = FileHandle.nullDevice
        outside.standardError = FileHandle.nullDevice
        try outside.run()
        defer {
            try? input.fileHandleForWriting.close()
            let deadline = ContinuousClock.now + .seconds(2)
            while outside.isRunning, ContinuousClock.now < deadline { usleep(10_000) }
            if outside.isRunning { kill(outside.processIdentifier, SIGKILL) }
            outside.waitUntilExit()
        }
        #expect(
            await waitUntil {
                FileManager.default.fileExists(atPath: fixture.codexHome.appendingPathComponent("outside.ready").path)
            })
        await fixture.store.reload()
        #expect(fixture.store.sessions.contains(where: { $0.nativeSessionID == native }))
        await fixture.awaitBinding()
        #expect(tab.sessionReference == nil)
        #expect(!fixture.source.settings.isSigilConversation("codex:\(native)"))
        #expect(fixture.source.settings.openTabs.tabs.isEmpty)
        #expect(!tab.capabilities.resume)
        let process = tab.controller.processGeneration
        fixture.model.restartTab(id: tab.id)
        #expect(fixture.model.tabs.first === tab)
        #expect(tab.controller.processGeneration == process)
        #expect(fixture.errors.values.count == 1)
        #expect(fixture.errors.values.first?.localizedDescription == "Open this conversation from history")
    }

    @Test func twoSameFolderTabsBindTheirOwnFilesInReversedFirstUse() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.newTab()
        let second = try await fixture.newTab()
        let secondID = try await fixture.prompt(second)
        let firstID = try await fixture.prompt(first)
        await fixture.store.reload()
        await fixture.awaitBinding()
        #expect(first.nativeSessionID == firstID && second.nativeSessionID == secondID)
        #expect(fixture.source.settings.openTabs.tabs.map(\.sessionID) == [firstID, secondID])
        #expect(fixture.source.settings.isSigilConversation("codex:\(firstID)"))
        #expect(fixture.source.settings.isSigilConversation("codex:\(secondID)"))
        // Exact ownership and validated metadata enable tracking, not completion.
        #expect(first.capabilities.lifecycle && second.capabilities.lifecycle)
        #expect(first.activity == .unknown && second.activity == .unknown)
    }

    @Test func multipleFilesNeedAnExplicitUserLink() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.newTab()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        tab.controller.send(text: "\(first) \(second)\r")
        #expect(await waitUntil { tab.controller.bufferText().contains("HELD=\(second)") })
        await fixture.store.reload()
        await fixture.awaitBinding()
        #expect(tab.nativeSessionID == nil)
        let choices = fixture.model.codexLinkCandidates(for: tab)
        #expect(Set(choices.map(\.nativeSessionID)) == Set([first, second]))
        let chosen = try #require(choices.first(where: { $0.nativeSessionID == second }))
        #expect(await fixture.model.linkCodexSession(chosen, to: tab.id))
        #expect(tab.nativeSessionID == second)
        #expect(fixture.source.settings.openTabs.tabs.first?.sessionID == second)
        #expect(!fixture.model.codexLinkCandidates(for: tab).contains(chosen))
    }

    @Test func twoTreesHoldingTheSameNewFileCannotClaimItByOrder() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.newTab()
        let second = try await fixture.newTab()
        let native = UUID().uuidString.lowercased()
        _ = try await fixture.prompt(first, native: native)
        _ = try await fixture.prompt(second, native: native)
        await fixture.store.reload()
        await fixture.awaitBinding()
        #expect(first.nativeSessionID == nil)
        #expect(second.nativeSessionID == nil)
        #expect(fixture.source.settings.openTabs.tabs.isEmpty)
    }

    @Test func aClosedTabCannotClaimItsLateHistory() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.newTab()
        let native = try await fixture.prompt(tab)
        fixture.model.closeTab(tab.id)
        await fixture.store.reload()
        await fixture.awaitBinding()
        #expect(fixture.model.tabs.isEmpty)
        #expect(!fixture.source.settings.isSigilConversation("codex:\(native)"))
        #expect(fixture.source.settings.openTabs.tabs.isEmpty)
    }

    @Test func anExplicitLinkRechecksHistoryAndTheTargetTab() async throws {
        let fixture = try CodexBindingFixture()
        defer { fixture.cleanup() }
        let tab = try await fixture.newTab()
        let native = UUID().uuidString.lowercased()
        try fixture.data(native).write(to: fixture.file(native))
        await fixture.store.reload()
        let candidate = try #require(fixture.model.codexLinkCandidates(for: tab).first)
        try Data("malformed\n".utf8).write(to: candidate.directory)
        #expect(!(await fixture.model.linkCodexSession(candidate, to: tab.id)))
        #expect(tab.nativeSessionID == nil)
        #expect(fixture.errors.values.count == 1)
        try fixture.data(native).write(to: fixture.file(native))
        fixture.model.closeTab(tab.id)
        #expect(!(await fixture.model.linkCodexSession(candidate, to: tab.id)))
        #expect(fixture.source.settings.openTabs.tabs.isEmpty)
    }
}

/// CI-only AppModel/PTY fixture. The shell and Codex executable are generated;
/// every home and history root is private to the test.
@MainActor
final class CodexBindingFixture {
    final class Errors { var values: [Error] = [] }
    let source: ModelFixture
    let cwd: URL
    let codexHome: URL
    let store: SessionStore
    let model: AppModel
    let errors: Errors
    private let oldEnvironment: [String: String?]

    init() throws {
        source = try ModelFixture()
        cwd = try source.directory("project")
        codexHome = try source.directory("codex-home")
        let sessions = codexHome.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.store.root, withIntermediateDirectories: true)
        let bin = try source.directory("fake-bin")
        let shell = bin.appendingPathComponent("zsh")
        try "#!/bin/sh\nshift\nexec /bin/sh -c \"$@\"\n".write(to: shell, atomically: true, encoding: .utf8)
        let cli = bin.appendingPathComponent("codex")
        try """
        #!/bin/sh
        printf 'READY\\n'
        while IFS= read -r line; do
            set -- $line
            exec 3>"$CODEX_HOME/sessions/$1.jsonl"
            printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","cli_version":"0.157.1"}}\\n' "$1" "$PWD" >&3
            printf 'HELD=%s\\n' "$1"
            if [ -n "$2" ]; then
                exec 4>"$CODEX_HOME/sessions/$2.jsonl"
                printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","cli_version":"0.157.1"}}\\n' "$2" "$PWD" >&4
                printf 'HELD=%s\\n' "$2"
            fi
        done
        """.write(to: cli, atomically: true, encoding: .utf8)
        for file in [shell, cli] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        oldEnvironment = Dictionary(
            uniqueKeysWithValues: ["SHELL", "PATH", "CODEX_HOME"].map {
                ($0, ProcessInfo.processInfo.environment[$0])
            })
        setenv("SHELL", shell.path, 1)
        setenv("PATH", "\(bin.path):/usr/bin:/bin", 1)
        setenv("CODEX_HOME", codexHome.path, 1)
        store = SessionStore(root: source.store.root, timing: SessionStoreTiming(), nativeRoots: [(.codex, sessions)])
        let errors = Errors()
        self.errors = errors
        model = source.model(store: store, presentError: { errors.values.append($0) })
    }

    func cleanup() {
        model.closeAllTabsAndWait()
        for (key, value) in oldEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        source.cleanup()
    }

    func newTab() async throws -> TerminalTab {
        let tab = try #require(model.newTab(in: cwd, provider: .codex))
        #expect(await waitUntil { tab.controller.bufferText().contains("READY") })
        return tab
    }

    func awaitBinding() async {
        await Task.yield()
        model.recordStartedCodexSessions()
        while let pending = model.codexBindingTask { await pending.value }
    }

    func prompt(_ tab: TerminalTab, native: String = UUID().uuidString.lowercased()) async throws -> String {
        tab.controller.send(text: "\(native)\r")
        #expect(await waitUntil { tab.controller.bufferText().contains("HELD=\(native)") })
        return native
    }

    func file(_ id: String) -> URL { codexHome.appendingPathComponent("sessions/\(id).jsonl") }

    func data(_ id: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": ["id": id, "cwd": cwd.path, "cli_version": "0.157.1"],
        ]) + Data([0x0A])
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
