import AppKit
import Foundation
import SigilKit
import Testing
import Vision

@testable import SigilApp

@Suite(.serialized)
struct RemoteCommandsTests {
    @Test @MainActor func controlsOnlyKnownTabsAndRejectsControlSequences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let received = root.appendingPathComponent("received")
        let executable = root.appendingPathComponent("fake-grok")
        let script = """
            #!/bin/sh
            stty -echo
            printf '\\033[?1hREMOTE_READY\\n'
            while IFS= read -r line; do
                printf '%s' "$line" > '\(received.path)'
                printf 'RECEIVED:%s\\n' "$line"
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "sigil-remote-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        let model = AppModel(
            settings: settings, presentError: { _ in }, providerInstallations: fixtureProviderInstallations(executable))
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: root))
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("REMOTE_READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("REMOTE_READY"))
        func command(_ action: String, text: String? = nil, tabID: String? = nil) async -> RemoteReply {
            await RemoteCommands.execute(
                RemoteRequest(
                    challenge: "test", sequence: 1, action: action, tabID: tabID ?? tab.id.uuidString, text: text),
                model: model)
        }
        #expect(await !command("input", text: "\u{1b}[201~injected\r").ok)
        #expect(await !command("input", text: "hello", tabID: UUID().uuidString).ok)
        #expect(await !command("key", text: "shell").ok)
        #expect(await !command("delete").ok)
        #expect(await !command("restart").ok)
        #expect(await !command("restart", tabID: UUID().uuidString).ok)
        #expect(await !command("input", text: "first\nsecond").ok)
        #expect(await command("input", text: "phone-test").ok)
        #expect(await command("key", text: "enter").ok)
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("phone-test") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("phone-test"))
        #expect(try String(contentsOf: received, encoding: .utf8) == "phone-test")
        let reply = await command("state")
        #expect(reply.state?.tabs.first?.id == tab.id.uuidString)
        #expect(reply.state?.terminal.contains("phone-test") == true)
        #expect(await command("key", text: "up").ok)
        #expect(await command("key", text: "enter").ok)
        for _ in 0..<100 {
            if (try? String(contentsOf: received, encoding: .utf8)) == "\u{1b}OA" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: received, encoding: .utf8) == "\u{1b}OA")
        tab.terminateAndWait()
        #expect(await !command("input", text: "after exit").ok)
        let restart = await command("restart")
        #expect(restart.ok)
        let replacement = try #require(model.selectedTab)
        #expect(replacement.id != tab.id)
        #expect(restart.restartedTabID == replacement.id.uuidString)
        #expect(replacement.sessionID == tab.sessionID)
        #expect(replacement.workingDirectory == tab.workingDirectory)
        #expect(model.tabs.count == 1)
        #expect(await !command("restart").ok)
        let other = try #require(model.newTab(in: root))
        replacement.terminateAndWait()
        let backgroundRestart = await command("restart", tabID: replacement.id.uuidString)
        #expect(backgroundRestart.ok)
        #expect(backgroundRestart.restartedTabID == model.tabs[0].id.uuidString)
        #expect(backgroundRestart.restartedTabID != other.id.uuidString)
        #expect(backgroundRestart.state?.selectedTabID == other.id.uuidString)
        #expect(model.selectedTabID == other.id)
    }

    @Test @MainActor func restartAcceptsAWorkingDirectoryThatIsASymlinkToAFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("folder")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-grok")
        try Data("#!/bin/sh\nprintf 'REMOTE_READY\\n'\nsleep 60\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "sigil-remote-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        let model = AppModel(
            settings: settings, presentError: { _ in }, providerInstallations: fixtureProviderInstallations(executable))
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: link))
        tab.terminateAndWait()
        let reply = await RemoteCommands.execute(
            RemoteRequest(challenge: "test", sequence: 1, action: "restart", tabID: tab.id.uuidString), model: model)
        #expect(reply.error == nil)
        #expect(reply.ok)
    }

    @Test @MainActor func fileChunksWriteToTheDropCacheAndPasteThePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let received = root.appendingPathComponent("received")
        let executable = root.appendingPathComponent("fake-grok")
        let script = """
            #!/bin/sh
            stty -echo
            printf '\\033[?1hREMOTE_READY\\n'
            while IFS= read -r line; do
                printf '%s' "$line" > '\(received.path)'
                printf 'RECEIVED:%s\\n' "$line"
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "sigil-remote-file-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        let model = AppModel(
            settings: settings, presentError: { _ in }, providerInstallations: fixtureProviderInstallations(executable))
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: root))
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("REMOTE_READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("REMOTE_READY"))
        RemoteCommands.uploads = RemoteUpload.Inbox()
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let reply = await RemoteCommands.execute(
            RemoteRequest(
                challenge: "test", sequence: 1, action: "file", tabID: tab.id.uuidString,
                text: png.base64EncodedString(), name: "shot.png", index: 0, count: 1,
                transfer: String(repeating: "ef", count: 16)),
            model: model)
        #expect(reply.ok)
        #expect(
            await RemoteCommands.execute(
                RemoteRequest(challenge: "test", sequence: 2, action: "key", tabID: tab.id.uuidString, text: "enter"),
                model: model
            ).ok)
        for _ in 0..<100 {
            if (try? String(contentsOf: received, encoding: .utf8))?.contains(".png") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pasted = try String(contentsOf: received, encoding: .utf8)
        #expect(pasted.contains(".png"))
        #expect(pasted.hasSuffix(" ") || pasted.contains(".png "))
        #expect(FileManager.default.fileExists(atPath: pasted.trimmingCharacters(in: .whitespaces)))
        tab.terminateAndWait()
    }

    @Test @MainActor func qrIsDecodableAndURLValidationIsStrict() throws {
        for address in [
            "https://example.com/path", "https://user:password@example.com", "https://example.com?token=x",
            "https://example.com/#key=x", "http://192.168.1.5", "file:///tmp/a",
        ] {
            #expect(RemoteControl.origin(address) == nil)
        }
        #expect(RemoteControl.origin("https://example.com/")?.absoluteString == "https://example.com")
        #expect(RemoteControl.origin(RemoteControl.productionOrigin)?.absoluteString == RemoteControl.productionOrigin)
        #expect(RemoteControl.productionOrigin == "https://remote.sigilapp.dev")
        #expect(RemoteControl.preferredOrigin(RemoteControl.legacyRailwayOrigin) == RemoteControl.productionOrigin)
        #expect(
            RemoteControl.preferredOrigin("https://sidereal-production-587c.up.railway.app/")
                == RemoteControl.productionOrigin)
        #expect(
            RemoteControl.preferredOrigin("  https://sidereal-production-587c.up.railway.app  ")
                == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin(RemoteControl.legacyApexOrigin) == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://sigilapp.dev/") == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://SIGILAPP.DEV") == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://sigilapp.dev:443") == RemoteControl.productionOrigin)
        #expect(RemoteControl.origin("https://SIGILAPP.DEV")?.absoluteString == RemoteControl.legacyApexOrigin)
        #expect(RemoteControl.origin("https://sigilapp.dev:443")?.absoluteString == RemoteControl.legacyApexOrigin)
        #expect(RemoteControl.preferredOrigin(RemoteControl.productionOrigin) == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://example.com") == "https://example.com")
        let value =
            "https://example.com/#room=\(String(repeating: "a", count: 32))&key=\(String(repeating: "b", count: 64))"
        let image = try #require(RemoteControlView.qrImage(value))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        #expect(request.results?.first?.payloadStringValue == value)
    }

    @Test @MainActor func visibleTabsKeepsASelectedTabBeyondTheFirstHundred() {
        let tabs = (0..<101).map { RemoteState.Tab(id: "tab-\($0)", title: "Tab \($0)", status: "idle") }
        let visible = RemoteCommands.visibleTabs(tabs, selectedID: "tab-100")
        #expect(visible.count == 100)
        #expect(visible.last?.id == "tab-100")
        #expect(Set(visible.map(\.id)).count == 100)
        #expect(visible.prefix(99).map(\.id) == tabs.prefix(99).map(\.id))
        #expect(tabs.count == 101)
        let few = Array(tabs.prefix(50))
        #expect(RemoteCommands.visibleTabs(few, selectedID: "tab-10").map(\.id) == few.map(\.id))
        #expect(RemoteCommands.visibleTabs(few, selectedID: "missing").map(\.id) == few.map(\.id))
    }

    @Test @MainActor func boundedStringsCutOnScalarBoundariesWithoutReplacementCharacters() {
        let cut = RemoteCommands.bounded(String(repeating: "é", count: 60), bytes: 97)
        #expect(cut == String(repeating: "é", count: 48))
        #expect(!cut.contains("\u{FFFD}"))
        #expect(cut.utf8.count <= 97)
        let tail = RemoteCommands.boundedSuffix("start-" + String(repeating: "\u{1D11E}", count: 10), bytes: 18)
        #expect(tail == String(repeating: "\u{1D11E}", count: 4))
        #expect(!tail.contains("\u{FFFD}"))
        #expect(tail.utf8.count <= 18)
        #expect(RemoteCommands.bounded("héllo", bytes: 3) == "hé")
        #expect(RemoteCommands.bounded("short", bytes: 96) == "short")
        #expect(RemoteCommands.boundedSuffix("end", bytes: 12_000) == "end")
        #expect(RemoteCommands.bounded("abc", bytes: 0) == "")
        #expect(RemoteCommands.boundedSuffix("abc", bytes: 0) == "")
    }

    @Test @MainActor func stopRevokesPendingStartup() async {
        let remote = RemoteControl(store: InMemoryRemotePairingStore())
        let model = AppModel(pairingStore: InMemoryRemotePairingStore())
        remote.start(urlText: "http://127.0.0.1:1", model: model)
        remote.stop()
        await Task.yield()
        #expect(!remote.isEnabled)
        #expect(remote.pairingURL == nil)
        #expect(remote.error == nil)
    }

    @Test @MainActor func phoneListsChatsAndProjectsWithoutTranscripts() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let widget = try fixture.directory("widget-folder")
        let other = try fixture.directory("other-folder")
        let archivedFolder = try fixture.directory("archived-folder")
        let desktop = try fixture.directory("desktop-folder")
        fixture.settings.defaultDirectory = desktop.path
        fixture.settings.focusedProjectPath = ""
        fixture.settings.showWorktreeSessions = true
        let widgetID = "widget-session"
        let otherID = "other-session"
        let archivedID = "archived-session"
        try fixture.writeSession(
            id: widgetID, cwd: widget.path, summary: "Fix the widget",
            updatedAt: "2026-08-03T00:00:00Z", secret: "SECRET_TRANSCRIPT_WIDGET")
        try fixture.writeSession(
            id: otherID, cwd: other.path, summary: "Unrelated notes",
            updatedAt: "2026-08-02T00:00:00Z", secret: "SECRET_TRANSCRIPT_OTHER")
        try fixture.writeSession(
            id: archivedID, cwd: archivedFolder.path, summary: "Archived router notes",
            updatedAt: "2026-08-01T00:00:00Z", secret: "SECRET_TRANSCRIPT_ARCHIVED")
        fixture.settings.archivedConversations = [
            OpenTabsSnapshot.Entry(sessionID: archivedID, cwd: archivedFolder.path)
        ]
        await fixture.store.reload()
        #expect(fixture.model.store.sessions.count == 3)

        let byTitle = await fixture.command("chats", text: "widget")
        #expect(byTitle.ok)
        let titleHits = try #require(byTitle.chats)
        #expect(titleHits.count == 1)
        #expect(titleHits[0].id == widgetID)
        #expect(titleHits[0].title == "Fix the widget")
        #expect(titleHits[0].folder == widget.path)
        let titleJSON = try encoded(byTitle)
        #expect(!titleJSON.contains("SECRET_TRANSCRIPT"))
        #expect(!titleJSON.contains("transcript"))

        let byFolder = await fixture.command("chats", text: "other-folder")
        #expect(byFolder.chats?.map(\.id) == [otherID])

        let archived = await fixture.command("chats", text: "router")
        #expect(archived.chats?.map(\.id) == [archivedID])

        let projects = await fixture.command("projects")
        #expect(projects.ok)
        let folders = try #require(projects.projects)
        #expect(folders.contains { $0.name == "widget-folder" && $0.folder == widget.path })
        #expect(folders.contains { $0.name == "other-folder" && $0.folder == other.path })
        #expect(!folders.contains { $0.folder == archivedFolder.path })
        let projectJSON = try encoded(projects)
        #expect(!projectJSON.contains("SECRET_TRANSCRIPT"))
        #expect(!projectJSON.contains("Fix the widget"))
        #expect(!projectJSON.contains("session_summary"))

        try fixture.writeSession(
            id: "scratch-session", cwd: "/tmp/sigil-scratch-\(UUID().uuidString)",
            summary: "Hidden scratch chat", updatedAt: "2026-08-04T00:00:00Z",
            secret: "SECRET_TRANSCRIPT_SCRATCH")
        await fixture.store.reload()
        fixture.settings.showWorktreeSessions = false
        #expect(await fixture.command("chats", text: "Hidden scratch").chats?.isEmpty == true)
        fixture.settings.showWorktreeSessions = true
        #expect(await fixture.command("chats", text: "Hidden scratch").chats?.map(\.id) == ["scratch-session"])
        fixture.settings.showWorktreeSessions = false

        let beforeOpen = fixture.model.tabs.count
        let opened = await fixture.command("open", text: widget.path, name: widgetID)
        #expect(opened.ok)
        #expect(fixture.model.tabs.count == beforeOpen + 1)
        let tab = try #require(fixture.model.tabs.first { $0.sessionID == widgetID })
        #expect(GrokPaths.canonicalPath(tab.workingDirectory.path) == GrokPaths.canonicalPath(widget.path))
        let again = await fixture.command("open", text: widget.path, name: widgetID)
        #expect(again.ok)
        #expect(fixture.model.tabs.count == beforeOpen + 1)
        #expect(await !fixture.command("open", text: widget.path, name: "missing-session").ok)
        #expect(fixture.model.tabs.count == beforeOpen + 1)

        let remembered = fixture.settings.defaultDirectory
        let focused = fixture.settings.focusedProjectPath
        let started = await fixture.command("new", text: other.path)
        #expect(started.ok)
        let created = try #require(fixture.model.selectedTab)
        #expect(GrokPaths.canonicalPath(created.workingDirectory.path) == GrokPaths.canonicalPath(other.path))
        #expect(fixture.settings.defaultDirectory == remembered)
        #expect(fixture.settings.focusedProjectPath == focused)
        let count = fixture.model.tabs.count
        #expect(await !fixture.command("new", text: "/no/such/sigil-project").ok)
        #expect(fixture.model.tabs.count == count)
        #expect(fixture.settings.defaultDirectory == remembered)
    }

    @Test @MainActor func phoneOpenAndNewFailWithoutAlertWhenFolderOrCLIIsGone() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let gone = try fixture.directory("gone-folder")
        let kept = try fixture.directory("kept-folder")
        fixture.settings.showWorktreeSessions = true
        try fixture.writeSession(
            id: "gone-session", cwd: gone.path, summary: "Deleted worktree",
            updatedAt: "2026-08-03T00:00:00Z", secret: "x")
        try fixture.writeSession(
            id: "kept-session", cwd: kept.path, summary: "Still here",
            updatedAt: "2026-08-02T00:00:00Z", secret: "x")
        await fixture.store.reload()
        try FileManager.default.removeItem(at: gone)

        let open = await fixture.command("open", text: gone.path, name: "gone-session")
        #expect(!open.ok)
        #expect(open.error == "Restore the folder on your Mac, then try again.")
        let new = await fixture.command("new", text: gone.path)
        #expect(!new.ok)
        #expect(new.error == "Restore the folder on your Mac, then try again.")
        fixture.settings.focusedProjectPath = gone.path
        #expect(await !fixture.command("new").ok)
        fixture.settings.focusedProjectPath = ""

        fixture.settings.executablePath = fixture.root.appendingPathComponent("missing-grok").path
        let noCLI = await fixture.command("open", text: kept.path, name: "kept-session")
        #expect(!noCLI.ok)
        #expect(noCLI.error == "Restore the Grok CLI on your Mac, then try again.")

        #expect(fixture.model.tabs.isEmpty)
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func phoneNewSessionUsesTheChosenModelAndEffort() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("chosen")
        try fixture.writeSession(
            id: "chosen-session", cwd: folder.path, summary: "Chosen", updatedAt: "2026-09-01T00:00:00Z", secret: "x")
        await fixture.store.reload()

        let options = try #require(await fixture.command("options").options)
        #expect(options.providers.map(\.id) == CLIProvider.allCases.map(\.rawValue))
        #expect(options.providers.filter(\.takesModel).map(\.id) == [CLIProvider.grokBuild.rawValue])
        #expect(options.providers.allSatisfy { $0.problem == nil })
        #expect(options.models.starts(with: GrokModelCatalog.fallback))
        #expect(options.locations.map(\.folder).contains(fixture.root.path))

        let started = await fixture.command(
            "new", text: folder.path, provider: CLIProvider.grokBuild.rawValue, model: "grok-4.6", effort: "high")
        #expect(started.ok)
        let tab = try #require(fixture.model.selectedTab)
        #expect(tab.spec.provider == .grokBuild)
        #expect(tab.spec.model == "grok-4.6")
        #expect(tab.spec.reasoningEffort == "high")
        let count = fixture.model.tabs.count
        #expect(await !fixture.command("new", text: folder.path, provider: "grokBuild", model: "--yolo").ok)
        #expect(await !fixture.command("new", text: folder.path, provider: "grokBuild", effort: "max").ok)
        #expect(await !fixture.command("new", text: folder.path, provider: "someOtherCLI").ok)
        #expect(fixture.model.tabs.count == count)
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func phoneCreatesProjectsAndStartsInAddedOnes() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        fixture.settings.showWorktreeSessions = true
        let existing = try fixture.directory("existing")
        try fixture.writeSession(
            id: "existing-session", cwd: existing.path, summary: "Existing", updatedAt: "2026-09-01T00:00:00Z",
            secret: "x")
        await fixture.store.reload()
        // Added on the Mac, with no chat yet.
        let added = try fixture.directory("added")
        fixture.model.addProject(added)
        #expect(await fixture.command("projects").projects?.contains { $0.folder == added.path } == true)
        #expect(await fixture.command("new", text: added.path).ok)

        let created = await fixture.command("createProject", text: fixture.root.path, name: " fresh ")
        #expect(created.ok)
        let project = try #require(created.project)
        let fresh = fixture.root.appendingPathComponent("fresh")
        #expect(project.name == "fresh")
        #expect(project.folder == fresh.path)
        #expect(AppModel.isUsableDirectory(fresh))
        #expect(await fixture.command("projects").projects?.first?.folder == fresh.path)
        #expect(await fixture.command("new", text: project.folder).ok)
        #expect(
            GrokPaths.canonicalPath(try #require(fixture.model.selectedTab).workingDirectory.path)
                == GrokPaths.canonicalPath(fresh.path))
        #expect(await fixture.command("createProject", text: fixture.root.path, name: "fresh").ok)

        try Data("file".utf8).write(to: fixture.root.appendingPathComponent("a-file"))
        for (parent, name) in [
            (fixture.root.path, "../escape"), (fixture.root.path, ".hidden"), (fixture.root.path, "a/b"),
            (fixture.root.path, ""), (fixture.root.path, "a-file"), ("/usr", "nope"),
        ] {
            #expect(await !fixture.command("createProject", text: parent, name: name).ok, "\(parent) \(name)")
        }
        let escaped = fixture.root.deletingLastPathComponent().appendingPathComponent("escape")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func phoneChatPagesStayWithinOneSlice() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        fixture.settings.showWorktreeSessions = true
        let folder = try fixture.directory("paged")
        for index in 0...40 {
            try fixture.writeSession(
                id: String(format: "paged-%02d", index),
                cwd: folder.path,
                summary: String(format: "Paged chat %02d", index),
                updatedAt: String(format: "2026-09-01T00:%02d:00Z", index),
                secret: "SECRET_PAGE_\(index)")
        }
        await fixture.store.reload()
        let first = await fixture.command("chats", index: 0)
        let second = await fixture.command("chats", index: 40)
        let page = try #require(first.chats)
        let rest = try #require(second.chats)
        #expect(page.count == 40)
        #expect(rest.count == 1)
        #expect(rest[0].title == "Paged chat 00")
        #expect(!page.contains { $0.title == "Paged chat 00" })
        #expect(try encoded(first).contains("SECRET_PAGE") == false)
        let projects = try #require(await fixture.command("projects").projects)
        #expect(projects.count == 1)
        #expect(projects[0].name == "paged")
        #expect(projects[0].folder == folder.path)
    }

    @Test @MainActor func phoneRecentChatsLeaveOutOpenTabs() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("recent")
        for id in ["open-chat", "closed-chat"] {
            try fixture.writeSession(
                id: id, cwd: folder.path, summary: "Recent \(id)", updatedAt: "2026-09-01T00:00:00Z", secret: "x")
        }
        await fixture.store.reload()
        #expect(await fixture.command("open", text: folder.path, name: "open-chat").ok)
        #expect(await fixture.command("chats").chats?.map(\.id) == ["closed-chat"])
        #expect(await fixture.command("chats", text: "open-chat").chats?.map(\.id) == ["open-chat"])
    }

    @Test @MainActor func phoneNewStartsInANewWorktreeWhenSettingsSaySo() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let saved = RemoteCommands.worktreeRoot
        RemoteCommands.worktreeRoot = fixture.root.appendingPathComponent("worktrees")
        defer { RemoteCommands.worktreeRoot = saved }
        let repository = try fixture.directory("repository")
        try git(["init", "-q"], in: repository)
        try git(
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repository
        )
        fixture.model.addProject(repository)

        #expect(fixture.settings.startsInWorktree)
        #expect(await fixture.command("new", text: repository.path).ok)
        let folder = try #require(fixture.model.selectedTab).workingDirectory.path
        #expect(SigilWorktree.projectPath(of: folder, root: RemoteCommands.worktreeRoot) == repository.path)
        #expect(try git(["rev-parse", "--abbrev-ref", "HEAD"], in: URL(fileURLWithPath: folder)).hasPrefix("sigil/"))

        // Stopping Remote while git runs starts nothing.
        let before = fixture.model.tabs.count
        let cancelled = Task { await fixture.command("new", text: repository.path) }
        cancelled.cancel()
        #expect(await !cancelled.value.ok)
        #expect(fixture.model.tabs.count == before)

        fixture.settings.startsInWorktree = false
        #expect(await fixture.command("new", text: repository.path).ok)
        #expect(
            GrokPaths.canonicalPath(try #require(fixture.model.selectedTab).workingDirectory.path) == repository.path)

        // With no commit git cannot add a worktree: the phone hears why and nothing starts.
        fixture.settings.startsInWorktree = true
        let empty = try fixture.directory("empty-repository")
        try git(["init", "-q"], in: empty)
        fixture.model.addProject(empty)
        let count = fixture.model.tabs.count
        let failed = await fixture.command("new", text: empty.path)
        #expect(!failed.ok)
        #expect(failed.error?.hasPrefix("Could not create a worktree.") == true)
        #expect(fixture.model.tabs.count == count)
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func aLongChatPageIsTrimmedInsteadOfReportedEmpty() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        fixture.settings.showWorktreeSessions = true
        let bucket = fixture.root.appendingPathComponent("sessions").appendingPathComponent("wide")
        for index in 0..<40 {
            let id = String(format: "wide-%02d", index)
            let folder = "/" + String(repeating: "p", count: 1_200) + "/wide-\(index)"
            let dir = bucket.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json: [String: Any] = [
                "info": ["id": id, "cwd": folder],
                "session_summary": "Wide \(index)",
                "created_at": "2026-08-01T00:00:00Z",
                "updated_at": String(format: "2026-09-02T00:%02d:00Z", index),
                "num_chat_messages": 4,
            ]
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: dir.appendingPathComponent("summary.json"))
        }
        await fixture.store.reload()
        let reply = await fixture.command("chats", text: "Wide")
        let chats = try #require(reply.chats)
        #expect(reply.ok)
        #expect(!chats.isEmpty)
        #expect(chats.count < 40)
        #expect(reply.chatsTruncated)
        let data = try JSONEncoder().encode(reply)
        #expect(data.count <= 48_000)
        #expect(!String(decoding: data, as: UTF8.self).contains("SECRET_WIDE"))
    }

    @Test @MainActor func anOversizedStateIsShrunkInsteadOfCalledAListFailure() throws {
        let tabs = (0..<100).map { index in
            RemoteState.Tab(
                id: String(format: "tab-%03d", index),
                title: String(repeating: "\"", count: 96),
                status: "working")
        }
        let state = RemoteState(
            tabs: tabs,
            selectedTabID: tabs[0].id,
            terminal: String(repeating: "\n", count: 12_000))
        let reply = RemoteCommands.fitting(
            RemoteReply(challenge: "test", sequence: 1, state: state))
        #expect(reply.ok)
        #expect(reply.error == nil)
        #expect(reply.chats == nil)
        #expect(reply.projects == nil)
        let data = try JSONEncoder().encode(reply)
        #expect(data.count <= 48_000)
    }

    @Test @MainActor func aHugeTerminalDoesNotWipeTheChatList() throws {
        let tabs = (0..<100).map { index in
            RemoteState.Tab(
                id: String(format: "tab-%03d", index),
                title: String(repeating: "\"", count: 96),
                status: "working")
        }
        let state = RemoteState(
            tabs: tabs,
            selectedTabID: tabs[0].id,
            terminal: String(repeating: "\n", count: 12_000))
        let chats = [
            RemoteChat(id: "chat-1", title: "Keep me", folder: "/work/keep")
        ]
        let projects = [
            RemoteProject(name: "Keep", folder: "/work/keep")
        ]
        let reply = RemoteCommands.fitting(
            RemoteReply(
                challenge: "test", sequence: 1, state: state, chats: chats, projects: projects))
        let keptChats = try #require(reply.chats)
        let keptProjects = try #require(reply.projects)
        #expect(reply.ok)
        #expect(reply.error == nil)
        #expect(keptChats.contains { $0.id == "chat-1" })
        #expect(keptProjects.contains { $0.folder == "/work/keep" })
        let data = try JSONEncoder().encode(reply)
        #expect(data.count <= 48_000)
    }

    @Test @MainActor func earlierReplyKeepsTheLiveTail() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let early = "EARLY_MARKER"
        let late = "LATE_MARKER"
        let text =
            early + "\n" + String(repeating: "a", count: 6_000) + "\n"
            + String(repeating: "b", count: 14_000) + "\n" + late + "\n"
        let payload = fixture.root.appendingPathComponent("payload.txt")
        try Data(text.utf8).write(to: payload)
        let script = """
            #!/bin/sh
            cat '\(payload.path)'
            """
        try Data(script.utf8).write(to: fixture.executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.executable.path)
        let tab = try #require(fixture.model.newTab(in: fixture.root))
        var tail = ""
        for _ in 0..<200 {
            tail = tab.controller.remoteSnapshot()
            if !tab.controller.isRunning, tail.contains(late) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tail.contains(late))
        #expect(!tail.contains(early))
        let reply = await fixture.command(
            "earlier",
            text: String(tail.prefix(80)),
            tabID: tab.id.uuidString,
            name: String(tail.suffix(40)),
            index: tail.count)
        #expect(reply.ok)
        let slice = try #require(reply.earlier)
        #expect(slice.contains(early))
        #expect(!slice.contains(late))
        #expect(slice.utf8.count <= 12_000)
        #expect(reply.state?.terminal.contains(late) == true)
        #expect(reply.state?.terminal.contains(early) == false)
        #expect((reply.state?.terminal.utf8.count ?? 0) <= 12_000)
    }
}

@MainActor
final class PhoneCommandFixture {
    let root: URL
    let executable: URL
    let settings: AppSettings
    let store: SessionStore
    let model: AppModel
    /// Alerts AppModel tried to show. A modal alert would block the remote loop.
    let alerts: AlertLog
    private let defaultsName: String

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/sigil-phone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("fake-grok")
        let script = "#!/bin/sh\nsleep 60\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaultsName = "sigil-phone-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        store = SessionStore(root: root.appendingPathComponent("sessions"))
        let alerts = AlertLog()
        self.alerts = alerts
        model = AppModel(
            settings: settings, store: store, presentError: { _ in alerts.count += 1 },
            pairingStore: InMemoryRemotePairingStore(), providerInstallations: fixtureProviderInstallations(executable))
    }

    func cleanup() {
        model.closeAllTabsAndWait()
        store.stop()
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(fileURLWithPath: GrokPaths.canonicalPath(url.path))
    }

    func writeSession(
        id: String, cwd: String, summary: String, updatedAt: String, secret: String
    ) throws {
        let canonical = GrokPaths.canonicalPath(cwd)
        let dir =
            storeRoot
            .appendingPathComponent(GrokPaths.encode(path: canonical))
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "info": ["id": id, "cwd": canonical],
            "session_summary": summary,
            "created_at": "2026-08-01T00:00:00Z",
            "updated_at": updatedAt,
            "num_chat_messages": 4,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent("summary.json"))
        try Data(secret.utf8).write(to: dir.appendingPathComponent("transcript.txt"))
    }

    func command(
        _ action: String, text: String? = nil, tabID: String? = nil, name: String? = nil, index: Int? = nil,
        provider: String? = nil, model chosenModel: String? = nil, effort: String? = nil, worktree: Bool? = nil
    ) async -> RemoteReply {
        await RemoteCommands.execute(
            RemoteRequest(
                challenge: "test", sequence: 1, action: action, tabID: tabID, text: text, name: name, index: index,
                provider: provider, model: chosenModel, effort: effort, worktree: worktree),
            model: model)
    }

    private var storeRoot: URL { root.appendingPathComponent("sessions") }
}

@MainActor
final class AlertLog {
    var count = 0
}

private func encoded(_ reply: RemoteReply) throws -> String {
    let data = try JSONEncoder().encode(reply)
    return String(decoding: data, as: UTF8.self)
}

@Suite(.serialized)
struct RemoteSessionOpsTests {
    @Test @MainActor func tabsCarryProviderFolderAndArchiveability() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("ops-folder")
        let tab = try #require(fixture.model.newTab(in: folder))
        let reply = await fixture.command("state")
        let record = try #require(reply.state?.tabs.first { $0.id == tab.id.uuidString })
        #expect(record.provider == "grokBuild")
        #expect(record.providerName == "Grok Build")
        #expect(record.folder == "ops-folder")
        // No summary has been written, so the store does not know this chat yet.
        #expect(record.canArchive == false)
        #expect(reply.state?.capabilities.contains("screen") == true)
        #expect(reply.state?.capabilities.contains("sessionOps") == true)
        #expect(reply.state?.mac?.isEmpty == false)
    }

    @Test @MainActor func closeRenameAndArchiveFollowTheMac() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("ops-folder")
        fixture.settings.defaultProvider = .claudeCode
        let shell = fixture.root.appendingPathComponent("zsh")
        try "#!/bin/sh\nprintf 'ISOLATED_PROVIDER_READY\\n'\nwhile IFS= read -r line; do :; done\n"
            .write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell.path)
        let oldShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", shell.path, 1)
        defer { if let oldShell { setenv("SHELL", oldShell, 1) } else { unsetenv("SHELL") } }
        let tab = try #require(fixture.model.newTab(in: folder, provider: .claudeCode))
        for _ in 0..<100 where !tab.controller.remoteSnapshot().contains("ISOLATED_PROVIDER_READY") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("ISOLATED_PROVIDER_READY"))
        let id = tab.id.uuidString

        #expect(await fixture.command("rename", tabID: id, name: "  Phone name  ").ok)
        #expect(fixture.model.title(for: tab) == "Phone name")
        #expect(await fixture.command("rename", tabID: id, name: "").ok)
        #expect(fixture.model.title(for: tab) == "Claude Code · ops-folder")
        #expect(await !fixture.command("rename", tabID: id, name: String(repeating: "x", count: 81)).ok)
        #expect(await !fixture.command("rename", tabID: id, name: "bad\u{7}name").ok)

        // A tab with no saved chat cannot be archived, only closed.
        let archived = await fixture.command("archive", tabID: id)
        #expect(!archived.ok)
        #expect(archived.error?.contains("Close this tab") == true)
        #expect(fixture.model.tabs.contains { $0.id == tab.id })

        #expect(await fixture.command("close", tabID: id).ok)
        #expect(!fixture.model.tabs.contains { $0.id == tab.id })
        #expect(await !fixture.command("close", tabID: id).ok)
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func archiveHidesASavedChatAndClosesItsTab() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("archive-folder")
        fixture.settings.showEmptySessions = true
        let tab = try #require(fixture.model.newTab(in: folder))
        let sessionID = try #require(tab.sessionID)
        try fixture.writeSession(
            id: sessionID, cwd: folder.path, summary: "Archive me", updatedAt: "2026-08-03T00:00:00Z", secret: "S")
        await fixture.store.reload()
        let before = await fixture.command("state")
        #expect(before.state?.tabs.first?.canArchive == true)
        #expect(await fixture.command("archive", tabID: tab.id.uuidString).ok)
        #expect(fixture.model.tabs.isEmpty)
        let session = try #require(fixture.model.store.sessions.first { $0.id == sessionID })
        #expect(fixture.model.isArchived(session))
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func watchAndRowsReturnStyledScreens() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("screen-folder")
        let script =
            "#!/bin/sh\nfor i in $(seq 1 30); do echo \"row $i\"; done\nprintf '\\033[32mGREEN\\033[0m\\n'\nsleep 60\n"
        try Data(script.utf8).write(to: fixture.executable)
        let tab = try #require(fixture.model.newTab(in: folder))
        for _ in 0..<200 {
            if tab.controller.remoteSnapshot().contains("GREEN") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let watched = await fixture.command("watch")
        let screen = try #require(watched.state?.screen)
        #expect(watched.state?.terminal == "")
        #expect(screen.palette?.count == 16)
        let green = try #require(screen.rows.first { $0.t == "GREEN" })
        #expect(green.s == [[0, 5, 2, -1, 0]])
        #expect(screen.rows.contains { $0.t == "row 30" })
        #expect(screen.end == screen.rows.last!.i + 1)

        let older = await fixture.command("rows", tabID: tab.id.uuidString, index: green.i)
        let rows = try #require(older.state?.screen?.rows)
        #expect(rows.last?.t == "row 30")
        #expect(rows.last?.i == green.i - 1)
        #expect(older.state?.screen?.gen == screen.gen)
        #expect(await !fixture.command("rows", tabID: tab.id.uuidString, index: 0).ok)
    }

    @Test @MainActor func unverifiedTerminalHintsRejectStructuredAnswersButKeepRawControls() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("prompt-folder")
        let received = fixture.root.appendingPathComponent("received")
        let script = """
            #!/bin/sh
            stty -echo
            printf 'Do you want to proceed?\n'
            printf '❯ 1. Yes\n  2. Yes, and always\n  3. No, and tell Claude what to do differently (esc)\n'
            while IFS= read -r line; do printf '%s' "$line" > '\(received.path)'; done
            """
        try Data(script.utf8).write(to: fixture.executable)
        let tab = try #require(fixture.model.newTab(in: folder))
        for _ in 0..<200 {
            if tab.controller.remoteSnapshot().contains("3. No") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = try #require(await fixture.command("state").state)
        let prompt = try #require(state.prompt)
        #expect(prompt.question == "Do you want to proceed?")
        #expect(prompt.choices.map(\.key) == ["1", "2", "3"])
        #expect(prompt.yes == "1" && prompt.no == nil)
        #expect(prompt.verified == false)
        #expect(prompt.sessionID?.contains(tab.id.uuidString) == true)

        let id = tab.id.uuidString
        #expect(await !fixture.command("answer", text: "7", tabID: id, name: prompt.id).ok)
        #expect(await !fixture.command("answer", text: "rm -rf /", tabID: id, name: prompt.id).ok)
        // A tap meant for another question, or for none, types nothing.
        #expect(await !fixture.command("answer", text: "2", tabID: id, name: "stale").ok)
        #expect(await !fixture.command("answer", text: "2", tabID: id).ok)
        #expect(await !fixture.command("answer", text: "2", tabID: id, name: prompt.id).ok)
        #expect(await !fixture.command("answer", text: "2", tabID: id, name: prompt.id).ok)
        #expect(await !fixture.command("answer", text: "enter", tabID: id, name: prompt.id).ok)
        #expect(!FileManager.default.fileExists(atPath: received.path))
        // A consciously chosen ordinary terminal action remains available.
        #expect(await fixture.command("input", text: "2", tabID: id).ok)
        #expect(RemoteCommands.prompt(for: tab) == nil)
        _ = await fixture.command("key", text: "enter", tabID: id)
        for _ in 0..<100 {
            if (try? String(contentsOf: received, encoding: .utf8)) == "2" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: received, encoding: .utf8) == "2")
        #expect(fixture.alerts.count == 0)
    }

    @Test @MainActor func repeatedAndReplacedTerminalMenusInvalidateDelayedAnswers() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let folder = try fixture.directory("interaction-folder")
        let received = fixture.root.appendingPathComponent("received")
        let script = """
            #!/bin/sh
            stty -echo
            show() { printf '\\033[2J\\033[H%s\\nProceed?\\n1. Yes\\n2. No\\n' "$1"; }
            show 'git status'
            while IFS= read -r line; do
                case "$line" in
                    repeat) show 'git status';;
                    replace) show 'rm -rf build';;
                    *) printf '%s' "$line" >> '\(received.path)';;
                esac
            done
            """
        try Data(script.utf8).write(to: fixture.executable)
        let tab = try #require(fixture.model.newTab(in: folder))
        for _ in 0..<200 {
            if tab.controller.remoteSnapshot().contains("2. No") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let first = try #require(RemoteCommands.prompt(for: tab))
        #expect(RemoteCommands.prompt(for: tab)?.id == first.id)
        let revision = tab.controller.remoteInteractionRevision
        tab.controller.send(text: "repeat\r")
        #expect(RemoteCommands.prompt(for: tab) == nil)
        for _ in 0..<200 {
            if tab.controller.remoteInteractionRevision > revision + 1,
                !tab.controller.remoteInteractionAfterInput
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let repeated = try #require(RemoteCommands.prompt(for: tab))
        #expect(repeated.question == first.question)
        #expect(repeated.id != first.id)
        #expect(await !fixture.command("answer", text: "1", tabID: tab.id.uuidString, name: first.id).ok)
        tab.controller.send(text: "replace\r")
        for _ in 0..<200 {
            if tab.controller.remoteSnapshot().contains("rm -rf build") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let replaced = try #require(RemoteCommands.prompt(for: tab))
        #expect(replaced.operation?.contains("rm -rf build") == true)
        #expect(replaced.id != repeated.id)
        #expect(await !fixture.command("answer", text: "1", tabID: tab.id.uuidString, name: repeated.id).ok)
        let other = try #require(fixture.model.newTab(in: folder))
        #expect(await !fixture.command("answer", text: "1", tabID: other.id.uuidString, name: replaced.id).ok)
        #expect(!FileManager.default.fileExists(atPath: received.path))
    }

    @Test @MainActor func projectsSayWhetherAWorktreeCanStartThere() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo-folder")
        let plain = try fixture.directory("plain-folder")
        fixture.settings.showWorktreeSessions = true
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fixture.writeSession(
            id: "r", cwd: repo.path, summary: "Repo", updatedAt: "2026-08-03T00:00:00Z", secret: "S")
        try fixture.writeSession(
            id: "p", cwd: plain.path, summary: "Plain", updatedAt: "2026-08-02T00:00:00Z", secret: "S")
        await fixture.store.reload()
        let projects = try #require(await fixture.command("projects").projects)
        #expect(projects.first { $0.folder == repo.path }?.repository == true)
        #expect(projects.first { $0.folder == plain.path }?.repository == false)

        // The phone's toggle wins over the Mac's setting, both ways.
        let saved = RemoteCommands.worktreeRoot
        RemoteCommands.worktreeRoot = fixture.root.appendingPathComponent("worktrees")
        defer { RemoteCommands.worktreeRoot = saved }
        try FileManager.default.removeItem(at: repo.appendingPathComponent(".git"))
        try git(["init", "-q"], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        fixture.settings.startsInWorktree = true
        #expect(await fixture.command("new", text: repo.path, worktree: false).ok)
        #expect(GrokPaths.canonicalPath(try #require(fixture.model.selectedTab).workingDirectory.path) == repo.path)
        fixture.settings.startsInWorktree = false
        #expect(await fixture.command("new", text: repo.path, worktree: true).ok)
        let folder = try #require(fixture.model.selectedTab).workingDirectory.path
        #expect(SigilWorktree.projectPath(of: folder, root: RemoteCommands.worktreeRoot) == repo.path)
        // The tab's folder label needs the real worktree root, so here it is the checkout name.
        let record = try #require(fixture.model.tabs.first { $0.workingDirectory.path == folder })
        let shown = RemoteCommands.tabRecords(fixture.model).first { $0.id == record.id.uuidString }?.folder
        #expect(shown == URL(fileURLWithPath: folder).lastPathComponent)
    }
}

private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
