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

    @Test @MainActor
    func alreadyInstalledRegistrationStillRunsMcpAddToRepairPath() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.createSession(id: "session-1", cwd: cwd)
        fixture.settings.openTabs = OpenTabsSnapshot(
            tabs: [.init(sessionID: "session-1", cwd: cwd.path)],
            selectedSessionID: "session-1",
            selectedCWD: cwd.path
        )
        fixture.settings.isTabMessagingEnabled = true
        let probe = RunnerProbe()
        probe.setResponse((0, "ok"))
        let model = fixture.model(
            registrationRunner: probe.run,
            mcpBinary: fixture.executable
        )
        defer {
            model.store.stop()
            model.closeAllTabsAndWait()
        }

        await model.onAppear()

        #expect(model.tabs.count == 1)
        #expect(fixture.settings.isTabMessagingEnabled)
        #expect(
            probe.calls.contains {
                $0 == ["mcp", "add", "sigil", fixture.executable.path, "-s", "user"]
            })
        #expect(!probe.calls.contains { $0.contains("remove") })
        #expect(model.tabMessagingError == nil)
    }

    @Test @MainActor
    func installFailureLeavesPreexistingRegistrationAndSettingOn() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        fixture.settings.isTabMessagingEnabled = true
        let probe = RunnerProbe()
        probe.setResponse((1, "server already exists"))
        let model = fixture.model(
            registrationRunner: probe.run,
            mcpBinary: fixture.executable
        )
        defer {
            model.store.stop()
            model.closeAllTabsAndWait()
        }

        await model.onAppear()

        #expect(fixture.settings.isTabMessagingEnabled)
        #expect(model.isTabMessagingAvailable)
        #expect(probe.calls.contains { $0.contains("add") })
        #expect(!probe.calls.contains { $0.contains("remove") })
        #expect(model.tabMessagingError != nil)
    }

    @Test @MainActor
    func restoreOpenTabsCompletesWhileRegistrationHangs() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.createSession(id: "session-1", cwd: cwd)
        fixture.settings.openTabs = OpenTabsSnapshot(
            tabs: [.init(sessionID: "session-1", cwd: cwd.path)],
            selectedSessionID: "session-1",
            selectedCWD: cwd.path
        )
        fixture.settings.isTabMessagingEnabled = true
        let gate = CallGate()
        let probe = RunnerProbe()
        probe.setResponse((0, "| sigil |"))
        probe.hangWhileClosed(gate)
        let model = fixture.model(
            registrationRunner: probe.run,
            mcpBinary: fixture.executable
        )
        defer {
            gate.open()
            model.store.stop()
            model.closeAllTabsAndWait()
        }

        let appear = Task { await model.onAppear() }
        let restored = await waitUntil { model.tabs.count == 1 }
        #expect(restored)
        #expect(model.tabs.first?.sessionID == "session-1")
        gate.open()
        await appear.value
        #expect(fixture.settings.isTabMessagingEnabled)
    }

    @Test @MainActor
    func canonicalPathCacheHitsAndEquatesSymlinkedPaths() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let real = try fixture.directory("project")
        let link = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: real.path)

        let counter = ResolverCounter()
        let model = fixture.model(canonicalPath: counter.wrap)
        defer { model.closeAllTabsAndWait() }

        let viaReal = makeSession(id: "session-1", cwd: real)
        let viaLink = makeSession(id: "session-1", cwd: link)
        #expect(model.sessionKey(viaReal) == model.sessionKey(viaLink))
        let afterWarm = counter.count
        #expect(afterWarm > 0)
        #expect(model.sessionKey(viaReal) == model.sessionKey(viaLink))
        #expect(counter.count == afterWarm)

        try fixture.createSession(id: "session-1", cwd: real)
        fixture.settings.openTabs = OpenTabsSnapshot(
            tabs: [.init(sessionID: "session-1", cwd: link.path)],
            selectedSessionID: "session-1",
            selectedCWD: link.path
        )
        model.restoreOpenTabs()
        #expect(model.isOpen(viaReal))
        #expect(model.isOpen(viaLink))
        let afterOpen = counter.count
        #expect(model.isOpen(viaReal))
        #expect(model.isOpen(viaLink))
        #expect(counter.count == afterOpen)
    }

    @Test @MainActor
    func pinToggleAndDeleteDropThePin() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let session = makeSession(id: "s1", cwd: cwd)
        let model = fixture.model(trashConversation: { _ in })
        defer { model.closeAllTabsAndWait() }

        #expect(!model.isPinned(session))
        model.pin(session)
        #expect(model.isPinned(session))
        #expect(fixture.settings.pinnedConversations.map(\.sessionID) == ["s1"])
        model.togglePin(session)
        #expect(!model.isPinned(session))
        model.togglePin(session)
        #expect(model.deleteConversation(session))
        #expect(!model.isPinned(session))
        #expect(fixture.settings.pinnedConversations.isEmpty)
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
    let socketURL: URL
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
        socketURL = URL(fileURLWithPath: "/tmp/s-\(UUID().uuidString.prefix(8)).sock")
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
        presentError: @escaping AppModel.ErrorPresenter = { _ in },
        registrationRunner: BridgeRegistration.Runner? = nil,
        mcpBinary: URL? = nil,
        canonicalPath: (@Sendable (String) -> String)? = nil
    ) -> AppModel {
        if let registrationRunner {
            return AppModel(
                settings: settings,
                store: store,
                trashConversation: trashConversation,
                presentError: presentError,
                registrationRunner: registrationRunner,
                mcpBinary: mcpBinary,
                tabMessagingSocketURL: socketURL,
                canonicalPath: canonicalPath ?? { GrokPaths.canonicalPath($0) }
            )
        }
        if let canonicalPath {
            return AppModel(
                settings: settings,
                store: store,
                trashConversation: trashConversation,
                presentError: presentError,
                canonicalPath: canonicalPath
            )
        }
        return AppModel(
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
        try? FileManager.default.removeItem(at: socketURL)
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

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private final class RunnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [[String]] = []
    private var storedResponses: [(Int32, String)] = []
    private var storedResponse: (Int32, String) = (0, "")
    private var gate: CallGate?

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func setResponse(_ value: (Int32, String)) {
        lock.lock()
        storedResponse = value
        lock.unlock()
    }

    func setResponses(_ values: [(Int32, String)]) {
        lock.lock()
        storedResponses = values
        lock.unlock()
    }

    func hangWhileClosed(_ gate: CallGate) {
        lock.lock()
        self.gate = gate
        lock.unlock()
    }

    func run(executable: URL, arguments: [String]) -> (Int32, String) {
        let gate: CallGate?
        lock.lock()
        gate = self.gate
        lock.unlock()
        gate?.waitWhileClosed()

        lock.lock()
        storedCalls.append(arguments)
        let result: (Int32, String)
        if storedResponses.isEmpty {
            result = storedResponse
        } else {
            result = storedResponses.removeFirst()
        }
        lock.unlock()
        return result
    }
}

private final class CallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func waitWhileClosed() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var wrap: @Sendable (String) -> String {
        { [self] path in
            lock.lock()
            value += 1
            lock.unlock()
            return GrokPaths.canonicalPath(path)
        }
    }
}
