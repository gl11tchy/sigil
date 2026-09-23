import AppKit
import Darwin
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@Suite(.serialized)
struct AppModelTests {

    @Test @MainActor
    func requestingAndCancellingAProviderDoesNotStartAProcess() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        fixture.settings.executablePath = "/missing/grok"
        let model = fixture.model()
        let folder = try fixture.directory("chosen folder")
        model.requestNewSession(in: folder)
        #expect(model.isShowingNewSessionSheet)
        #expect(model.pendingSessionDirectory == folder)
        #expect(model.tabs.isEmpty)
        model.isShowingNewSessionSheet = false
        #expect(model.tabs.isEmpty)
        #expect(fixture.settings.openTabs.tabs.isEmpty)
    }

    @Test(arguments: CLIProvider.allCases) @MainActor
    func providerSelectionStartsAnInteractivePTYInTheChosenFolder(provider: CLIProvider) async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let bin = try fixture.directory("bin with spaces")
        let folder = try fixture.directory("project 'quoted' ; literal")
        // A deterministic login shell prevents the developer's shell profile
        // from replacing this test's PATH with real, authenticated CLIs.
        let shell = bin.appendingPathComponent("zsh")
        try "#!/bin/sh\nshift\nexec /bin/sh -c \"$@\"\n".write(to: shell, atomically: true, encoding: .utf8)
        let cli = bin.appendingPathComponent(provider.command)
        try """
        #!/bin/sh
        printf 'PROVIDER=\(provider.rawValue)\\nCWD=%s\\nARGC=%s\\n' "$(/bin/pwd -P)" "$#"
        while IFS= read -r line; do printf 'REPLY=%s\\n' "$line"; done
        """.write(to: cli, atomically: true, encoding: .utf8)
        for file in [shell, cli] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let previousShell = ProcessInfo.processInfo.environment["SHELL"]
        let previousPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("SHELL", shell.path, 1)
        setenv("PATH", "\(bin.path):/usr/bin:/bin", 1)
        defer {
            if let previousShell { setenv("SHELL", previousShell, 1) } else { unsetenv("SHELL") }
            if let previousPath { setenv("PATH", previousPath, 1) } else { unsetenv("PATH") }
        }
        fixture.settings.executablePath = provider == .grokBuild ? cli.path : "/missing/grok"
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: folder, provider: provider))
        #expect(model.selectedTab?.id == tab.id)
        #expect(tab.spec.provider == provider)
        #expect(await waitUntil { tab.controller.bufferText().contains("PROVIDER=\(provider.rawValue)") })
        #expect(tab.controller.bufferText().contains("CWD=\(GrokPaths.canonicalPath(folder.path))"))
        #expect(tab.controller.bufferText().contains(provider == .grokBuild ? "ARGC=4" : "ARGC=0"))
        #expect(tab.controller.view.accessibilityLabel() == "\(provider.name) terminal")
        tab.controller.send(text: "provider-input\r")
        #expect(await waitUntil { tab.controller.bufferText().contains("REPLY=provider-input") })

        if provider != .grokBuild {
            #expect(tab.sessionID == nil)
            #expect(tab.spec.sessionDirectory == nil)
            #expect(fixture.settings.openTabs.tabs.isEmpty)
            #expect(!model.canExportSelectedTranscript)
            #expect(!tab.canDeliverBridgePrompt)
            fixture.settings.themeName = TerminalTheme.grokDay.name
            let pid = tab.controller.processID
            model.applyTheme()
            #expect(model.selectedTab?.id == tab.id)
            #expect(tab.controller.processID == pid)
            model.restartTab(id: tab.id)
            let restarted = try #require(model.selectedTab)
            #expect(restarted.spec.provider == provider)
            #expect(restarted.id != tab.id)
            #expect(await waitUntil { restarted.controller.bufferText().contains("PROVIDER=\(provider.rawValue)") })
            #expect(!tab.controller.isRunning)
        } else {
            #expect(fixture.settings.openTabs.tabs.count == 1)
        }
    }

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
    func restartingANeverCreatedNewSessionStaysNewAndPicksUpTheTheme() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let original = try #require(model.newTab(in: cwd, model: "grok-4", effort: "high"))
        let sessionID = try #require(original.sessionID)
        fixture.settings.themeName = TerminalTheme.grokDay.name

        model.restartTab(id: original.id)

        let restarted = try #require(model.tabs.first)
        #expect(restarted.sessionID == sessionID)
        guard case .new = restarted.spec.mode else {
            Issue.record("expected .new mode, got \(restarted.spec.mode)")
            return
        }
        #expect(restarted.spec.themeName == TerminalTheme.grokDay.grokThemeName)
        #expect(restarted.spec.model == original.spec.model)
        #expect(restarted.spec.reasoningEffort == original.spec.reasoningEffort)

        try fixture.createSession(id: sessionID, cwd: cwd)
        model.restartTab(id: restarted.id)

        let resumed = try #require(model.tabs.first)
        guard case .resume(let resumedID) = resumed.spec.mode else {
            Issue.record("expected .resume mode, got \(resumed.spec.mode)")
            return
        }
        #expect(resumedID == sessionID)
    }

    /// The Grok TUI reads GROK_THEME at process start. Recolouring SwiftTerm
    /// leaves the program inside the tab on the old palette.
    @Test @MainActor
    func changingTheWindowThemeRelaunchesGrokWithTheNewPalette() throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nexec /usr/bin/yes >/dev/null\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let original = try #require(model.newTab(in: cwd))
        let sessionID = try #require(original.sessionID)
        #expect(original.spec.themeName == TerminalTheme.sigilNeon.grokThemeName)

        fixture.settings.themeName = TerminalTheme.twitch.name
        model.applyTheme()

        let relaunched = try #require(model.tabs.first)
        #expect(relaunched.sessionID == sessionID)
        #expect(relaunched.spec.themeName == TerminalTheme.twitch.grokThemeName)
        #expect(relaunched.spec.themeVariables["GROK_THEME_BG"] == "0E0E10")
        #expect(relaunched.spec.themeVariables["GROK_THEME_ACCENT"] == "BF94FF")
        #expect(relaunched.id != original.id)
    }

    @Test @MainActor
    func changingThemeDoesNotKillATabThatIsStillWorking() throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nexec /usr/bin/yes >/dev/null\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let original = try #require(model.newTab(in: cwd))
        original.noteTurnStarted()
        #expect(original.shouldWarnBeforeStopping)
        let originalID = original.id

        fixture.settings.themeName = TerminalTheme.twitch.name
        model.applyTheme()

        let still = try #require(model.tabs.first)
        #expect(still.id == originalID)
        #expect(still.spec.themeName == TerminalTheme.sigilNeon.grokThemeName)
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

    @Test @MainActor
    func selectingATabWhileTheWindowIsInactiveKeepsAPendingFocus() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let first = try #require(model.newTab(in: cwd))
        let second = try #require(model.newTab(in: cwd))
        await flushMainAsync()
        model.needsTerminalFocus = false

        model.isFindBarVisible = true
        model.select(second.id)
        await flushMainAsync()
        #expect(!model.needsTerminalFocus)
        #expect(model.selectedTabID == second.id)

        model.isFindBarVisible = false
        model.select(first.id)
        await flushMainAsync()
        #expect(model.needsTerminalFocus)

        model.appDidBecomeActive()
        await flushMainAsync()
        #expect(model.needsTerminalFocus)

        model.windowDidBecomeKey()
        await flushMainAsync()
        #expect(model.needsTerminalFocus)
    }

    @Test @MainActor
    func readingAChatThenLeavingClearsItsUnreadDot() throws {
        _ = NSApplication.shared
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let first = try #require(model.newTab(in: cwd))
        let second = try #require(model.newTab(in: cwd))
        first.enqueueBridgePrompt("turn finished")

        #expect(first.hasUnseenActivity)
        #expect(
            SidebarActivityDot.isVisible(
                activity: first.activity,
                hasUnseenActivity: first.hasUnseenActivity,
                isActive: false
            )
        )

        model.select(first.id)
        #expect(!first.hasUnseenActivity)
        #expect(
            !SidebarActivityDot.isVisible(
                activity: first.activity,
                hasUnseenActivity: first.hasUnseenActivity,
                isActive: true
            )
        )

        model.select(second.id)
        #expect(!first.hasUnseenActivity)
        #expect(
            !SidebarActivityDot.isVisible(
                activity: first.activity,
                hasUnseenActivity: first.hasUnseenActivity,
                isActive: false
            )
        )
    }

    @Test @MainActor
    func newTabTrimsWhitespaceInModelAndEffort() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let trimmed = try #require(model.newTab(in: cwd, model: "  grok-4.6  ", effort: " high "))
        #expect(trimmed.spec.model == "grok-4.6")
        #expect(trimmed.spec.reasoningEffort == "high")

        let blank = try #require(model.newTab(in: cwd, model: "   ", effort: " \t "))
        #expect(blank.spec.model == nil)
        #expect(blank.spec.reasoningEffort == nil)
    }

    @Test
    func repeatedFastExportsFinishWithoutBlocking() async throws {
        let root = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try makeExecutable(
            in: root,
            body: """
                #!/bin/sh
                printf 'body-%s' "$2" > "$3"
                """
        )
        for index in 1...8 {
            let output = root.appendingPathComponent("Transcript-\(index).md")
            try await AppModel.runTranscriptExport(
                executable: script,
                sessionID: "session-\(index)",
                output: output,
                workingDirectory: root,
                timeout: .seconds(2)
            )
            #expect(try String(contentsOf: output, encoding: .utf8) == "body-session-\(index)")
        }
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

        #expect(!model.remoteControl.isEnabled)
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
    func canonicalPathCacheSurvivesANewerSessionTimestamp() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let counter = ResolverCounter()
        let model = fixture.model(canonicalPath: counter.wrap)
        defer { model.closeAllTabsAndWait() }

        try fixture.writeListedSession(
            id: "session-1",
            cwd: "/Users/someone/Documents/sigil",
            updatedAt: "2026-08-01T00:00:00Z"
        )
        await fixture.store.reload()
        let first = try #require(model.store.sessions.first)
        _ = model.sessionKey(first)
        let afterWarm = counter.count
        #expect(afterWarm > 0)

        try fixture.writeListedSession(
            id: "session-1",
            cwd: "/Users/someone/Documents/sigil",
            updatedAt: "2026-08-02T00:00:00Z"
        )
        await fixture.store.reload()
        let updated = try #require(model.store.sessions.first)
        _ = model.sessionKey(updated)
        #expect(counter.count == afterWarm)
    }

    @Test @MainActor
    func sidebarHidesWorktreeSessionsUntilEnabled() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "proj-session", cwd: "/Users/someone/Documents/sigil")
        try fixture.writeListedSession(
            id: "wt-session",
            cwd: "/Users/someone/Documents/sigil/.claude/worktrees/chunk"
        )
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        #expect(model.sidebarSessions.map(\.id) == ["proj-session"])

        model.settings.showWorktreeSessions = true
        #expect(Set(model.sidebarSessions.map(\.id)) == ["proj-session", "wt-session"])
    }

    @Test @MainActor
    func sidebarKeepsAnOpenWorktreeSessionVisible() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let worktree = try fixture.directory("agent-wt")
        try fixture.writeListedSession(id: "open-wt", cwd: worktree.path)
        try fixture.writeListedSession(
            id: "closed-wt", cwd: "/Users/someone/.t3/worktrees/other")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let open = try #require(fixture.store.sessions.first { $0.id == "open-wt" })
        model.open(open)

        #expect(Set(model.sidebarSessions.map(\.id)) == ["open-wt"])
        #expect(!model.sidebarSessions.contains { $0.id == "closed-wt" })
    }

    /// A remount of the sidebar (⌘B) must not refocus Search for an old ⌘⇧F.
    @Test @MainActor
    func searchFocusRequestIsConsumedOnce() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        #expect(!model.consumeSearchFocusRequest())

        model.focusSidebarSearch()

        #expect(model.consumeSearchFocusRequest())
        #expect(!model.consumeSearchFocusRequest())
    }

    @Test @MainActor
    func sidebarHidesSubagentSessionsUntilEnabled() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(id: "parent", cwd: "/Users/someone/Documents/peptide")
        try fixture.writeListedSession(
            id: "child",
            cwd: "/Users/someone/Documents/peptide",
            summary: "Verify sticky nav",
            sessionKind: "subagent"
        )
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        #expect(model.sidebarSessions.map(\.id) == ["parent"])

        model.settings.showSubagentSessions = true
        #expect(Set(model.sidebarSessions.map(\.id)) == ["parent", "child"])
    }

    @Test @MainActor
    func sidebarKeepsAnOpenSubagentSessionVisible() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
            .appendingPathComponent("Sigil-SubagentSidebar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        try fixture.writeListedSession(
            id: "open-child", cwd: cwd.path, sessionKind: "subagent")
        try fixture.writeListedSession(
            id: "closed-child", cwd: cwd.path, sessionKind: "subagent")
        try fixture.writeListedSession(id: "parent", cwd: cwd.path)
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let open = try #require(fixture.store.sessions.first { $0.id == "open-child" })
        model.open(open)

        #expect(Set(model.sidebarSessions.map(\.id)) == ["open-child", "parent"])
        #expect(!model.sidebarSessions.contains { $0.id == "closed-child" })
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

    @Test @MainActor
    func projectPinToggleIsIndependentOfChatPins() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let session = makeSession(id: "s1", cwd: cwd)
        let model = fixture.model(trashConversation: { _ in })
        defer { model.closeAllTabsAndWait() }
        let project = SidebarProject(
            id: cwd.path,
            name: "project",
            displayPath: cwd.path,
            cwd: cwd.path,
            sessions: [session],
            updatedAt: session.updatedAt
        )

        #expect(!model.isPinned(project))
        model.pin(project)
        #expect(model.isPinned(project))
        #expect(!model.isPinned(session))
        #expect(fixture.settings.pinnedProjects == [cwd.path])
        model.togglePin(project)
        #expect(!model.isPinned(project))
        model.togglePin(project)
        #expect(model.deleteConversation(session))
        #expect(!model.isPinned(project))
        #expect(fixture.settings.pinnedProjects.isEmpty)
    }

    @Test @MainActor
    func projectPinsKeepNewestFirstAcrossFolders() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(id: "a", cwd: "/Users/someone/Documents/alpha")
        try fixture.writeListedSession(id: "b", cwd: "/Users/someone/Documents/beta")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let alpha = try #require(model.sidebarProjects.first { $0.name == "alpha" })
        let beta = try #require(model.sidebarProjects.first { $0.name == "beta" })

        model.pin(alpha)
        model.pin(beta)
        #expect(model.pinnedProjects().map(\.name) == ["beta", "alpha"])
        #expect(model.unpinnedProjects().isEmpty)

        model.pin(alpha)
        #expect(model.pinnedProjects().map(\.name) == ["alpha", "beta"])
    }

    @Test @MainActor
    func pruneDropsProjectPinsForMissingFolders() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(id: "gone", cwd: "/Users/someone/Documents/project")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first)
        model.pin(project)
        let session = try #require(fixture.store.sessions.first { $0.id == "gone" })
        try FileManager.default.removeItem(at: session.directory)
        await fixture.store.reload()
        model.pruneMissingPins()
        #expect(fixture.settings.pinnedProjects.isEmpty)
    }

    @Test @MainActor
    func deletingOneChatKeepsTheProjectPin() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(id: "keep", cwd: "/Users/someone/Documents/project")
        try fixture.writeListedSession(id: "drop", cwd: "/Users/someone/Documents/project")
        await fixture.store.reload()

        let model = fixture.model(trashConversation: { _ in })
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first)
        model.pin(project)
        let drop = try #require(fixture.store.sessions.first { $0.id == "drop" })
        #expect(model.deleteConversation(drop))
        #expect(model.isPinned(project))
        #expect(fixture.settings.pinnedProjects == [project.cwd])
    }

    @Test @MainActor
    func archivingEveryChatKeepsTheProjectPin() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(id: "only", cwd: "/Users/someone/Documents/kept")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first)
        model.pin(project)
        let session = try #require(fixture.store.sessions.first)
        model.archive(session)
        #expect(model.sidebarProjects.isEmpty)
        #expect(fixture.settings.pinnedProjects == [project.cwd])
        model.unarchive(session)
        #expect(model.pinnedProjects().map(\.name) == ["kept"])
    }

    @Test @MainActor
    func customNameShowsInTitleAndSearch() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)

        #expect(model.title(for: session) == "CLI summary")
        model.rename(session, to: "Auth rewrite")
        #expect(model.title(for: session) == "Auth rewrite")
        #expect(model.hasCustomName(session))

        model.searchText = "Auth"
        #expect(model.sidebarSessions.map(\.id) == ["s1"])
        model.searchText = "rewrite"
        #expect(model.sidebarSessions.map(\.id) == ["s1"])
        model.searchText = "no-such-name"
        #expect(model.sidebarSessions.isEmpty)
    }

    @Test @MainActor
    func customNamePersistsAcrossRelaunch() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")

        let relaunchedSettings = AppSettings(defaults: fixture.defaults)
        relaunchedSettings.executablePath = fixture.executable.path
        let relaunched = AppModel(
            settings: relaunchedSettings,
            store: fixture.store,
            trashConversation: { _ in },
            presentError: { _ in }
        )
        defer { relaunched.closeAllTabsAndWait() }
        let again = try #require(relaunched.store.sessions.first)
        #expect(relaunched.title(for: again) == "Auth rewrite")
        #expect(relaunched.hasCustomName(again))
        relaunched.searchText = "Auth"
        #expect(relaunched.sidebarSessions.map(\.id) == ["s1"])
    }

    @Test @MainActor
    func customNameSurvivesCLISummaryRewrite() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")

        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Totally new CLI summary")
        await fixture.store.reload()

        let rewritten = try #require(model.store.sessions.first)
        #expect(rewritten.summary == "Totally new CLI summary")
        #expect(rewritten.title == "Totally new CLI summary")
        #expect(model.title(for: rewritten) == "Auth rewrite")
        model.searchText = "Auth"
        #expect(model.sidebarSessions.map(\.id) == ["s1"])
    }

    @Test @MainActor
    func resetNameRestoresCLISummary() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        let namedData = try #require(fixture.defaults.data(forKey: "sidebar.conversationNames"))
        model.resetName(session)
        #expect(model.title(for: session) == "CLI summary")
        #expect(!model.hasCustomName(session))
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(fixture.defaults.data(forKey: "sidebar.conversationNames") != namedData)
    }

    @Test @MainActor
    func resetNameUsesTheLiveStoreSessionForOpenTabs() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: cwd.path, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let stale = try #require(model.store.sessions.first)
        model.rename(stale, to: "Auth rewrite")
        model.open(stale)
        let tab = try #require(model.selectedTab)
        #expect(tab.sessionTitle == "Auth rewrite")

        try fixture.writeListedSession(id: "s1", cwd: cwd.path, summary: "Totally new CLI summary")
        await fixture.store.reload()
        let live = try #require(model.store.sessions.first)
        #expect(stale.title == "CLI summary")
        #expect(live.title == "Totally new CLI summary")

        model.resetName(stale)
        #expect(!model.hasCustomName(stale))
        #expect(model.title(for: live) == "Totally new CLI summary")
        #expect(tab.sessionTitle == "Totally new CLI summary")
    }

    @Test @MainActor
    func whitespaceRenameClearsTheCustomName() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        model.rename(session, to: "  \n\t ")
        #expect(model.title(for: session) == "CLI summary")
        #expect(!model.hasCustomName(session))

        model.rename(session, to: "Auth rewrite")
        model.rename(session, to: "")
        #expect(model.title(for: session) == "CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)
    }

    @Test @MainActor
    func customNameIsTheTabLabel() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: cwd.path, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        model.open(session)
        let tab = try #require(model.selectedTab)
        #expect(model.title(for: tab) == "Auth rewrite")
    }

    @Test @MainActor
    func namedEmptySessionStaysListed() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "", messages: 0)
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        #expect(model.sidebarSessions.isEmpty)

        model.rename(session, to: "Keep me")
        #expect(model.sidebarSessions.map(\.id) == ["s1"])
        #expect(model.title(for: session) == "Keep me")
    }

    @Test @MainActor
    func resetNameOnOpenEmptySessionKeepsUntitledTabTitle() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: cwd.path, summary: "", messages: 0)
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.open(session)
        let tab = try #require(model.selectedTab)
        let untitled = "Untitled session in project"
        #expect(model.title(for: session) == untitled)
        #expect(tab.sessionTitle == untitled)
        #expect(model.sidebarSessions.map(\.id) == ["s1"])

        model.rename(session, to: "Keep me")
        #expect(tab.sessionTitle == "Keep me")
        #expect(model.title(for: tab) == "Keep me")
        model.resetName(session)
        #expect(!model.hasCustomName(session))
        #expect(model.title(for: session) == untitled)
        #expect(tab.sessionTitle == untitled)
        #expect(model.title(for: tab) == untitled)
        #expect(tab.title == untitled)
        #expect(model.sidebarSessions.map(\.id) == ["s1"])
    }

    @Test @MainActor
    func blankClearOnOpenEmptySessionKeepsUntitledTabTitle() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: cwd.path, summary: "", messages: 0)
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.open(session)
        let tab = try #require(model.selectedTab)
        let untitled = "Untitled session in project"
        model.rename(session, to: "Keep me")
        model.rename(session, to: "")
        #expect(!model.hasCustomName(session))
        #expect(model.title(for: session) == untitled)
        #expect(tab.sessionTitle == untitled)
        #expect(model.title(for: tab) == untitled)
        #expect(tab.title == untitled)
        #expect(model.sidebarSessions.map(\.id) == ["s1"])
    }

    @Test @MainActor
    func deletingAConversationDropsItsName() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model(trashConversation: { _ in })
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        #expect(model.deleteConversation(session))
        #expect(fixture.settings.conversationNames.isEmpty)
    }

    @Test @MainActor
    func namesDoNotCollideAcrossCopiedSessionIDs() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "same", cwd: "/Users/someone/Documents/one", summary: "One")
        try fixture.writeListedSession(
            id: "same", cwd: "/Users/someone/Documents/two", summary: "Two")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let one = try #require(model.store.sessions.first { $0.cwd.hasSuffix("/one") })
        let two = try #require(model.store.sessions.first { $0.cwd.hasSuffix("/two") })
        model.rename(one, to: "Alpha")
        #expect(model.title(for: one) == "Alpha")
        #expect(model.title(for: two) == "Two")
    }

    @Test @MainActor
    func renamingToCLITitleDoesNotPinAnOverlay() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        #expect(
            !AppModel.shouldPersistConversationNames(
                next: fixture.settings.conversationNames,
                current: fixture.settings.conversationNames))
        let namesBefore = fixture.defaults.data(forKey: "sidebar.conversationNames")
        model.rename(session, to: "CLI summary")
        #expect(!model.hasCustomName(session))
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(fixture.defaults.data(forKey: "sidebar.conversationNames") == namesBefore)

        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Totally new CLI summary")
        await fixture.store.reload()
        let rewritten = try #require(model.store.sessions.first)
        #expect(model.title(for: rewritten) == "Totally new CLI summary")
    }

    @Test @MainActor
    func finderNoOpRenameDoesNotPersistUnchangedConversationNames() {
        let empty: [ConversationName] = []
        #expect(!AppModel.shouldPersistConversationNames(next: empty, current: empty))
        let named = [
            ConversationName(sessionID: "s1", cwd: "/tmp/project", name: "Auth rewrite")
        ]
        #expect(AppModel.shouldPersistConversationNames(next: named, current: empty))
        #expect(AppModel.shouldPersistConversationNames(next: empty, current: named))
        #expect(!AppModel.shouldPersistConversationNames(next: named, current: named))
        #expect(AppModel.shouldNoOpRenameCommit(draft: "CLI summary", baseline: "CLI summary"))
        #expect(!AppModel.shouldNoOpRenameCommit(draft: "Typed", baseline: "CLI summary"))
        #expect(!AppModel.shouldNoOpRenameCommit(draft: "CLI summary", baseline: nil))
    }

    @Test @MainActor
    func resetNameWithoutOverlayDoesNotPersistConversationNames() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "s1", cwd: cwd.path, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.open(session)
        let tab = try #require(model.selectedTab)
        let titleBefore = tab.sessionTitle
        #expect(fixture.settings.conversationNames.isEmpty)
        let namesBefore = fixture.defaults.data(forKey: "sidebar.conversationNames")
        model.resetName(session)
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(fixture.defaults.data(forKey: "sidebar.conversationNames") == namesBefore)
        #expect(tab.sessionTitle == titleBefore)
        #expect(model.title(for: session) == "CLI summary")
    }

    @Test @MainActor
    func deletingAConversationWithoutANameDoesNotPersistConversationNames() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model(trashConversation: { _ in })
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        #expect(fixture.settings.conversationNames.isEmpty)
        let namesBefore = fixture.defaults.data(forKey: "sidebar.conversationNames")
        #expect(model.deleteConversation(session))
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(fixture.defaults.data(forKey: "sidebar.conversationNames") == namesBefore)
    }

    @Test @MainActor
    func renamingBackToCLITitleClearsTheOverlay() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        model.rename(session, to: "CLI summary")
        #expect(!model.hasCustomName(session))
        #expect(model.title(for: session) == "CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)
    }

    @Test @MainActor
    func commitRenameAfterCancelStillSavesTheCapturedSession() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        #expect(model.renamingSessionKey == model.sessionKey(session))

        // SwiftUI often runs the alert's isPresented setter (cancel) before
        // the Rename button action. The view commits the captured session.
        let captured = session
        model.cancelRename()
        #expect(model.renamingSessionKey == nil)
        model.commitRename(captured, to: "Auth rewrite")
        #expect(model.title(for: session) == "Auth rewrite")
        #expect(model.hasCustomName(session))
        #expect(model.renamingSessionKey == nil)
    }

    @Test @MainActor
    func dismissAfterCommitDoesNotClearASavedName() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.commitRename(session, to: "Auth rewrite")
        model.cancelRename()
        #expect(model.title(for: session) == "Auth rewrite")
        #expect(model.hasCustomName(session))
    }

    @Test @MainActor
    func renameAlertCancelOnDismissOnlyWhenUncommitted() {
        #expect(AppModel.shouldCancelRenameAlert(didCommit: false))
        #expect(!AppModel.shouldCancelRenameAlert(didCommit: true))
    }

    @Test @MainActor
    func renameSurfaceFollowsVisibilityIndependentOfTheKey() {
        #expect(
            AppModel.renameSurface(isRenaming: false, sessionAvailable: true, rowVisible: true)
                == AppModel.RenameSurface.none)
        #expect(
            AppModel.renameSurface(isRenaming: true, sessionAvailable: false, rowVisible: false)
                == AppModel.RenameSurface.none)
        #expect(
            AppModel.renameSurface(isRenaming: true, sessionAvailable: true, rowVisible: true)
                == .inline)
        #expect(
            AppModel.renameSurface(isRenaming: true, sessionAvailable: true, rowVisible: false)
                == .prompt)
        #expect(
            AppModel.renameSurface(isRenaming: true, sessionAvailable: true, rowVisible: true)
                == .inline)
    }

    @Test @MainActor
    func inlineCommitAfterResetDoesNotRestoreTheOverlay() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        model.beginRename(session)
        model.resetName(session)
        #expect(model.renamingSessionKey == nil)
        model.commitInlineRename(session, to: "Auth rewrite")
        #expect(!model.hasCustomName(session))
        #expect(model.title(for: session) == "CLI summary")
    }

    @Test @MainActor
    func inlineCommitAfterCancelDoesNotWrite() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.cancelRename()
        model.commitInlineRename(session, to: "Auth rewrite")
        #expect(!model.hasCustomName(session))
        #expect(fixture.settings.conversationNames.isEmpty)
    }

    @Test @MainActor
    func inlineCommitOnAnotherRowDoesNotWriteTheOldRow() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "one", cwd: "/Users/someone/Documents/project", summary: "One")
        try fixture.writeListedSession(
            id: "two", cwd: "/Users/someone/Documents/project", summary: "Two")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let one = try #require(model.store.sessions.first { $0.id == "one" })
        let two = try #require(model.store.sessions.first { $0.id == "two" })
        model.beginRename(one)
        model.beginRename(two)
        model.commitInlineRename(one, to: "Old")
        #expect(!model.hasCustomName(one))
        #expect(model.renamingSessionKey == model.sessionKey(two))
        model.commitInlineRename(two, to: "Keep me")
        #expect(model.title(for: two) == "Keep me")
        #expect(model.title(for: one) == "One")
    }

    @Test @MainActor
    func renameIsNotReconfiguredWhenSurfaceAndKeyAreUnchanged() {
        #expect(
            !AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .prompt,
                nextKey: "s1",
                nextSurface: .prompt,
                forceReconfigure: false
            ))
        #expect(
            !AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .inline,
                nextKey: "s1",
                nextSurface: .inline,
                forceReconfigure: false
            ))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .prompt,
                nextKey: "s1",
                nextSurface: .inline,
                forceReconfigure: false
            ))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .inline,
                nextKey: "s1",
                nextSurface: .prompt,
                forceReconfigure: false
            ))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .prompt,
                nextKey: "s2",
                nextSurface: .prompt,
                forceReconfigure: false
            ))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .prompt,
                nextKey: "s1",
                nextSurface: .prompt,
                forceReconfigure: true
            ))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: "s1",
                previousSurface: .prompt,
                nextKey: "s1",
                nextSurface: .prompt,
                forceReconfigure: false,
                forceRepresent: true
            ))
        #expect(AppModel.shouldInvalidatePreparedRenameOnBegin())
        #expect(
            AppModel.shouldRepresentRenamePromptOnSameKeyBegin(
                isFreshKey: false, showRenameAlert: false, preparedSurface: .prompt))
        #expect(
            !AppModel.shouldRepresentRenamePromptOnSameKeyBegin(
                isFreshKey: false, showRenameAlert: true, preparedSurface: .prompt))
        #expect(
            !AppModel.shouldRepresentRenamePromptOnSameKeyBegin(
                isFreshKey: false, showRenameAlert: false, preparedSurface: .inline))
        #expect(
            !AppModel.shouldRepresentRenamePromptOnSameKeyBegin(
                isFreshKey: false, showRenameAlert: false, preparedSurface: .none))
        #expect(
            !AppModel.shouldRepresentRenamePromptOnSameKeyBegin(
                isFreshKey: true, showRenameAlert: false, preparedSurface: .prompt))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: nil,
                previousSurface: .none,
                nextKey: "s1",
                nextSurface: .prompt,
                forceReconfigure: true
            ))
    }

    @Test @MainActor
    func inlineHandoffAfterYieldRequiresLiveInlineSurface() {
        #expect(
            AppModel.shouldFinishInlineHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: "s1",
                currentSurface: .inline
            ))
        #expect(
            !AppModel.shouldFinishInlineHandoff(
                isCancelled: true,
                expectedKey: "s1",
                currentKey: "s1",
                currentSurface: .inline
            ))
        #expect(
            !AppModel.shouldFinishInlineHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: nil,
                currentSurface: .none
            ))
        #expect(
            !AppModel.shouldFinishInlineHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: "s1",
                currentSurface: .prompt
            ))
        #expect(
            !AppModel.shouldFinishInlineHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: "s2",
                currentSurface: .inline
            ))
    }

    @Test @MainActor
    func promptHandoffAfterPulseYieldRequiresLivePromptSurface() {
        #expect(
            AppModel.shouldFinishPromptHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: "s1",
                currentSurface: .prompt
            ))
        #expect(
            !AppModel.shouldFinishPromptHandoff(
                isCancelled: true,
                expectedKey: "s1",
                currentKey: "s1",
                currentSurface: .prompt
            ))
        #expect(
            !AppModel.shouldFinishPromptHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: nil,
                currentSurface: .none
            ))
        #expect(
            !AppModel.shouldFinishPromptHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: "s1",
                currentSurface: .inline
            ))
        #expect(
            !AppModel.shouldFinishPromptHandoff(
                isCancelled: false,
                expectedKey: "s1",
                currentKey: "s2",
                currentSurface: .prompt
            ))
        #expect(
            !AppModel.shouldFinishPromptHandoff(
                isCancelled: false,
                expectedKey: nil,
                currentKey: nil,
                currentSurface: .prompt
            ))
    }

    @Test @MainActor
    func alertSelectAllAfterYieldRequiresTheSamePromptKey() {
        #expect(
            AppModel.shouldConsumeRenameAlertSelectAll(
                expectedKey: "s1", currentKey: "s1", currentSurface: .prompt,
                selectAllPending: true, isCancelled: false, forceRepresent: false))
        #expect(
            !AppModel.shouldConsumeRenameAlertSelectAll(
                expectedKey: "s1", currentKey: "s2", currentSurface: .prompt,
                selectAllPending: true, isCancelled: false, forceRepresent: false))
        #expect(
            !AppModel.shouldConsumeRenameAlertSelectAll(
                expectedKey: "s1", currentKey: "s1", currentSurface: .inline,
                selectAllPending: true, isCancelled: false, forceRepresent: false))
        #expect(
            !AppModel.shouldConsumeRenameAlertSelectAll(
                expectedKey: "s1", currentKey: "s1", currentSurface: .prompt,
                selectAllPending: true, isCancelled: true, forceRepresent: false))
        #expect(
            !AppModel.shouldConsumeRenameAlertSelectAll(
                expectedKey: "s1", currentKey: "s1", currentSurface: .prompt,
                selectAllPending: true, isCancelled: false, forceRepresent: true))
        #expect(
            !AppModel.shouldConsumeRenameAlertSelectAll(
                expectedKey: "s1", currentKey: "s1", currentSurface: .prompt,
                selectAllPending: false, isCancelled: false, forceRepresent: false))
        #expect(
            AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: true, selectAllPending: true))
        #expect(
            !AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: false, selectAllPending: true))
        #expect(
            !AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: true, selectAllPending: false))
        #expect(
            !AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: false, selectAllPending: false))
    }

    @Test @MainActor
    func renameSelectAllRequiresTheRenameFieldEditorAsFirstResponder() {
        #expect(
            AppModel.isRenameFieldEditorReady(
                fieldEditorExists: true, fieldEditorIsFirstResponder: true,
                isEditingRenameField: true))
        #expect(
            !AppModel.isRenameFieldEditorReady(
                fieldEditorExists: true, fieldEditorIsFirstResponder: false,
                isEditingRenameField: true))
        #expect(
            !AppModel.isRenameFieldEditorReady(
                fieldEditorExists: true, fieldEditorIsFirstResponder: true,
                isEditingRenameField: false))
        #expect(
            !AppModel.isRenameFieldEditorReady(
                fieldEditorExists: false, fieldEditorIsFirstResponder: false,
                isEditingRenameField: true))
        #expect(
            !AppModel.isRenameFieldEditorReady(
                fieldEditorExists: false, fieldEditorIsFirstResponder: true,
                isEditingRenameField: true))
        #expect(
            !AppModel.isRenameFieldEditorReady(
                fieldEditorExists: true, fieldEditorIsFirstResponder: false,
                isEditingRenameField: false))

        #expect(
            !AppModel.isEditingRenameAlertField(
                hasKeyWindow: true, keyWindowIsMain: true, keyWindowIsSheet: false,
                editorStringMatchesDraft: true))
        #expect(
            AppModel.isEditingRenameAlertField(
                hasKeyWindow: true, keyWindowIsMain: false, keyWindowIsSheet: false,
                editorStringMatchesDraft: true))
        #expect(
            AppModel.isEditingRenameAlertField(
                hasKeyWindow: true, keyWindowIsMain: true, keyWindowIsSheet: true,
                editorStringMatchesDraft: true))
        #expect(
            !AppModel.isEditingRenameAlertField(
                hasKeyWindow: true, keyWindowIsMain: false, keyWindowIsSheet: false,
                editorStringMatchesDraft: false))
        #expect(
            !AppModel.isEditingRenameAlertField(
                hasKeyWindow: false, keyWindowIsMain: false, keyWindowIsSheet: false,
                editorStringMatchesDraft: true))
        #expect(
            !AppModel.isEditingRenameAlertField(
                hasKeyWindow: true, keyWindowIsMain: false, keyWindowIsSheet: true,
                editorStringMatchesDraft: false))

        #expect(
            !AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: AppModel.isRenameFieldEditorReady(
                    fieldEditorExists: true, fieldEditorIsFirstResponder: false,
                    isEditingRenameField: true),
                selectAllPending: true))
        #expect(
            AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: AppModel.isRenameFieldEditorReady(
                    fieldEditorExists: true, fieldEditorIsFirstResponder: true,
                    isEditingRenameField: true),
                selectAllPending: true))
        #expect(!AppModel.shouldSuppressBlurCommitDuringRenameSelectAllWait())
        #expect(AppModel.renameSelectAllRetryInterval == .milliseconds(16))
        #expect(AppModel.renameSelectAllRetryTimeout == .milliseconds(400))
        #expect(AppModel.shouldContinueRenameSelectAllRetry(elapsed: .zero))
        #expect(AppModel.shouldContinueRenameSelectAllRetry(elapsed: .milliseconds(16)))
        #expect(AppModel.shouldContinueRenameSelectAllRetry(elapsed: .milliseconds(399)))
        #expect(!AppModel.shouldContinueRenameSelectAllRetry(elapsed: .milliseconds(400)))
        #expect(!AppModel.shouldContinueRenameSelectAllRetry(elapsed: .seconds(2)))
        #expect(AppModel.renameSelectAllRetryInterval < AppModel.renameSelectAllRetryTimeout)
        #expect(AppModel.shouldClearRenameSelectAllOnRetryTimeout())
        #expect(!AppModel.shouldSelectRenameDraftOnRetryTimeout())
        #expect(
            !AppModel.shouldConsumeRenameSelectAll(
                fieldEditorReady: AppModel.shouldSelectRenameDraftOnRetryTimeout(),
                selectAllPending: true))
    }

    @Test @MainActor
    func renameFocusAfterYieldRequiresActiveUncancelledRow() {
        #expect(
            AppModel.shouldStealRenameFocusAfterYield(isCancelled: false, isRenaming: true))
        #expect(
            !AppModel.shouldStealRenameFocusAfterYield(isCancelled: true, isRenaming: true))
        #expect(
            !AppModel.shouldStealRenameFocusAfterYield(isCancelled: false, isRenaming: false))
        #expect(
            !AppModel.shouldStealRenameFocusAfterYield(isCancelled: true, isRenaming: false))
        #expect(AppModel.shouldClearBlurSuppressionAfterCommitOrAbandon())
        #expect(
            AppModel.shouldCommitRenameIfFocusStealMissed(
                isRenaming: true, focusIsRename: false))
        #expect(
            !AppModel.shouldCommitRenameIfFocusStealMissed(
                isRenaming: true, focusIsRename: true))
        #expect(
            !AppModel.shouldCommitRenameIfFocusStealMissed(
                isRenaming: false, focusIsRename: false))
        #expect(
            !AppModel.shouldCommitRenameIfFocusStealMissed(
                isRenaming: false, focusIsRename: true))
        #expect(AppModel.shouldCommitInlineBlurAfterYield(focusIsRename: false))
        #expect(!AppModel.shouldCommitInlineBlurAfterYield(focusIsRename: true))
        #expect(AppModel.shouldCancelPendingBlurCommit(focusIsRename: true))
        #expect(!AppModel.shouldCancelPendingBlurCommit(focusIsRename: false))
    }

    @Test @MainActor
    func renameFocusStealMissWaitsForFieldReadinessBeforeBlurCommit() {
        // Keyboard: editor already ready after the steal — select-all, no wait.
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: true, focusIsRename: true,
                isCancelled: false, isRenaming: true, elapsed: .zero) == .selectAll)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: true, focusIsRename: false,
                isCancelled: false, isRenaming: true, elapsed: .zero) == .selectAll)

        // FocusState landed on a later turn — fall through to select-all.
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: true,
                isCancelled: false, isRenaming: true, elapsed: .milliseconds(16))
                == .selectAll)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: true,
                isCancelled: false, isRenaming: true,
                elapsed: AppModel.renameSelectAllRetryTimeout) == .selectAll)

        // Two yields / short elapsed, focus still off — wait, do not miss.
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: false, isRenaming: true, elapsed: .zero) == .wait)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: false, isRenaming: true, elapsed: .milliseconds(16))
                == .wait)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: false, isRenaming: true, elapsed: .milliseconds(399))
                == .wait)

        // Same timeout as select-all: still renaming, focus off → blur-commit.
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: false, isRenaming: true,
                elapsed: AppModel.renameSelectAllRetryTimeout) == .miss)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: false, isRenaming: true, elapsed: .seconds(2))
                == .miss)
        #expect(
            AppModel.shouldCommitRenameIfFocusStealMissed(
                isRenaming: true, focusIsRename: false))

        // Timeout is not a miss if the row ended or the task was cancelled.
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: true, isRenaming: true, elapsed: .milliseconds(400))
                == .abort)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: false, isRenaming: false, elapsed: .milliseconds(400))
                == .abort)
        #expect(
            AppModel.renameFocusStealFollowUp(
                fieldEditorReady: false, focusIsRename: false,
                isCancelled: true, isRenaming: true, elapsed: .zero) == .abort)
    }

    @Test @MainActor
    func inlineBlurCommitsOnlyWhenKeyMatchesAndRowIsVisible() {
        #expect(
            AppModel.shouldCommitInlineBlur(
                keyMatches: true, rowVisible: true, sidebarVisible: true, fieldMounted: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCommitInlineBlur(
                keyMatches: true, rowVisible: false, sidebarVisible: true, fieldMounted: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCommitInlineBlur(
                keyMatches: false, rowVisible: true, sidebarVisible: true, fieldMounted: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCommitInlineBlur(
                keyMatches: false, rowVisible: false, sidebarVisible: true, fieldMounted: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCommitInlineBlur(
                keyMatches: true, rowVisible: true, sidebarVisible: false, fieldMounted: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCommitInlineBlur(
                keyMatches: true, rowVisible: true, sidebarVisible: true, fieldMounted: false,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCommitInlineBlur(
                keyMatches: true, rowVisible: true, sidebarVisible: true, fieldMounted: true,
                expectedGeneration: 1, currentGeneration: 2))
    }

    @Test @MainActor
    func inlineBlurAfterTheRowLeavesTheListDoesNotPersistOrClearTheKey() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.searchText = "no-such-name"
        #expect(model.sidebarSessions.isEmpty)
        #expect(model.renamingSessionKey == model.sessionKey(session))
        model.commitInlineBlur(
            session, to: "Auth rewrite", mountGeneration: model.renameFieldMountGeneration)
        #expect(!model.hasCustomName(session))
        #expect(model.renamingSessionKey == model.sessionKey(session))
        #expect(model.title(for: session) == "CLI summary")
        model.commitRename(session, to: "Auth rewrite")
        #expect(model.title(for: session) == "Auth rewrite")
    }

    @Test @MainActor
    func inlineBlurWhileVisibleStillWrites() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.noteRenameFieldMounted(true, key: model.sessionKey(session))
        model.commitInlineBlur(
            session, to: "Auth rewrite", mountGeneration: model.renameFieldMountGeneration)
        #expect(model.title(for: session) == "Auth rewrite")
        #expect(model.renamingSessionKey == nil)
    }

    @Test @MainActor
    func capturedRenameCommitsTheDraftEvenIfCancelWipesItFirst() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        model.beginRename(session)
        model.renameDraft = "Keep this"
        model.commitCapturedRename(session)
        #expect(model.title(for: session) == "Keep this")

        model.rename(session, to: "Auth rewrite")
        model.beginRename(session)
        model.renameDraft = "Keep this"
        let snapshot = model.renameDraft
        model.cancelRename()
        #expect(model.renameDraft.isEmpty)
        model.commitRename(session, to: snapshot)
        #expect(model.title(for: session) == "Keep this")
    }

    @Test @MainActor
    func capturedRenameUsesTheLiveStoreSessionNotTheAlertSnapshot() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let stale = try #require(model.store.sessions.first)
        model.beginRename(stale)
        model.renameAlertSession = stale
        #expect(stale.title == "CLI summary")

        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Totally new CLI summary")
        await fixture.store.reload()
        let live = try #require(model.store.sessions.first)
        #expect(live.title == "Totally new CLI summary")
        #expect(model.freshSession(matching: stale).title == "Totally new CLI summary")

        model.renameDraft = "Totally new CLI summary"
        model.commitCapturedRename(stale)
        #expect(!model.hasCustomName(stale))
        #expect(model.title(for: live) == "Totally new CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)

        model.beginRename(live)
        model.renameDraft = "Auth rewrite"
        model.commitCapturedRename(stale)
        #expect(model.title(for: live) == "Auth rewrite")
        #expect(model.hasCustomName(live))

        model.beginRename(live)
        model.renameDraft = "Totally new CLI summary"
        model.commitCapturedRename(stale)
        #expect(!model.hasCustomName(live))
        #expect(model.title(for: live) == "Totally new CLI summary")
    }

    @Test @MainActor
    func capturedRenameFallsBackToTheSnapshotWhenTheSessionIsGone() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let ghost = makeSession(id: "gone", cwd: cwd)
        #expect(!model.store.sessions.contains { $0.id == ghost.id })
        #expect(model.freshSession(matching: ghost).id == ghost.id)
        model.renameDraft = "Keep this"
        model.commitCapturedRename(ghost)
        #expect(model.title(for: ghost) == "Keep this")
        #expect(model.hasCustomName(ghost))
    }

    @Test @MainActor
    func inlineRenameUsesTheLiveStoreSessionNotTheRowSnapshot() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let stale = try #require(model.store.sessions.first)
        model.beginRename(stale)
        #expect(stale.title == "CLI summary")

        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Totally new CLI summary")
        await fixture.store.reload()
        let live = try #require(model.store.sessions.first)
        #expect(model.freshSession(matching: stale).title == "Totally new CLI summary")

        model.commitInlineRename(stale, to: "Totally new CLI summary")
        #expect(!model.hasCustomName(stale))
        #expect(model.title(for: live) == "Totally new CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)

        model.beginRename(live)
        model.commitInlineRename(stale, to: "Auth rewrite")
        #expect(model.title(for: live) == "Auth rewrite")
        #expect(model.hasCustomName(live))

        model.beginRename(live)
        model.commitInlineRename(stale, to: "Totally new CLI summary")
        #expect(!model.hasCustomName(live))
        #expect(model.title(for: live) == "Totally new CLI summary")
    }

    @Test @MainActor
    func inlineBlurUsesTheLiveStoreSessionNotTheRowSnapshot() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let stale = try #require(model.store.sessions.first)
        model.beginRename(stale)
        model.noteRenameFieldMounted(true, key: model.sessionKey(stale))

        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Totally new CLI summary")
        await fixture.store.reload()
        let live = try #require(model.store.sessions.first)

        model.commitInlineBlur(
            stale, to: "Totally new CLI summary",
            mountGeneration: model.renameFieldMountGeneration)
        #expect(!model.hasCustomName(stale))
        #expect(model.title(for: live) == "Totally new CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)

        model.beginRename(live)
        model.noteRenameFieldMounted(true, key: model.sessionKey(live))
        model.commitInlineBlur(
            stale, to: "Auth rewrite",
            mountGeneration: model.renameFieldMountGeneration)
        #expect(model.title(for: live) == "Auth rewrite")
        #expect(model.hasCustomName(live))
    }

    @Test @MainActor
    func uneditedCommitAfterCLISummaryRewriteDoesNotPinTheStaleDraft() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let stale = try #require(model.store.sessions.first)
        model.beginRename(stale)
        #expect(model.renameDraft == "CLI summary")
        #expect(model.renameCommitBaseline == "CLI summary")
        let namesBefore = fixture.defaults.data(forKey: "sidebar.conversationNames")

        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Totally new CLI summary")
        await fixture.store.reload()
        let live = try #require(model.store.sessions.first)
        #expect(model.renameDraft == "CLI summary")
        #expect(model.renameCommitBaseline == "CLI summary")
        model.commitCapturedRename(stale)
        #expect(!model.hasCustomName(live))
        #expect(model.title(for: live) == "Totally new CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(fixture.defaults.data(forKey: "sidebar.conversationNames") == namesBefore)
        #expect(model.renamingSessionKey == nil)
        #expect(model.renameCommitBaseline == nil)

        model.beginRename(live)
        #expect(model.renameDraft == "Totally new CLI summary")
        #expect(model.renameCommitBaseline == "Totally new CLI summary")
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Third CLI summary")
        await fixture.store.reload()
        let live2 = try #require(model.store.sessions.first)
        model.commitInlineRename(stale, to: model.renameDraft)
        #expect(!model.hasCustomName(live2))
        #expect(model.title(for: live2) == "Third CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)

        model.beginRename(live2)
        model.noteRenameFieldMounted(true, key: model.sessionKey(live2))
        #expect(model.renameCommitBaseline == "Third CLI summary")
        try fixture.writeListedSession(id: "s1", cwd: cwd, summary: "Fourth CLI summary")
        await fixture.store.reload()
        let live3 = try #require(model.store.sessions.first)
        model.commitInlineBlur(
            stale, to: model.renameDraft, mountGeneration: model.renameFieldMountGeneration)
        #expect(!model.hasCustomName(live3))
        #expect(model.title(for: live3) == "Fourth CLI summary")
        #expect(fixture.settings.conversationNames.isEmpty)
        #expect(model.renamingSessionKey == nil)
    }

    @Test @MainActor
    func sameKeyBeginRenameKeepsCommitBaselineSoTypingStillSaves() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.renameDraft = "Typed"
        #expect(model.renameCommitBaseline == "CLI summary")
        model.beginRename(session)
        #expect(model.renameCommitBaseline == "CLI summary")
        #expect(model.renameSelectAllBaseline == nil)
        model.commitCapturedRename(session)
        #expect(model.title(for: session) == "Typed")
        #expect(model.hasCustomName(session))
    }

    @Test @MainActor
    func deferredAlertCancelSkipsOnceRenameHasCommitted() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.revealRenameAlert(session)
        model.renameDraft = "Keep this"
        let generation = model.renameAlertDismissGeneration
        let pending = Task { await model.deferCancelRenameAlert(expectedGeneration: generation) }
        model.commitCapturedRename(session)
        await pending.value
        #expect(model.title(for: session) == "Keep this")
        #expect(model.renamingSessionKey == nil)
    }

    @Test @MainActor
    func deferredAlertCancelRunsWhenStillUncommitted() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.revealRenameAlert(session)
        model.renameDraft = "Typed"
        #expect(!model.renameAlertDidCommit)
        await model.deferCancelRenameAlert(
            expectedGeneration: model.renameAlertDismissGeneration)
        #expect(model.renamingSessionKey == nil)
        #expect(model.renameDraft.isEmpty)
        #expect(!model.hasCustomName(session))
    }

    @Test @MainActor
    func deferredAlertCancelPolicy() {
        #expect(
            AppModel.shouldCancelRenameAlertAfterYield(
                isCancelled: false, sidebarVisible: true, didCommit: false, stillRenaming: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCancelRenameAlertAfterYield(
                isCancelled: false, sidebarVisible: true, didCommit: true, stillRenaming: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCancelRenameAlertAfterYield(
                isCancelled: true, sidebarVisible: true, didCommit: false, stillRenaming: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCancelRenameAlertAfterYield(
                isCancelled: false, sidebarVisible: false, didCommit: false, stillRenaming: true,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCancelRenameAlertAfterYield(
                isCancelled: false, sidebarVisible: true, didCommit: false, stillRenaming: false,
                expectedGeneration: 1, currentGeneration: 1))
        #expect(
            !AppModel.shouldCancelRenameAlertAfterYield(
                isCancelled: false, sidebarVisible: true, didCommit: false, stillRenaming: true,
                expectedGeneration: 1, currentGeneration: 2))
    }

    @Test @MainActor
    func beginRenamePoisonsInFlightAlertCancel() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s-a", cwd: "/Users/someone/Documents/project", summary: "Alpha CLI")
        try fixture.writeListedSession(
            id: "s-b", cwd: "/Users/someone/Documents/project", summary: "Beta CLI")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let sessionA = try #require(model.store.sessions.first { $0.id == "s-a" })
        let sessionB = try #require(model.store.sessions.first { $0.id == "s-b" })
        model.beginRename(sessionA)
        model.revealRenameAlert(sessionA)
        model.renameDraft = "Typed on A"
        let generation = model.renameAlertDismissGeneration
        let pending = Task { await model.deferCancelRenameAlert(expectedGeneration: generation) }
        model.beginRename(sessionB)
        await pending.value
        #expect(model.renamingSessionKey == model.sessionKey(sessionB))
        #expect(model.renameDraft == "Beta CLI")
        #expect(!model.hasCustomName(sessionA))
        #expect(!model.hasCustomName(sessionB))
    }

    @Test @MainActor
    func sameKeyBeginRenamePoisonsInFlightAlertCancel() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.revealRenameAlert(session)
        model.renameDraft = "Typed"
        let generation = model.renameAlertDismissGeneration
        let pending = Task {
            await model.deferCancelRenameAlert(expectedGeneration: generation)
        }
        model.beginRename(session)
        #expect(model.renameAlertDismissGeneration == generation + 1)
        await pending.value
        #expect(model.renamingSessionKey == model.sessionKey(session))
        #expect(model.renameDraft == "Typed")
        #expect(!model.renameAlertDidCommit)
    }

    @Test @MainActor
    func sameKeyBeginRenameAfterAlertDismissRepresentsPromptAndKeepsDraft() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        let key = model.sessionKey(session)
        model.preparedRenameKey = key
        model.preparedRenameSurface = .prompt
        model.revealRenameAlert(session)
        model.renameDraft = "Typed"
        model.showRenameAlert = false
        let generation = model.renameAlertDismissGeneration
        let token = model.renamePrepareToken
        let pending = Task {
            await model.deferCancelRenameAlert(expectedGeneration: generation)
        }
        model.beginRename(session)
        await Task.yield()
        await pending.value
        #expect(model.renamingSessionKey == key)
        #expect(model.renameDraft == "Typed")
        #expect(model.showRenameAlert)
        #expect(model.renameAlertSession?.id == session.id)
        #expect(model.preparedRenameKey == nil)
        #expect(model.preparedRenameSurface == .none)
        #expect(model.renamePrepareToken == token + 1)
        #expect(model.renamePrepareTaskID.token == token + 1)
        #expect(model.renamePrepareTaskID.key == key)
        #expect(!model.renameSelectAllPending)
        #expect(!AppModel.shouldArmRenameSelectAllOnBegin(isFreshKey: false))
        #expect(
            AppModel.shouldReconfigureRename(
                previousKey: model.preparedRenameKey,
                previousSurface: model.preparedRenameSurface,
                nextKey: key,
                nextSurface: .prompt,
                forceReconfigure: model.renamingSessionKey != model.preparedRenameKey
            ))
    }

    @Test @MainActor
    func sameKeyBeginRenameInvalidatesInlinePrepareWithoutReseedingDraft() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        let key = model.sessionKey(session)
        model.preparedRenameKey = key
        model.preparedRenameSurface = .inline
        model.renameDraft = "Typed"
        let token = model.renamePrepareToken
        model.beginRename(session)
        #expect(model.renamingSessionKey == key)
        #expect(model.renameDraft == "Typed")
        #expect(!model.showRenameAlert)
        #expect(model.preparedRenameKey == nil)
        #expect(model.preparedRenameSurface == .none)
        #expect(model.renamePrepareToken == token + 1)
        #expect(!model.renameSelectAllPending)
    }

    @Test @MainActor
    func clickOutAfterSameKeyBeginRenameStillCancels() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.revealRenameAlert(session)
        model.renameDraft = "Typed"
        #expect(!model.renameAlertDidCommit)
        model.beginRename(session)
        #expect(!model.renameAlertDidCommit)
        #expect(model.renameDraft == "Typed")
        await model.deferCancelRenameAlert(
            expectedGeneration: model.renameAlertDismissGeneration)
        #expect(model.renamingSessionKey == nil)
        #expect(model.renameDraft.isEmpty)
    }

    @Test @MainActor
    func beginRenameLeavesDidCommitTrueAcrossAlertTeardown() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s-a", cwd: "/Users/someone/Documents/project", summary: "Alpha CLI")
        try fixture.writeListedSession(
            id: "s-b", cwd: "/Users/someone/Documents/project", summary: "Beta CLI")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let sessionA = try #require(model.store.sessions.first { $0.id == "s-a" })
        let sessionB = try #require(model.store.sessions.first { $0.id == "s-b" })
        model.beginRename(sessionA)
        model.showRenameAlert = true
        model.renameAlertSession = sessionA
        model.renameAlertDidCommit = false

        model.beginRename(sessionB)
        #expect(model.renameAlertDidCommit)
        #expect(!model.showRenameAlert)
        #expect(!AppModel.shouldCancelRenameAlert(didCommit: model.renameAlertDidCommit))
        #expect(model.renameDraft == "Beta CLI")
        #expect(model.renamingSessionKey == model.sessionKey(sessionB))

        let generation = model.renameAlertDismissGeneration
        await model.deferCancelRenameAlert(expectedGeneration: generation)
        #expect(model.renameAlertDismissGeneration == generation)
        #expect(model.renamingSessionKey == model.sessionKey(sessionB))
        #expect(model.renameDraft == "Beta CLI")
        #expect(model.renameAlertDidCommit)

        model.revealRenameAlert(sessionB)
        #expect(!model.renameAlertDidCommit)
        #expect(AppModel.shouldCancelRenameAlert(didCommit: model.renameAlertDidCommit))
    }

    @Test @MainActor
    func forcePromptRepresentWhenKeyIsLiveAndRowIsHidden() {
        #expect(
            AppModel.shouldForcePromptRepresent(
                isRenaming: true, rowVisible: false, sidebarVisible: true,
                showRenameAlert: true, preparedSurface: .none))
        #expect(
            AppModel.shouldForcePromptRepresent(
                isRenaming: true, rowVisible: false, sidebarVisible: true,
                showRenameAlert: false, preparedSurface: .prompt))
        #expect(
            !AppModel.shouldForcePromptRepresent(
                isRenaming: true, rowVisible: false, sidebarVisible: true,
                showRenameAlert: false, preparedSurface: .none))
        #expect(
            !AppModel.shouldForcePromptRepresent(
                isRenaming: true, rowVisible: false, sidebarVisible: true,
                showRenameAlert: false, preparedSurface: .inline))
        #expect(
            !AppModel.shouldForcePromptRepresent(
                isRenaming: true, rowVisible: true, sidebarVisible: true,
                showRenameAlert: true, preparedSurface: .prompt))
        #expect(
            !AppModel.shouldForcePromptRepresent(
                isRenaming: false, rowVisible: false, sidebarVisible: true,
                showRenameAlert: true, preparedSurface: .prompt))
        #expect(
            !AppModel.shouldForcePromptRepresent(
                isRenaming: true, rowVisible: false, sidebarVisible: false,
                showRenameAlert: true, preparedSurface: .prompt))
    }

    @Test @MainActor
    func freshBeginRenameThatOpensTheSidebarIsNotAPromptRestore() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.isSidebarVisible = false
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        #expect(model.isSidebarVisible)
        #expect(model.renameSelectAllPending)
        #expect(!model.showRenameAlert)
        #expect(model.preparedRenameSurface == .none)
        #expect(
            !AppModel.shouldForcePromptRepresent(
                isRenaming: true,
                rowVisible: false,
                sidebarVisible: true,
                showRenameAlert: model.showRenameAlert,
                preparedSurface: model.preparedRenameSurface))
        #expect(model.renameSelectAllPending)
        #expect(
            AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: true, isCancelled: false, isRenaming: true,
                forceRepresent: false))
    }

    @Test @MainActor
    func forceRepresentPulsesAStuckAlertAndRefreshesTheSession() async throws {
        #expect(
            AppModel.shouldPulseRenameAlert(forceRepresent: true, currentlyShown: true))
        #expect(
            !AppModel.shouldPulseRenameAlert(forceRepresent: true, currentlyShown: false))
        #expect(
            !AppModel.shouldPulseRenameAlert(forceRepresent: false, currentlyShown: true))
        #expect(
            AppModel.shouldApplyRenameAlertPresentedChange(sidebarVisible: true, pulsing: false))
        #expect(
            !AppModel.shouldApplyRenameAlertPresentedChange(sidebarVisible: true, pulsing: true))
        #expect(
            !AppModel.shouldApplyRenameAlertPresentedChange(
                sidebarVisible: false, pulsing: false))

        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.renameDraft = "Typed"
        model.showRenameAlert = true
        model.renameAlertSession = session
        model.renameAlertDidCommit = false

        #expect(
            AppModel.shouldPulseRenameAlert(
                forceRepresent: true, currentlyShown: model.showRenameAlert))
        model.pulseRenameAlertOff()
        #expect(!model.showRenameAlert)
        #expect(model.renameAlertIsPulsing)
        #expect(model.renameAlertDidCommit)
        #expect(model.renameDraft == "Typed")
        #expect(model.renamingSessionKey == model.sessionKey(session))

        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project",
            summary: "Totally new CLI summary")
        await fixture.store.reload()
        let live = try #require(model.store.sessions.first)
        model.revealRenameAlert(live)
        #expect(model.showRenameAlert)
        #expect(!model.renameAlertIsPulsing)
        #expect(!model.renameAlertDidCommit)
        #expect(model.renameAlertSession?.title == "Totally new CLI summary")
        #expect(model.renameDraft == "Typed")
    }

    @Test @MainActor
    func lazyUnmountBlurDoesNotCommitAHalfTypedName() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.renameDraft = "Half"
        let key = model.sessionKey(session)
        model.noteRenameFieldMounted(true, key: key)
        let generation = model.renameFieldMountGeneration
        model.noteRenameFieldMounted(false, key: key)
        #expect(model.renameFieldMountedKey == nil)
        model.noteRenameFieldMounted(true, key: key)
        #expect(model.renameFieldMountedKey == key)
        model.commitInlineBlur(
            session, to: model.renameDraft, mountGeneration: generation)
        #expect(!model.hasCustomName(session))
        #expect(model.renameDraft == "Half")
        #expect(model.renamingSessionKey == key)
        #expect(model.title(for: session) == "CLI summary")
    }

    @Test @MainActor
    func renameFieldMountAppliesOnlyForTheActiveKey() {
        #expect(
            AppModel.shouldApplyRenameFieldMount(mountKey: "b", activeKey: "b", mountedKey: nil))
        #expect(
            AppModel.shouldApplyRenameFieldMount(mountKey: "b", activeKey: "b", mountedKey: "a"))
        #expect(
            !AppModel.shouldApplyRenameFieldMount(mountKey: "b", activeKey: "b", mountedKey: "b"))
        #expect(
            !AppModel.shouldApplyRenameFieldMount(mountKey: "b", activeKey: "a", mountedKey: "a"))
        #expect(
            !AppModel.shouldApplyRenameFieldMount(mountKey: "b", activeKey: nil, mountedKey: nil))
        #expect(
            AppModel.shouldApplyRenameFieldUnmount(unmountKey: "a", activeKey: "a", mountedKey: "a"))
        #expect(
            !AppModel.shouldApplyRenameFieldUnmount(unmountKey: "a", activeKey: "b", mountedKey: "b"))
        #expect(
            !AppModel.shouldApplyRenameFieldUnmount(unmountKey: "a", activeKey: "b", mountedKey: "a"))
        #expect(
            !AppModel.shouldApplyRenameFieldUnmount(unmountKey: "a", activeKey: "a", mountedKey: nil))
        #expect(
            !AppModel.shouldApplyRenameFieldUnmount(unmountKey: "a", activeKey: nil, mountedKey: "a"))
    }

    @Test @MainActor
    func switchingRenameToAnOnScreenRowKeepsTheNewFieldMounted() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = "/Users/someone/Documents/project"
        try fixture.writeListedSession(id: "s-a", cwd: cwd, summary: "Alpha CLI")
        try fixture.writeListedSession(id: "s-b", cwd: cwd, summary: "Beta CLI")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let sessionA = try #require(model.store.sessions.first { $0.id == "s-a" })
        let sessionB = try #require(model.store.sessions.first { $0.id == "s-b" })
        let keyA = model.sessionKey(sessionA)
        let keyB = model.sessionKey(sessionB)

        model.beginRename(sessionA)
        model.noteRenameFieldMounted(true, key: keyA)
        #expect(model.renameFieldMountedKey == keyA)
        let generationAfterA = model.renameFieldMountGeneration

        model.beginRename(sessionB)
        // B is earlier in the list, so its field reports mounted before A unmounts.
        model.noteRenameFieldMounted(true, key: keyB)
        model.noteRenameFieldMounted(false, key: keyA)
        #expect(model.renameFieldMountedKey == keyB)
        #expect(model.renamingSessionKey == keyB)
        #expect(model.renameFieldMountGeneration == generationAfterA + 1)

        model.commitInlineBlur(
            sessionA, to: "Alpha typed", mountGeneration: model.renameFieldMountGeneration)
        #expect(!model.hasCustomName(sessionA))
        #expect(model.renamingSessionKey == keyB)

        model.commitInlineBlur(
            sessionB, to: "Beta typed", mountGeneration: model.renameFieldMountGeneration)
        #expect(model.title(for: sessionB) == "Beta typed")
        #expect(model.renamingSessionKey == nil)
        #expect(model.renameFieldMountedKey == nil)
    }

    @Test @MainActor
    func renamingRowIsNotAButtonAndResetNameRequiresAnOverlay() {
        #expect(AppModel.renameRowUsesButtonTrait(isRenaming: false))
        #expect(!AppModel.renameRowUsesButtonTrait(isRenaming: true))
        #expect(AppModel.renameRowOffersResetName(hasCustomName: true))
        #expect(!AppModel.renameRowOffersResetName(hasCustomName: false))
    }

    @Test @MainActor
    func selectAllIsOnlyPendingOnFreshBeginRename() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        #expect(model.renameSelectAllPending)
        #expect(model.renameSelectAllBaseline == "CLI summary")
        #expect(
            AppModel.shouldSelectRenameDraftIfUnedited(
                currentDraft: model.renameDraft, baseline: model.renameSelectAllBaseline))
        #expect(
            !AppModel.shouldSelectRenameDraftIfUnedited(
                currentDraft: "CLI summary", baseline: nil))
        #expect(AppModel.shouldArmRenameSelectAllOnBegin(isFreshKey: true))
        #expect(!AppModel.shouldArmRenameSelectAllOnBegin(isFreshKey: false))
        #expect(
            AppModel.shouldSelectRenameDraft(
                selectAllPending: true, isCancelled: false, isRenaming: true))
        #expect(model.consumeRenameSelectAll())
        #expect(!model.renameSelectAllPending)
        #expect(model.renameSelectAllBaseline == nil)
        #expect(!model.consumeRenameSelectAll())

        model.beginRename(session)
        #expect(!model.renameSelectAllPending)
        #expect(model.renameSelectAllBaseline == nil)
        model.renameDraft = "Typed"
        model.clearRenameSelectAllPending()
        #expect(
            !AppModel.shouldSelectRenameDraft(
                selectAllPending: false, isCancelled: false, isRenaming: true))
        #expect(model.renameDraft == "Typed")
    }

    @Test @MainActor
    func fieldUnmountDoesNotClearSelectAllPending() async throws {
        #expect(
            AppModel.shouldClearRenameSelectAllOnSidebarHide(wasVisible: true, isVisible: false))
        #expect(
            !AppModel.shouldClearRenameSelectAllOnSidebarHide(wasVisible: true, isVisible: true))
        #expect(
            !AppModel.shouldClearRenameSelectAllOnSidebarHide(wasVisible: false, isVisible: true))
        #expect(
            !AppModel.shouldClearRenameSelectAllOnSidebarHide(wasVisible: false, isVisible: false))

        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        let key = model.sessionKey(session)
        model.beginRename(session)
        model.noteRenameFieldMounted(true, key: key)
        #expect(model.renameSelectAllPending)
        model.noteRenameFieldMounted(false, key: key)
        #expect(model.renameSelectAllPending)
        model.noteRenameFieldMounted(true, key: key)
        #expect(model.renameSelectAllPending)
        #expect(model.consumeRenameSelectAll())
        #expect(!model.renameSelectAllPending)
    }

    @Test @MainActor
    func hidingSidebarClearsSelectAllPendingAndRestoreDoesNotSelectAll() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.renameDraft = "Typed"
        #expect(model.renameSelectAllPending)

        model.isSidebarVisible = false
        #expect(!model.renameSelectAllPending)
        #expect(model.renameDraft == "Typed")
        #expect(model.renamingSessionKey == model.sessionKey(session))

        model.isSidebarVisible = true
        #expect(!model.renameSelectAllPending)
        #expect(model.renameDraft == "Typed")
        #expect(
            !AppModel.shouldSelectRenameDraft(
                selectAllPending: model.renameSelectAllPending,
                isCancelled: false,
                isRenaming: true))
    }

    @Test @MainActor
    func beginRenameSeedsDraftOnAFreshKeyAndDoesNotClobberLaterTyping() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s-a", cwd: "/Users/someone/Documents/project", summary: "Alpha CLI")
        try fixture.writeListedSession(
            id: "s-b", cwd: "/Users/someone/Documents/project", summary: "Beta CLI")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let sessionA = try #require(model.store.sessions.first { $0.id == "s-a" })
        let sessionB = try #require(model.store.sessions.first { $0.id == "s-b" })

        model.beginRename(sessionA)
        #expect(model.renameDraft == "Alpha CLI")
        model.renameDraft = "Typed on A"
        model.beginRename(sessionA)
        #expect(model.renameDraft == "Typed on A")

        model.beginRename(sessionB)
        #expect(model.renameDraft == "Beta CLI")
        #expect(model.renameSelectAllBaseline == "Beta CLI")
        model.renameDraft = "Typed on B"
        #expect(model.renameSelectAllPending)
        #expect(
            !AppModel.shouldSelectRenameDraftIfUnedited(
                currentDraft: model.renameDraft, baseline: model.renameSelectAllBaseline))
        model.beginRename(sessionB)
        #expect(model.renameDraft == "Typed on B")
        #expect(!model.renameSelectAllPending)
        #expect(!AppModel.shouldArmRenameSelectAllOnBegin(isFreshKey: false))
    }

    @Test @MainActor
    func sameKeyBeginRenameClearsSelectAllPendingWithoutRearming() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        #expect(model.renameSelectAllPending)
        #expect(model.renameSelectAllBaseline == "CLI summary")
        model.renameDraft = "Typed"
        #expect(
            !AppModel.shouldSelectRenameDraftIfUnedited(
                currentDraft: "Typed", baseline: model.renameSelectAllBaseline))
        model.beginRename(session)
        #expect(!model.renameSelectAllPending)
        #expect(model.renameDraft == "Typed")
        #expect(
            !AppModel.shouldSelectRenameDraft(
                selectAllPending: model.renameSelectAllPending,
                isCancelled: false,
                isRenaming: true))
    }

    @Test @MainActor
    func alertSelectAllIsOnlyOnFreshBeginNotForceRepresent() async throws {
        #expect(AppModel.renameAlertCommitUsesDefaultAction())
        #expect(
            AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: true, isCancelled: false, isRenaming: true,
                forceRepresent: false))
        #expect(
            !AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: true, isCancelled: false, isRenaming: true,
                forceRepresent: true))
        #expect(
            !AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: false, isCancelled: false, isRenaming: true,
                forceRepresent: false))
        #expect(
            !AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: true, isCancelled: true, isRenaming: true,
                forceRepresent: false))
        #expect(
            !AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: true, isCancelled: false, isRenaming: false,
                forceRepresent: false))
        #expect(AppModel.shouldPrepareRename(isCancelled: false))
        #expect(!AppModel.shouldPrepareRename(isCancelled: true))
        #expect(
            AppModel.shouldClearRenameSelectAllOnPrepare(
                forceRepresent: true, isCancelled: false))
        #expect(
            !AppModel.shouldClearRenameSelectAllOnPrepare(
                forceRepresent: true, isCancelled: true))
        #expect(
            !AppModel.shouldClearRenameSelectAllOnPrepare(
                forceRepresent: false, isCancelled: false))
        #expect(
            !AppModel.shouldClearRenameSelectAllOnPrepare(
                forceRepresent: false, isCancelled: true))

        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        #expect(model.renameSelectAllPending)
        #expect(
            AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: model.renameSelectAllPending,
                isCancelled: false,
                isRenaming: true,
                forceRepresent: false))
        #expect(model.consumeRenameSelectAll())
        #expect(!model.renameSelectAllPending)

        model.beginRename(session)
        model.renameDraft = "Typed"
        #expect(!model.renameSelectAllPending)
        #expect(
            !AppModel.shouldSelectRenameAlertDraft(
                selectAllPending: model.renameSelectAllPending,
                isCancelled: false,
                isRenaming: true,
                forceRepresent: true))
        model.clearRenameSelectAllPending()
        #expect(model.renameDraft == "Typed")
        #expect(!model.renameSelectAllPending)
    }

    @Test @MainActor
    func hidingSidebarMidRenamePreservesDraftAndDoesNotCommit() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.renameDraft = "Typed name"
        model.preparedRenameKey = model.sessionKey(session)
        model.preparedRenameSurface = .inline

        model.isSidebarVisible = false
        model.commitInlineBlur(
            session, to: model.renameDraft, mountGeneration: model.renameFieldMountGeneration)

        #expect(model.renamingSessionKey == model.sessionKey(session))
        #expect(model.renameDraft == "Typed name")
        #expect(!model.renameSelectAllPending)
        #expect(!model.hasCustomName(session))
        #expect(model.title(for: session) == "CLI summary")

        model.isSidebarVisible = true
        #expect(model.renameDraft == "Typed name")
        #expect(model.renamingSessionKey == model.sessionKey(session))
        #expect(!model.renameSelectAllPending)
        #expect(!model.hasCustomName(session))
    }

    @Test @MainActor
    func hidingSidebarDoesNotClearAnExistingOverride() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.rename(session, to: "Auth rewrite")
        model.beginRename(session)
        model.renameDraft = "Changing it"
        model.isSidebarVisible = false
        model.commitInlineBlur(
            session, to: "Changing it", mountGeneration: model.renameFieldMountGeneration)

        #expect(model.hasCustomName(session))
        #expect(model.title(for: session) == "Auth rewrite")
        #expect(model.renameDraft == "Changing it")
        #expect(model.renamingSessionKey == model.sessionKey(session))
    }

    @Test @MainActor
    func alertCommitAfterCancelStillWritesWhenInlineWouldNot() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        try fixture.writeListedSession(
            id: "s1", cwd: "/Users/someone/Documents/project", summary: "CLI summary")
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let session = try #require(model.store.sessions.first)
        model.beginRename(session)
        model.cancelRename()
        model.commitInlineRename(session, to: "From inline")
        #expect(!model.hasCustomName(session))
        model.commitRename(session, to: "From alert")
        #expect(model.title(for: session) == "From alert")
    }

    @Test @MainActor
    func focusedProjectLimitsChatsAndNewSessionsToThatFolder() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let projectA = try fixture.directory("acme-api")
        let projectB = try fixture.directory("acme-web")
        try fixture.writeListedSession(id: "a", cwd: projectA.path, summary: "API chat")
        try fixture.writeListedSession(id: "b", cwd: projectB.path, summary: "Web chat")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let api = try #require(model.sidebarProjects.first { $0.name == "acme-api" })
        model.openProject(api)

        #expect(model.focusedProject?.name == "acme-api")
        #expect(model.focusedSidebarSessions.map(\.id) == ["a"])
        #expect(
            model.newSessionDirectory.resolvingSymlinksInPath().path
                == projectA.resolvingSymlinksInPath().path)

        model.requestNewSessionInProject(api)
        #expect(model.isShowingNewSessionSheet)
        #expect(model.tabs.isEmpty)
        let directory = try #require(model.pendingSessionDirectory)
        let tab = try #require(model.newTab(in: directory))
        #expect(
            tab.workingDirectory.resolvingSymlinksInPath().path
                == projectA.resolvingSymlinksInPath().path)

        model.searchText = "no-such-chat"
        #expect(model.focusedProject?.name == "acme-api")
        #expect(model.focusedSidebarSessions.isEmpty)
        #expect(
            model.newSessionDirectory.resolvingSymlinksInPath().path
                == projectA.resolvingSymlinksInPath().path)

        model.searchText = ""
        model.leaveProject()
        #expect(model.focusedProject == nil)
        #expect(model.focusedSidebarSessions.map(\.id).sorted() == ["a", "b"])
    }

    @Test @MainActor
    func recentsAndArchivedAreDrillInsNotFilters() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("acme-api")
        try fixture.writeListedSession(id: "live", cwd: cwd.path, summary: "Live chat")
        try fixture.writeListedSession(id: "old", cwd: cwd.path, summary: "Old chat")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let old = try #require(model.store.sessions.first { $0.id == "old" })
        model.archive(old)

        #expect(model.sidebarSurface == .folders)
        #expect(model.sidebarSessions.map(\.id) == ["live"])
        model.openRecents()
        #expect(model.sidebarSurface == .recents)
        #expect(model.focusedProject == nil)
        #expect(model.sidebarSessions.map(\.id) == ["live"])
        model.openArchived()
        #expect(model.sidebarSurface == .archived)
        #expect(model.sidebarSessions.map(\.id) == ["old"])
        model.pruneMissingPins()
        #expect(model.sidebarSurface == .archived)
        model.openRecents()
        model.pruneMissingPins()
        #expect(model.sidebarSurface == .recents)
        model.leaveProject()
        #expect(model.sidebarSurface == .folders)
    }

    @Test @MainActor
    func archivingAProjectHidesTheFolderAndLeavesIt() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("acme-api")
        try fixture.writeListedSession(id: "a", cwd: cwd.path, summary: "A")
        try fixture.writeListedSession(id: "b", cwd: cwd.path, summary: "B")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first)
        model.pin(project)
        model.openProject(project)
        model.archive(project)
        #expect(model.focusedProject == nil)
        #expect(model.sidebarProjects.isEmpty)
        #expect(!model.isPinned(project))
        model.openArchived()
        #expect(model.sidebarSessions.map(\.id).sorted() == ["a", "b"])
        model.unarchive(project)
        model.leaveProject()
        #expect(model.sidebarProjects.map(\.name) == ["acme-api"])
    }

    @Test @MainActor
    func archivingAnOpenChatClosesItsTab() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let tab = try #require(model.newTab(in: cwd))
        let session = makeSession(id: try #require(tab.sessionID), cwd: cwd)
        model.archive(session)

        #expect(model.tabs.isEmpty)
        #expect(model.selectedTabID == nil)
        #expect(model.isArchived(session))
        #expect(!model.isOpen(session))
        model.unarchive(session)
        #expect(model.tabs.isEmpty)
    }

    @Test @MainActor
    func archivingOneChatLeavesOtherTabsOpen() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let first = try #require(model.newTab(in: cwd))
        let second = try #require(model.newTab(in: cwd))
        let archived = makeSession(id: try #require(first.sessionID), cwd: cwd)
        model.archive(archived)

        #expect(model.tabs.map(\.id) == [second.id])
        #expect(model.selectedTabID == second.id)
        #expect(model.isArchived(archived))
        #expect(!model.isOpen(archived))
    }

    @Test @MainActor
    func archivingAProjectClosesItsOpenTabs() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let projectDir = try fixture.directory("acme-api")
        let otherDir = try fixture.directory("other")
        try fixture.writeListedSession(id: "a", cwd: projectDir.path, summary: "A")
        try fixture.writeListedSession(id: "b", cwd: projectDir.path, summary: "B")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first { $0.name == "acme-api" })
        let keep = try #require(model.newTab(in: otherDir))
        model.open(try #require(model.store.sessions.first { $0.id == "a" }))
        model.open(try #require(model.store.sessions.first { $0.id == "b" }))
        #expect(model.tabs.count == 3)

        model.archive(project)
        #expect(model.tabs.map(\.id) == [keep.id])
        #expect(model.selectedTabID == keep.id)
        #expect(model.store.sessions.filter { model.isArchived($0) }.map(\.id).sorted() == ["a", "b"])
    }

    @Test @MainActor
    func archivingAWorkingChatKeepsTheTabIfYouCancel() throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nexec /usr/bin/yes >/dev/null\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let tab = try #require(model.newTab(in: cwd))
        tab.noteTurnStarted()
        #expect(tab.shouldWarnBeforeStopping)
        let session = makeSession(id: try #require(tab.sessionID), cwd: cwd)
        model.confirmStopWorking = { false }
        model.archive(session)

        #expect(model.tabs.map(\.id) == [tab.id])
        #expect(!model.isArchived(session))
        #expect(model.isOpen(session))
    }

    @Test @MainActor
    func archivingAWorkingChatClosesTheTabIfYouConfirm() throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nexec /usr/bin/yes >/dev/null\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let tab = try #require(model.newTab(in: cwd))
        tab.noteTurnStarted()
        #expect(tab.shouldWarnBeforeStopping)
        let session = makeSession(id: try #require(tab.sessionID), cwd: cwd)
        model.confirmStopWorking = { true }
        model.archive(session)

        #expect(model.tabs.isEmpty)
        #expect(model.isArchived(session))
        #expect(!model.isOpen(session))
    }

    @Test @MainActor
    func archivingASelectionArchivesEveryChat() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let a = makeSession(id: "s-a", cwd: cwd)
        let b = makeSession(id: "s-b", cwd: cwd)
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        model.archive([a, b])

        #expect(model.isArchived(a))
        #expect(model.isArchived(b))
    }

    @Test @MainActor
    func archivingASelectionWithAWorkingChatAsksOnce() throws {
        let fixture = try ModelFixture(script: "#!/bin/sh\nexec /usr/bin/yes >/dev/null\n")
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let tab = try #require(model.newTab(in: cwd))
        tab.noteTurnStarted()
        let working = makeSession(id: try #require(tab.sessionID), cwd: cwd)
        let other = makeSession(id: "s-other", cwd: cwd)

        var asked = 0
        model.confirmStopWorking = {
            asked += 1
            return false
        }
        model.archive([working, other])
        #expect(asked == 1)
        #expect(!model.isArchived(working))
        #expect(!model.isArchived(other))
        #expect(model.isOpen(working))

        model.confirmStopWorking = {
            asked += 1
            return true
        }
        model.archive([working, other])
        #expect(asked == 2)
        #expect(model.isArchived(working))
        #expect(model.isArchived(other))
        #expect(!model.isOpen(working))
    }

    @Test @MainActor
    func deletingASelectionTrashesEachAndDropsItsNotes() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwdA = try fixture.directory("project-a")
        let cwdB = try fixture.directory("project-b")
        try fixture.createSession(id: "s-a", cwd: cwdA)
        try fixture.createSession(id: "s-b", cwd: cwdB)
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let a = makeSession(id: "s-a", cwd: cwdA)
        let b = makeSession(id: "s-b", cwd: cwdB)
        model.panel.setNotes("remember the milk", forSessionID: "s-a", cwd: cwdA.path)

        #expect(model.deleteConversations([a, b]) == 2)
        model.panel.notesStore.flushNow()
        #expect(model.panel.notes(forSessionID: "s-a", cwd: cwdA.path) == "")
        let noteDir =
            fixture.notesRoot
            .appendingPathComponent(GrokPaths.encode(path: GrokPaths.canonicalPath(cwdA.path)))
        #expect(
            !FileManager.default.fileExists(
                atPath: noteDir.appendingPathComponent("s-a.md").path))
    }

    @Test @MainActor
    func legacyFolderNotesMigrateToTheNewestConversationInTheFolder() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(
            id: "old", cwd: cwd.path, summary: "Old", updatedAt: "2026-07-01T00:00:00Z")
        try fixture.writeListedSession(
            id: "new", cwd: cwd.path, summary: "New", updatedAt: "2026-08-01T00:00:00Z")
        await fixture.store.reload()
        let orphanPath = fixture.root.appendingPathComponent("nowhere").path
        let legacy = [cwd.path: "folder note", orphanPath: "orphan note"]
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "panel.notes")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        model.migrateLegacyPanelNotes()

        #expect(model.panel.notes(forSessionID: "new", cwd: cwd.path) == "folder note")
        #expect(model.panel.notes(forSessionID: "old", cwd: cwd.path) == "")
        // A folder with no conversation keeps its note for a later launch.
        #expect(model.panel.legacyFolderNotes == [orphanPath: "orphan note"])
    }

    @Test @MainActor
    func legacyMigrationAppendsWhenTheTargetConversationAlreadyHasANote() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "new", cwd: cwd.path, summary: "New")
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        // The user typed a note before the migration ran.
        model.panel.setNotes("fresh note", forSessionID: "new", cwd: cwd.path)
        fixture.defaults.set(
            try JSONEncoder().encode([cwd.path: "folder note"]), forKey: "panel.notes")

        model.migrateLegacyPanelNotes()

        let migrated = model.panel.notes(forSessionID: "new", cwd: cwd.path)
        #expect(migrated.contains("fresh note"))
        #expect(migrated.contains("folder note"))
        #expect(model.panel.legacyFolderNotes.isEmpty)
    }

    @Test @MainActor
    func legacyMigrationAppendsEvenWhenTheLegacyTextIsAMereSubstring() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "new", cwd: cwd.path, summary: "New")
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.panel.setNotes("TODO later", forSessionID: "new", cwd: cwd.path)
        fixture.defaults.set(
            try JSONEncoder().encode([cwd.path: "TODO"]), forKey: "panel.notes")

        model.migrateLegacyPanelNotes()

        let migrated = model.panel.notes(forSessionID: "new", cwd: cwd.path)
        #expect(migrated == "TODO later\n\n---\n\nTODO")
        #expect(model.panel.legacyFolderNotes.isEmpty)
    }

    @Test @MainActor
    func legacyMigrationDoesNotDuplicateAnAlreadyMigratedSection() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        try fixture.writeListedSession(id: "new", cwd: cwd.path, summary: "New")
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        model.panel.setNotes("mine\n\n---\n\nfolder note", forSessionID: "new", cwd: cwd.path)
        fixture.defaults.set(
            try JSONEncoder().encode([cwd.path: "folder note"]), forKey: "panel.notes")

        model.migrateLegacyPanelNotes()

        #expect(model.panel.notes(forSessionID: "new", cwd: cwd.path) == "mine\n\n---\n\nfolder note")
        #expect(model.panel.legacyFolderNotes.isEmpty)
    }

    @Test @MainActor
    func deletingOneOfTwoSameIDConversationsKeepsTheFlatNote() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwdA = try fixture.directory("project-a")
        let cwdB = try fixture.directory("project-b")
        try fixture.writeListedSession(id: "same-id", cwd: cwdA.path, summary: "A")
        try fixture.writeListedSession(id: "same-id", cwd: cwdB.path, summary: "B")
        await fixture.store.reload()
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        try FileManager.default.createDirectory(at: fixture.notesRoot, withIntermediateDirectories: true)
        let flat = fixture.notesRoot.appendingPathComponent("same-id.md")
        try Data("shared note".utf8).write(to: flat)

        #expect(model.deleteConversation(makeSession(id: "same-id", cwd: cwdA)))
        model.panel.notesStore.flushNow()
        // The twin in project-b has not adopted the flat note yet; it stays.
        #expect(FileManager.default.fileExists(atPath: flat.path))
    }

    @Test @MainActor
    func archivingDropsADeferredTabSoItDoesNotRestore() throws {
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
        defer { model.closeAllTabsAndWait() }
        model.restoreOpenTabs()
        #expect(model.tabs.count == 1)

        model.archive(makeSession(id: "missing-id", cwd: missing))
        #expect(fixture.settings.openTabs.tabs.map(\.sessionID) == ["available-id"])
        #expect(fixture.settings.openTabs.selectedSessionID == "available-id")
    }

    @Test @MainActor
    func archivingAProjectClosesATabNotYetInTheStore() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let projectDir = try fixture.directory("acme-api")
        try fixture.writeListedSession(id: "a", cwd: projectDir.path, summary: "A")
        fixture.settings.showWorktreeSessions = true
        await fixture.store.reload()

        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        let project = try #require(model.sidebarProjects.first { $0.name == "acme-api" })
        let fresh = try #require(model.newTab(in: projectDir))
        #expect(model.store.sessions.map(\.id) == ["a"])
        #expect(model.tabs.map(\.id) == [fresh.id])

        model.archive(project)
        #expect(model.tabs.isEmpty)
        #expect(model.store.sessions.first { $0.id == "a" }.map(model.isArchived) == true)
    }

    @Test @MainActor
    func sidebarDismissClosesAnOpenTabAndDeletesAClosedChat() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }

        let tab = try #require(model.newTab(in: cwd))
        let sessionID = try #require(tab.sessionID)
        let open = makeSession(id: sessionID, cwd: cwd)
        #expect(model.sidebarDismiss(for: open) == .closeTab(tab.id))
        model.performSidebarDismiss(open)
        #expect(model.tabs.isEmpty)

        let closed = makeSession(id: "closed-id", cwd: cwd)
        #expect(model.sidebarDismiss(for: closed) == .delete)
    }

    @Test @MainActor
    func describesEveryTabActivity() {
        #expect(AppModel.describe(.starting) == "starting")
        #expect(AppModel.describe(.working) == "working")
        #expect(AppModel.describe(.idle) == "idle")
        #expect(AppModel.describe(.exited(code: 2)) == "exited 2")
        #expect(AppModel.describe(.exited(code: nil)) == "exited")
    }

    @Test @MainActor
    func crashStateSaysSoWhenNothingIsOpen() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }

        #expect(fixture.model().crashState() == "tabs open: 0")
    }

    @Test @MainActor
    func crashStateNamesTheOpenTabsAndMarksTheSelectedOne() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanup() }
        let cwd = try fixture.directory("project-a")
        let model = fixture.model()
        defer { model.closeAllTabsAndWait() }
        _ = try #require(model.newTab(in: cwd))

        let state = model.crashState()
        #expect(state.hasPrefix("tabs open: 1"))
        #expect(state.contains("\n* "))
        #expect(state.contains(cwd.lastPathComponent))
        #expect(state.contains("terminal tail"))
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
final class ModelFixture {
    let root: URL
    let grokHome: URL
    let executable: URL
    let socketURL: URL
    let defaults: UserDefaults
    let settings: AppSettings
    let store: SessionStore
    let notesRoot: URL

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
        defaults = UserDefaults(suiteName: defaultsName)!
        settings = AppSettings(defaults: defaults)
        settings.executablePath = executable.path
        store = SessionStore(root: grokHome.appendingPathComponent("sessions"))
        notesRoot = root.appendingPathComponent("notes")
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

    func writeListedSession(
        id: String,
        cwd: String,
        summary: String = "Session",
        messages: Int = 4,
        sessionKind: String? = nil,
        updatedAt: String = "2026-08-01T00:00:00Z"
    ) throws {
        let dir = GrokPaths.sessionDirectory(cwd: cwd, sessionID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json: [String: Any] = [
            "info": ["id": id, "cwd": cwd],
            "session_summary": summary,
            "created_at": "2026-08-01T00:00:00Z",
            "updated_at": updatedAt,
            "num_chat_messages": messages,
        ]
        if let sessionKind {
            json["session_kind"] = sessionKind
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
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
                canonicalPath: canonicalPath ?? { GrokPaths.canonicalPath($0) },
                panel: RightPanel(
                    defaults: defaults,
                    notesStore: ConversationNotesStore(root: notesRoot)
                ),
                pairingStore: InMemoryRemotePairingStore()
            )
        }
        if let canonicalPath {
            return AppModel(
                settings: settings,
                store: store,
                trashConversation: trashConversation,
                presentError: presentError,
                canonicalPath: canonicalPath,
                panel: RightPanel(
                    defaults: defaults,
                    notesStore: ConversationNotesStore(root: notesRoot)
                ),
                pairingStore: InMemoryRemotePairingStore()
            )
        }
        return AppModel(
            settings: settings,
            store: store,
            trashConversation: trashConversation,
            presentError: presentError,
            panel: RightPanel(
                defaults: defaults,
                notesStore: ConversationNotesStore(root: notesRoot)
            ),
            pairingStore: InMemoryRemotePairingStore()
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

@MainActor
private func flushMainAsync() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { cont.resume() }
    }
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
