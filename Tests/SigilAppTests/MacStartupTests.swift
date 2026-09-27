import AppKit
import Foundation
import SigilKit
import SwiftUI
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

        var launchVariable: String?
        let launch = AppLaunch(
            environment: profile.environment,
            makeModel: {
                // Read in the adopt's own main-actor turn: other suites'
                // fixtures set GROK_HOME while this test awaits.
                launchVariable = ProcessInfo.processInfo.environment["GROK_HOME"]
                return AppModel(
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
        #expect(launchVariable == blockingVariable)
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

    /// The canvas before the model exists wears the theme the model will.
    @Test(arguments: [nil, TerminalTheme.all.last?.name, "No Such Theme"] as [String?])
    func theWaitingWindowUsesTheSavedTheme(saved: String?) throws {
        let suite = "MacStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let saved { defaults.set(saved, forKey: "terminal.theme") }

        #expect(AppSettings.storedTheme(defaults: defaults).name == AppSettings(defaults: defaults).theme.name)
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

    /// The window SigilApp shows, hosted in a real window, while a `.zshenv`
    /// sleeps past the probe's ceiling: it lays out at once with no model,
    /// then shows its content once the model is built.
    @Test func theRealWindowLaysOutBeforeTheLoginShellAnswers() async throws {
        let profile = try ShellProfile(delay: 2.5)
        defer { profile.cleanup() }
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        _ = NSApplication.shared
        var appeared = 0
        var wired: AppModel?

        let started = ContinuousClock.now
        let launch = AppLaunch(
            environment: profile.environment,
            adopt: { _ in },
            makeModel: { fixture.model() })
        // As SigilApp.body builds it, with the delegate wiring it passes.
        let host = NSHostingView(
            rootView: SigilApp.mainWindow(launch: launch) {
                appeared += 1
                launch.whenReady { wired = $0 }
            })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let firstWindow = ContinuousClock.now - started

        // Laid out and drawn while the shell still sleeps: the canvas only.
        #expect(firstWindow < .milliseconds(500))
        #expect(launch.model == nil)
        #expect(host.frame.size == NSSize(width: 1000, height: 640))
        #expect(!holds(WindowCloseGuard.GuardView.self, host))
        #expect(await waitUntil { appeared == 1 })
        #expect(wired == nil)
        let canvas = Palette(theme: AppSettings.storedTheme()).canvasNSColor
        #expect(await waitUntil { window.backgroundColor == canvas })
        #expect(await waitUntil { launch.isSlow })
        #expect(launch.model == nil)

        // The probe passes its ceiling with no answer; the model comes anyway.
        let model = await ready(launch)
        #expect(await waitUntil { holds(WindowCloseGuard.GuardView.self, host) })
        #expect(wired === model)
        #expect(appeared == 1)
    }

    /// The window takes focus as a blocking launch's did: the first key view
    /// when the window shows, then the restored tab's terminal once the
    /// window is key. That holds too when the app was hidden or the window
    /// minimized or ordered out while the launch waited. A test window need
    /// not become key, so one that reports key stands in for it, with the
    /// notification AppKit posts.
    @Test(arguments: [false, true], [false, true])
    func theWindowFocusesAsABlockingLaunchDid(restoredTab: Bool, key: Bool) async throws {
        // The sidebar search leads the key view loop unless keyboard
        // navigation is on (as on the CI runners): then a control does.
        let shown: KeyboardFocus = NSApplication.shared.isFullKeyboardAccessEnabled ? .elsewhere : .sidebar
        let settled: KeyboardFocus = restoredTab ? .sessionTerminal : shown
        let expected = key ? [settled] : [shown, settled]
        for away in WindowAway.allCases {
            let blocking = try await startupFocus(
                waitsForShell: false, restoredTab: restoredTab, key: key, away: away, expecting: expected)
            let waiting = try await startupFocus(
                waitsForShell: true, restoredTab: restoredTab, key: key, away: away, expecting: expected)

            #expect(blocking == expected, "\(away)")
            #expect(waiting == blocking, "\(away)")
        }
    }

    /// Where the window is while the launch finishes.
    enum WindowAway: CaseIterable {
        case shown, appHidden, minimized, orderedOut
    }

    /// Shows the real window with the window's key state, sends it away,
    /// lets the launch finish, brings it back, and reads where focus lands;
    /// for a window that was not key, again once it becomes key.
    private func startupFocus(
        waitsForShell: Bool, restoredTab: Bool, key: Bool, away: WindowAway,
        expecting expected: [KeyboardFocus]
    ) async throws -> [KeyboardFocus] {
        let fixture = try ModelFixture(script: "#!/bin/sh\nread line\n")
        defer { fixture.cleanup() }
        if restoredTab {
            let cwd = try fixture.directory("project")
            try fixture.createSession(id: "restored", cwd: cwd)
            fixture.settings.openTabs = OpenTabsSnapshot(
                tabs: [.init(sessionID: "restored", cwd: cwd.path)],
                selectedSessionID: "restored",
                selectedCWD: cwd.path
            )
        }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        _ = NSApplication.shared
        let launch = AppLaunch(
            environment: waitsForShell ? [:] : ["GROK_HOME": fixture.grokHome.path],
            probe: { _ in
                gate.wait()
                return nil
            },
            adopt: { _ in },
            makeModel: { fixture.model() })
        let window = StandInKeyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: SigilApp.mainWindow(launch: launch) {})
        window.reportsKey = key
        window.orderFront(nil)
        if key { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window) }
        switch away {
        case .shown: break
        case .appHidden: NSApp.hide(nil)
        case .minimized: window.miniaturize(nil)
        case .orderedOut: window.orderOut(nil)
        }
        if away != .shown {
            window.reportsKey = false
            #expect(await waitUntil { !window.isVisible })
        }

        gate.signal()
        let model = await ready(launch)
        defer { model.closeAllTabsAndWait() }
        #expect(
            await waitUntil {
                restoredTab
                    ? model.selectedTab?.controller.view.window === window
                    : holds(WindowCloseGuard.GuardView.self, window.contentView!)
            })
        if away != .shown {
            try? await Task.sleep(for: .milliseconds(300))
            switch away {
            case .shown: break
            case .appHidden: NSApp.unhide(nil)
            case .minimized: window.deminiaturize(nil)
            case .orderedOut: window.orderFront(nil)
            }
            #expect(await waitUntil { window.isVisible })
            if key {
                window.reportsKey = true
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            }
        }
        func focus() -> KeyboardFocus {
            KeyboardFocus.classify(
                window.firstResponder, in: window,
                sessionView: model.selectedTab?.controller.view,
                panelShellView: model.panel.shell?.view,
                sidebarHasFocus: model.isSidebarFocused || model.isSidebarDividerFocused)
        }
        func settledFocus(_ want: KeyboardFocus) async -> KeyboardFocus {
            // Focus moves on the main queue's next turns; let them run, and
            // give a slow runner longer to land it.
            try? await Task.sleep(for: .milliseconds(300))
            _ = await waitUntil(timeout: .seconds(3)) { focus() == want }
            return focus()
        }
        var seen = [await settledFocus(expected[0])]
        if !key {
            window.reportsKey = true
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            seen.append(await settledFocus(expected[1]))
        }
        return seen
    }
}

/// A window that reports key when told to: the test process is not the
/// active app, and a locked screen keys no window at all.
private final class StandInKeyWindow: NSWindow {
    var reportsKey = false
    override var isKeyWindow: Bool { reportsKey }
}

/// True when `view`, or a view anywhere under it, is a `T`.
@MainActor
private func holds<T: NSView>(_ type: T.Type, _ view: NSView) -> Bool {
    view is T || view.subviews.contains { holds(type, $0) }
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
