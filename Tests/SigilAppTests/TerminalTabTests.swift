import AppKit
import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite("TerminalTab", .serialized)
@MainActor
struct TerminalTabTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func inboxDismissCancelsButProgrammaticRemovalDoesNot() {
        let tab = makeTab()
        var dismissals = 0

        tab.enqueueBridgePrompt(
            "question one",
            requestID: "request-1",
            onDismiss: { dismissals += 1 }
        )
        tab.dismissNextBridgePrompt()
        #expect(dismissals == 1)
        #expect(tab.bridgeInbox.isEmpty)

        tab.enqueueBridgePrompt(
            "question two",
            requestID: "request-2",
            onDismiss: { dismissals += 1 }
        )
        tab.removeBridgePrompt(requestID: "request-2")
        #expect(dismissals == 1)
        #expect(tab.bridgeInbox.isEmpty)
    }

    @Test func removingAStaleQuestionClearsItsUnreadMarker() {
        let tab = makeTab()
        var markerChanges = 0
        tab.onUnseenActivityChange = { markerChanges += 1 }

        tab.enqueueBridgePrompt("question", requestID: "request-1")
        tab.enqueueBridgePrompt("second", requestID: "request-2")
        #expect(tab.hasUnseenActivity)
        #expect(markerChanges == 1)

        tab.removeBridgePrompt(requestID: "request-1")
        #expect(tab.hasUnseenActivity)
        #expect(markerChanges == 1)

        tab.removeBridgePrompt(requestID: "request-2")
        #expect(!tab.hasUnseenActivity)
        #expect(markerChanges == 2)
    }

    @Test func restoringUnreadStateNotifiesTheReplacement() {
        let previous = makeTab()
        previous.enqueueBridgePrompt("unread")
        let replacement = makeTab()
        var markerChanges = 0
        replacement.onUnseenActivityChange = { markerChanges += 1 }

        replacement.restoreUnseenActivity(from: previous)
        replacement.restoreUnseenActivity(from: previous)

        #expect(replacement.hasUnseenActivity)
        #expect(markerChanges == 1)
    }

    @Test func aReplacementKeepsQueuedMessagesButNotQuestions() {
        let previous = makeTab()
        previous.enqueueBridgePrompt("plain")
        previous.enqueueBridgePrompt("question", requestID: "ask-1")
        let replacement = makeTab()

        replacement.restoreUnseenActivity(from: previous)
        replacement.restoreUnseenActivity(from: previous)

        #expect(replacement.bridgeInbox.map(\.prompt) == ["plain"])
        #expect(replacement.hasUnseenActivity)
        replacement.dismissNextBridgePrompt()
        #expect(!replacement.hasUnseenActivity)
    }

    @Test func aReplacementShowsNoUnreadDotForAnAnsweredQuestion() {
        let previous = makeTab()
        previous.enqueueBridgePrompt("question", requestID: "ask-1")
        let replacement = makeTab()

        replacement.restoreUnseenActivity(from: previous)

        #expect(replacement.bridgeInbox.isEmpty)
        #expect(!replacement.hasUnseenActivity)
    }

    @Test func recognizesOnlyGrokBusySpinnerTitles() {
        #expect(TerminalTab.isBusyTerminalTitle("⠼ - Waiting for response… - grok"))
        #expect(TerminalTab.isBusyTerminalTitle("⠹ - Thinking - grok"))
        #expect(TerminalTab.isBusyTerminalTitle("⠋ - Responding - grok"))
        #expect(TerminalTab.isBusyTerminalTitle("⠼ - Waiting for response... - GROK"))

        #expect(!TerminalTab.isBusyTerminalTitle("grok"))
        #expect(!TerminalTab.isBusyTerminalTitle("Thinking - grok"))
        #expect(!TerminalTab.isBusyTerminalTitle("Running unit tests - grok"))
        #expect(!TerminalTab.isBusyTerminalTitle("Request to Reply Only With OK - grok"))
    }

    @Test func readsClaudeCodeAndCodexSpinnerTitles() {
        #expect(TerminalTab.titleShowsWork("◐ Claude Code", provider: .claudeCode) == true)
        #expect(TerminalTab.titleShowsWork("◓ Fix the sidebar", provider: .claudeCode) == true)
        #expect(TerminalTab.titleShowsWork("✳ Claude Code", provider: .claudeCode) == false)
        #expect(TerminalTab.titleShowsWork("Claude Code", provider: .claudeCode) == nil)
        #expect(TerminalTab.titleShowsWork("⠙ Reply hi | sigil", provider: .codex) == true)
        #expect(TerminalTab.titleShowsWork("Reply hi | sigil", provider: .codex) == false)
        #expect(TerminalTab.titleShowsWork("", provider: .codex) == nil)
        #expect(TerminalTab.titleShowsWork("Cursor Agent", provider: .cursor) == nil)
        #expect(TerminalTab.titleShowsWork("⠙ busy", provider: .devin) == nil)
    }

    @Test func ordinaryTitlesAndSilenceNeverCompleteWork() async throws {
        for provider in [CLIProvider.grokBuild, .claudeCode, .codex] {
            let tab = makeTab(provider: provider)
            tab.noteTurnStarted()
            tab.noteTerminalTitle("✳ Claude Code")
            tab.noteTerminalTitle("Task complete")
            tab.noteTerminalOutput()
            try await Task.sleep(for: .milliseconds(1400))
            #expect(tab.activity == (provider == .grokBuild ? .working : .unknown))
            #expect(!tab.hasUnseenActivity)
            tab.terminate()
        }
    }

    @Test func titlesNeverManufactureATurn() {
        let tab = makeTab(provider: .claudeCode)
        tab.noteTerminalTitle("◐ Claude Code")
        #expect(tab.activity == .starting)
        tab.noteTerminalTitle("✳ Claude Code")
        #expect(tab.activity == .starting)
    }

    @Test(arguments: [CLIProvider.claudeCode, .codex, .devin, .cursor, .kimi])
    func unobservableProviderSubmissionRemainsUnknown(provider: CLIProvider) {
        let tab = makeTab(provider: provider)
        #expect(!tab.capabilities.lifecycle)

        tab.noteTurnStarted()

        #expect(tab.activity == .unknown)
        #expect(tab.workingSince == nil)
        #expect(tab.lastSubmittedAt != nil)
        #expect(!tab.isWatchingForCompletion)
        #expect(!tab.hasUnseenActivity)
    }

    @Test func claudeHistoryNeverStartsACompletionWatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("claude.jsonl")
        try Data("{\"type\":\"user\",\"message\":{\"content\":\"fixture\"}}\n".utf8).write(to: journal)
        let tab = makeTab(provider: .claudeCode, completionEventsURL: journal)

        tab.noteTurnStarted()
        tab.noteTurnStarted()

        #expect(!tab.capabilities.lifecycle)
        #expect(tab.activity == .unknown)
        #expect(tab.workingSince == nil)
        #expect(!tab.isWatchingForCompletion)
    }

    @Test(arguments: ["missing", "malformed", "wrong-id", "mixed", "unsupported-version"])
    func unvalidatedCodexHistoryRemainsUnknown(problem: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("codex.jsonl")
        let sessionID = UUID().uuidString.lowercased()
        if problem != "missing" {
            let metadata: Data
            switch problem {
            case "malformed": metadata = Data("not JSON\n".utf8)
            case "wrong-id": metadata = try codexMetadata(sessionID: UUID().uuidString.lowercased())
            case "mixed":
                metadata =
                    try codexMetadata(sessionID: sessionID) + codexMetadata(sessionID: UUID().uuidString.lowercased())
            case "unsupported-version": metadata = try codexMetadata(sessionID: sessionID, version: "1.0.0")
            default: metadata = try codexMetadata(sessionID: sessionID)
            }
            try metadata.write(to: journal)
        }
        let tab = makeCodexTab(journal: journal, sessionID: sessionID)

        #expect(!tab.capabilities.lifecycle)
        tab.noteTurnStarted()

        #expect(tab.activity == .unknown)
        #expect(tab.workingSince == nil)
        #expect(tab.lastSubmittedAt != nil)
        #expect(!tab.isWatchingForCompletion)
    }

    @Test(arguments: ["appended-header", "replacement", "truncation"])
    func validatedCodexHistoryCompletesAndIdentityLossStopsWatching(boundary: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("codex.jsonl")
        let sessionID = UUID().uuidString.lowercased()
        let metadata = try codexMetadata(sessionID: sessionID)
        try metadata.write(to: journal)
        let tab = makeCodexTab(journal: journal, sessionID: sessionID)
        defer { tab.terminate() }
        #expect(tab.capabilities.lifecycle)

        tab.noteTurnStarted()
        #expect(tab.activity == .working)
        #expect(tab.isWatchingForCompletion)
        try append(try codexEvents(turn: "one"), to: journal)
        #expect(await waitUntil { tab.activity == .idle })
        #expect(tab.hasUnseenActivity)
        tab.clearUnseenActivity()

        tab.noteTurnStarted()
        switch boundary {
        case "replacement": try metadata.write(to: journal, options: .atomic)
        case "truncation": try Data().write(to: journal)
        default: try append(metadata, to: journal)
        }
        #expect(await waitUntil { tab.activity == .unknown && !tab.isWatchingForCompletion })
        #expect(!tab.capabilities.lifecycle)
        #expect(tab.workingSince == nil)
        #expect(!tab.hasUnseenActivity)
    }

    @Test func exactProviderJournalCompletesAndDuplicateDoesNotNotifyTwice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        try Data().write(to: journal)
        let tab = makeTab(completionEventsURL: journal)
        tab.noteTurnStarted()
        let records = try events(sessionID: tab.nativeSessionID!)
        try append(records, to: journal)
        #expect(await waitUntil { tab.activity == .idle })
        #expect(tab.hasUnseenActivity)
        tab.clearUnseenActivity()
        try append(records, to: journal)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!tab.hasUnseenActivity)
        tab.terminate()
    }

    @Test func interruptedTurnIsNotCompletionAndOldJournalCannotFinishNextTurn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        try Data().write(to: journal)
        let tab = makeTab(completionEventsURL: journal)
        tab.noteTurnStarted()
        tab.noteInterrupted()
        #expect(tab.activity == .interrupted)
        #expect(!tab.hasUnseenActivity)
        try append(try events(sessionID: tab.nativeSessionID!), to: journal)
        tab.noteTurnStarted()
        try await Task.sleep(for: .milliseconds(400))
        #expect(tab.activity == .working)
        try append(try events(sessionID: tab.nativeSessionID!), to: journal)
        #expect(await waitUntil { tab.activity == .idle })
        tab.terminate()
    }

    @Test func missingJournalRemainsWorkingAndLateFileCanComplete() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        let tab = makeTab(completionEventsURL: journal)
        tab.noteTurnStarted()
        try await Task.sleep(for: .milliseconds(1400))
        #expect(tab.activity == .working)
        try events(sessionID: tab.nativeSessionID!).write(to: journal)
        #expect(await waitUntil { tab.activity == .idle })
        tab.terminate()
    }

    @Test func codexNewTabNeverUsesTabUUIDAsConversationID() {
        #expect(makeTab(provider: .codex).sessionReference == nil)
        let claude = makeTab(provider: .claudeCode)
        #expect(claude.sessionID == "claudeCode:\(claude.nativeSessionID!)")
    }

    @Test func disabledDeliveryKeepsTheQueuedPrompt() {
        let tab = makeTab()
        tab.enqueueBridgePrompt("do not inject yet")
        tab.deliverNextBridgePrompt()
        #expect(tab.bridgeInbox.count == 1)
        #expect(!tab.canDeliverBridgePrompt)
    }

    @Test func failedProviderProcessDoesNotBecomeFinished() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("failed-provider")
        try "#!/bin/sh\nexit 7\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let defaults = UserDefaults(suiteName: "TerminalTabFailure.\(UUID().uuidString)")!
        let tab = TerminalTab(
            spec: GrokLaunchSpec(executable: cli, workingDirectory: directory, mode: .new(sessionID: UUID())),
            settings: AppSettings(defaults: defaults))
        tab.start(isSelected: { false })
        tab.noteTurnStarted()
        #expect(await waitUntil { tab.activity.endedInFailure })
        #expect(tab.activity.statusName == "failed")
        #expect(!tab.hasUnseenActivity)
        tab.terminateAndWait()
    }

    @Test func otherProviderTabsInDifferentFoldersHaveDifferentTitles() {
        let suite = "TerminalTabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        // These tests list chats from the history files directly.
        settings.showOtherAppSessions = true
        func claudeTab(in folder: String) -> TerminalTab {
            TerminalTab(
                spec: GrokLaunchSpec(
                    executable: URL(fileURLWithPath: "/usr/bin/true"),
                    workingDirectory: URL(fileURLWithPath: "/tmp/\(folder)"),
                    mode: .continueLatest,
                    provider: .claudeCode
                ),
                settings: settings
            )
        }

        let api = claudeTab(in: "api")
        let web = claudeTab(in: "web")

        #expect(api.title == "Claude Code · api")
        #expect(web.title == "Claude Code · web")
    }

    private func events(sessionID: String) throws -> Data {
        let timestamp = Int64(Date().addingTimeInterval(0.01).timeIntervalSince1970 * 1000)
        let turn = UUID().uuidString
        let objects: [[String: Any]] = [
            [
                "timestamp": timestamp / 1000,
                "params": [
                    "sessionId": sessionID,
                    "_meta": ["eventId": UUID().uuidString, "promptId": turn, "agentTimestampMs": timestamp],
                    "update": ["sessionUpdate": "agent_message_chunk"],
                ],
            ],
            [
                "timestamp": timestamp / 1000,
                "params": [
                    "sessionId": sessionID, "_meta": ["eventId": UUID().uuidString, "agentTimestampMs": timestamp],
                    "update": ["sessionUpdate": "turn_completed", "prompt_id": turn, "stop_reason": "end_turn"],
                ],
            ],
        ]
        return try objects.reduce(into: Data()) { data, object in
            data.append(try JSONSerialization.data(withJSONObject: object))
            data.append(0x0A)
        }
    }

    private func codexMetadata(sessionID: String, version: String = "0.157.1") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": ["id": sessionID, "cwd": "/tmp", "cli_version": version],
        ]) + Data([0x0A])
    }

    private func codexEvents(turn: String) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(0.01))
        return try ["task_started", "task_complete"].reduce(into: Data()) { data, type in
            data.append(
                try JSONSerialization.data(withJSONObject: [
                    "timestamp": timestamp, "type": "event_msg", "payload": ["type": type, "turn_id": turn],
                ]))
            data.append(0x0A)
        }
    }

    private func makeCodexTab(journal: URL, sessionID: String) -> TerminalTab {
        let suite = "TerminalTabCodex.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TerminalTab(
            spec: GrokLaunchSpec(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                workingDirectory: journal.deletingLastPathComponent(),
                mode: .resume(sessionID: sessionID), provider: .codex, sessionFile: journal),
            settings: AppSettings(defaults: defaults))
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func waitUntil(condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func makeTab(provider: CLIProvider = .grokBuild, completionEventsURL: URL? = nil) -> TerminalTab {
        let suite = "TerminalTabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return TerminalTab(
            spec: GrokLaunchSpec(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                workingDirectory: FileManager.default.temporaryDirectory, mode: .new(sessionID: UUID()),
                provider: provider),
            settings: AppSettings(defaults: defaults), completionEventsURL: completionEventsURL)
    }
}
