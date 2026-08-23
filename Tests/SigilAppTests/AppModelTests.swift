import AppKit
import Darwin
import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct AppModelTests {
    @Test @MainActor
    func restoreUsesIDAndFolderAndDoesNotDuplicateTabs() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwdA = try fixture.directory("project-a")
        let cwdB = try fixture.directory("project-b")
        let id = "copied-session-id"
        try fixture.createSession(id: id, cwd: cwdA)
        try fixture.createSession(id: id, cwd: cwdB)
        fixture.settings.openTabs = OpenTabsSnapshot(
            tabs: [
                .init(sessionID: id, cwd: cwdA.path),
                .init(sessionID: id, cwd: cwdB.path),
            ],
            selectedSessionID: id,
            selectedCWD: cwdB.path
        )

        let model = fixture.model()
        model.restoreOpenTabs()
        #expect(model.tabs.count == 2)
        #expect(model.selectedTab?.sessionID == id)
        #expect(model.selectedTab?.workingDirectory.resolvingSymlinksInPath().path == cwdB.path)

        model.restoreOpenTabs()
        #expect(model.tabs.count == 2)
        model.closeAllTabsAndWait()
    }

    @Test @MainActor
    func unavailableRestoredTabIsNotErased() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let available = try fixture.directory("available")
        let missing = fixture.root.appendingPathComponent("missing")
        try fixture.createSession(id: "available-id", cwd: available)
        fixture.settings.openTabs = OpenTabsSnapshot(
            tabs: [
                .init(sessionID: "available-id", cwd: available.path),
                .init(sessionID: "missing-id", cwd: missing.path),
            ],
            selectedSessionID: "missing-id",
            selectedCWD: missing.path
        )

        let model = fixture.model()
        model.restoreOpenTabs()

        #expect(model.tabs.count == 1)
        #expect(fixture.settings.openTabs.tabs.count == 2)
        #expect(fixture.settings.openTabs.selectedSessionID == "missing-id")
        #expect(fixture.settings.openTabs.selectedCWD == missing.path)
        model.closeAllTabsAndWait()
    }

    @Test @MainActor
    func failedTrashRestartsOnlyStoppedTabAndPreservesSelectionAndSnapshot() throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nexec /usr/bin/yes >/dev/null\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let errors = ErrorBox()
        let model = fixture.model(
            trashConversation: { _ in throw TestFailure.expected },
            presentError: { errors.error = $0 }
        )
        let original = try #require(model.newTab(in: cwd))
        let sessionID = try #require(original.sessionID)
        let snapshot = fixture.settings.openTabs
        let session = makeSession(id: sessionID, cwd: cwd)

        #expect(!model.deleteConversation(session))

        #expect(errors.error != nil)
        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].id != original.id)
        #expect(model.selectedTab?.id == model.tabs[0].id)
        #expect(model.selectedTab?.sessionID == sessionID)
        #expect(fixture.settings.openTabs == snapshot)
        model.closeAllTabsAndWait()
    }

    @Test @MainActor
    func deletingOneCopiedSessionLeavesTheOtherOpen() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwdA = try fixture.directory("project-a")
        let cwdB = try fixture.directory("project-b")
        let id = "same-id"
        try fixture.createSession(id: id, cwd: cwdA)
        try fixture.createSession(id: id, cwd: cwdB)
        fixture.settings.openTabs = .init(
            tabs: [
                .init(sessionID: id, cwd: cwdA.path),
                .init(sessionID: id, cwd: cwdB.path),
            ],
            selectedSessionID: id,
            selectedCWD: cwdB.path
        )
        let model = fixture.model(trashConversation: { _ in })
        model.restoreOpenTabs()

        #expect(model.deleteConversation(makeSession(id: id, cwd: cwdA)))

        #expect(model.tabs.count == 1)
        #expect(model.tabs[0].workingDirectory.resolvingSymlinksInPath().path == cwdB.path)
        #expect(fixture.settings.openTabs.tabs == [.init(sessionID: id, cwd: cwdB.path)])
        #expect(fixture.settings.openTabs.selectedCWD == cwdB.path)
        model.closeAllTabsAndWait()
    }

    @Test
    func successfulExportUsesWorkingFolderAndAtomicallyReplacesDestination() async throws {
        let root = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let working = root.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let script = try makeExecutable(
            in: root,
            body: """
                #!/bin/sh
                /usr/bin/yes x | /usr/bin/head -c 200000 >&2
                printf '%s|%s' "$PWD" "$2" > "$3"
                """
        )
        let output = root.appendingPathComponent("Transcript.md")
        try Data("old".utf8).write(to: output)

        try await AppModel.runTranscriptExport(
            executable: script,
            sessionID: "session-1",
            output: output,
            workingDirectory: working,
            timeout: .seconds(5)
        )

        let exported = try String(contentsOf: output, encoding: .utf8)
        let expected = "\(GrokPaths.canonicalPath(working.path))|session-1"
        #expect(exported == expected, "exported=\(exported), expected=\(expected)")
        #expect(try temporaryExports(nextTo: output).isEmpty)
    }

    @Test
    func failedExportPreservesExistingDestinationAndReportsCLIOutput() async throws {
        let root = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try makeExecutable(
            in: root,
            body: """
                #!/bin/sh
                printf partial > "$3"
                echo 'clear export failure' >&2
                exit 7
                """
        )
        let output = root.appendingPathComponent("Transcript.md")
        try Data("original".utf8).write(to: output)

        do {
            try await AppModel.runTranscriptExport(
                executable: script,
                sessionID: "session-1",
                output: output,
                workingDirectory: root,
                timeout: .seconds(5)
            )
            Issue.record("Export should fail")
        } catch {
            #expect(error.localizedDescription.contains("clear export failure"))
        }

        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
        #expect(try temporaryExports(nextTo: output).isEmpty)
    }

    @Test
    func timedOutExportPreservesExistingDestination() async throws {
        let root = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try makeExecutable(
            in: root,
            body: """
                #!/bin/sh
                printf partial > "$3"
                exec /usr/bin/yes >/dev/null 2>&1
                """
        )
        let output = root.appendingPathComponent("Transcript.md")
        try Data("original".utf8).write(to: output)
        let start = ContinuousClock.now

        do {
            try await AppModel.runTranscriptExport(
                executable: script,
                sessionID: "session-1",
                output: output,
                workingDirectory: root,
                timeout: .milliseconds(100)
            )
            Issue.record("Export should time out")
        } catch {
            #expect(error.localizedDescription.contains("did not finish"))
        }

        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
        #expect(try temporaryExports(nextTo: output).isEmpty)
    }
}

private enum TestFailure: Error {
    case expected
}

@MainActor
private final class ErrorBox {
    var error: Error?
}

@MainActor
private final class ModelFixture {
    let root: URL
    let grokHome: URL
    let executable: URL
    let settings: AppSettings
    let store: SessionStore

    private let oldGrokHome: String?
    private let defaultsName: String

    init(script: String = "#!/bin/sh\nexit 0\n") throws {
        root = try makeTemporaryTestDirectory()
        grokHome = root.appendingPathComponent("grok-home")
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
        oldGrokHome = ProcessInfo.processInfo.environment["GROK_HOME"]
        setenv("GROK_HOME", grokHome.path, 1)
        executable = try makeExecutable(in: root, body: script)
        defaultsName = "SigilAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        settings = AppSettings(defaults: defaults)
        settings.executablePath = executable.path
        store = SessionStore(root: grokHome.appendingPathComponent("sessions"))
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func createSession(id: String, cwd: URL) throws {
        try FileManager.default.createDirectory(
            at: GrokPaths.sessionDirectory(cwd: cwd.path, sessionID: id),
            withIntermediateDirectories: true
        )
    }

    func model(
        trashConversation: @escaping AppModel.TrashConversation = { _ in },
        presentError: @escaping AppModel.ErrorPresenter = { _ in }
    ) -> AppModel {
        AppModel(
            settings: settings,
            store: store,
            trashConversation: trashConversation,
            presentError: presentError
        )
    }

    func cleanup() {
        if let oldGrokHome {
            setenv("GROK_HOME", oldGrokHome, 1)
        } else {
            unsetenv("GROK_HOME")
        }
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeSession(id: String, cwd: URL) -> GrokSession {
    GrokSession(
        id: id,
        cwd: cwd.path,
        summary: "Session",
        createdAt: .now,
        updatedAt: .now,
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: GrokPaths.sessionDirectory(cwd: cwd.path, sessionID: id)
    )
}

private func makeExecutable(in root: URL, body: String) throws -> URL {
    let url = root.appendingPathComponent("grok-\(UUID().uuidString)")
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
    return url
}

private func temporaryExports(nextTo output: URL) throws -> [URL] {
    let prefix = ".\(output.deletingPathExtension().lastPathComponent).sigil-"
    return try FileManager.default.contentsOfDirectory(
        at: output.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(prefix) }
}

private func makeTemporaryTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
