import AppKit
import Foundation
import SigilKit
import Testing

@testable import SigilApp

/// The first window does not wait for the login shell's GROK_HOME, and the
/// model built after it answers matches the one a blocking launch built.
@Suite(.serialized)
@MainActor
struct MacStartupTests {
    /// No delay, a quarter second, and past the probe's two-second ceiling.
    @Test(arguments: [nil, 0.25, 2.5] as [Double?])
    func theWindowDoesNotWaitForTheLoginShell(delay: Double?) async throws {
        let profile = try ShellProfile(delay: delay)
        defer { profile.cleanup() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let log = Log()
        // Today's blocking read of the same profile, for the answer to match.
        let environment = profile.environment
        async let blocking = Task.detached { GrokPaths.loginShellGrokHome(environment: environment) }.value

        let started = ContinuousClock.now
        let launch = AppLaunch(
            environment: profile.environment,
            adopt: { log.append("adopt \($0)") },
            makeModel: {
                log.append("model")
                return fixture.model()
            })
        let initTime = ContinuousClock.now - started

        // Init only started the probe: no model, nothing adopted, main is free.
        #expect(launch.model == nil)
        #expect(log.entries.isEmpty)
        #expect(initTime < .milliseconds(200))
        if delay != nil {
            await flushMainAsync()
            #expect(launch.model == nil)
        }

        let model = await ready(launch)
        let expected = await blocking
        #expect(launch.model === model)
        #expect(log.entries == (expected.map { ["adopt \($0)"] } ?? []) + ["model"])
        if delay == 2.5 {
            // The ceiling passed: nothing adopted, and the model is built anyway.
            #expect(expected == nil)
        } else {
            #expect(expected == profile.grokHome)
        }
    }

    @Test func theModelSeesTheSameRootAndCLIEnvironmentAsABlockingLaunch() async throws {
        let profile = try ShellProfile(delay: 0.25)
        defer { profile.cleanup() }
        let saved = GrokHomeVariable()
        defer { saved.restore() }
        let suite = "MacStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let notes = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-startup-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: notes) }

        // Exactly what SigilApp.init did before: probe, adopt, then build.
        unsetenv("GROK_HOME")
        if let grokHome = GrokPaths.loginShellGrokHome(environment: profile.environment) {
            setenv("GROK_HOME", grokHome, 1)
        }
        let blockingRoot = SessionStore().root
        let blockingVariable = ProcessInfo.processInfo.environment["GROK_HOME"]
        let blockingExecutable = AppSettings(defaults: defaults).executablePath
        unsetenv("GROK_HOME")

        let launch = AppLaunch(
            environment: profile.environment,
            makeModel: {
                AppModel(
                    settings: AppSettings(defaults: defaults),
                    store: SessionStore(),
                    panel: RightPanel(defaults: defaults, notesStore: ConversationNotesStore(root: notes)),
                    pairingStore: InMemoryRemotePairingStore())
            })
        #expect(launch.model == nil)
        let model = await ready(launch)

        #expect(blockingRoot.path == profile.grokHome + "/sessions")
        #expect(model.store.root == blockingRoot)
        // A CLI launch reads the process environment, as it did before.
        #expect(ProcessInfo.processInfo.environment["GROK_HOME"] == blockingVariable)
        #expect(model.settings.executablePath == blockingExecutable)
    }

    @Test func aLaunchThatHasGrokHomeBuildsTheModelAtOnceAndReadsNoShell() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let probes = Log()
        let log = Log()

        let launch = AppLaunch(
            environment: ["GROK_HOME": fixture.grokHome.path, "SHELL": "/bin/zsh"],
            probe: { _ in
                probes.append("probe")
                return "/from/the/shell"
            },
            adopt: { log.append("adopt \($0)") },
            makeModel: {
                log.append("model")
                return fixture.model()
            })

        #expect(launch.model != nil)
        #expect(log.entries == ["model"])
        var ran = false
        launch.whenReady { _ in ran = true }
        #expect(ran)
        #expect(probes.entries.isEmpty)
        #expect(!launch.isSlow)
    }

    @Test func anEmptyGrokHomeStillReadsTheShell() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let log = Log()

        let launch = AppLaunch(
            environment: ["GROK_HOME": ""],
            probe: { _ in "/from/the/shell" },
            adopt: { log.append("adopt \($0)") },
            makeModel: {
                log.append("model")
                return fixture.model()
            })

        #expect(launch.model == nil)
        _ = await ready(launch)
        #expect(log.entries == ["adopt /from/the/shell", "model"])
    }

    @Test func requestsBeforeTheModelExistsWaitAndRunInOrder() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let log = Log()
        let launch = AppLaunch(
            environment: [:],
            probe: { _ in
                gate.wait()
                return "/resolved"
            },
            adopt: { log.append("adopt \($0)") },
            makeModel: {
                log.append("model")
                return fixture.model()
            })

        launch.whenReady { _ in log.append("new session") }
        launch.whenReady { _ in log.append("window") }
        await flushMainAsync()
        #expect(launch.model == nil)
        #expect(log.entries.isEmpty)

        gate.signal()
        let model = await ready(launch)
        #expect(log.entries == ["adopt /resolved", "model", "new session", "window"])

        var late: AppModel?
        launch.whenReady { late = $0 }
        #expect(late === model)
    }

    @Test func theSpinnerWaitsForASlowShell() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let launch = AppLaunch(
            environment: [:],
            slowAfter: .milliseconds(50),
            probe: { _ in
                gate.wait()
                return nil
            },
            makeModel: { fixture.model() })

        #expect(!launch.isSlow)
        #expect(await waitUntil { launch.isSlow })
        #expect(launch.model == nil)
        gate.signal()
        _ = await ready(launch)
    }

    @Test func aQuickShellShowsNoSpinner() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let launch = AppLaunch(
            environment: [:],
            probe: { _ in nil },
            makeModel: { fixture.model() })

        _ = await ready(launch)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!launch.isSlow)
    }
}

/// Waits for the model through the same path the menus and window use.
@MainActor
private func ready(_ launch: AppLaunch) async -> AppModel {
    await withCheckedContinuation { continuation in
        launch.whenReady { continuation.resume(returning: $0) }
    }
}

/// A login shell whose `.zshenv` sleeps, then exports GROK_HOME.
private struct ShellProfile {
    let home: URL
    let environment: [String: String]
    var grokHome: String { home.path + "/grok-from-profile" }

    init(delay: Double?) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-startup-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let sleep = delay.map { "/bin/sleep \($0)\n" } ?? ""
        try (sleep + "export GROK_HOME=\"$HOME/grok-from-profile\"\n")
            .write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        environment = [
            "HOME": home.path, "ZDOTDIR": home.path, "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin",
        ]
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: home)
    }
}

/// Puts the process's GROK_HOME back as the test found it.
private struct GrokHomeVariable {
    let value = ProcessInfo.processInfo.environment["GROK_HOME"]

    func restore() {
        if let value {
            setenv("GROK_HOME", value, 1)
        } else {
            unsetenv("GROK_HOME")
        }
    }
}

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var entries: [String] { lock.withLock { stored } }
    func append(_ entry: String) { lock.withLock { stored.append(entry) } }
}

@MainActor
private func flushMainAsync() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
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
