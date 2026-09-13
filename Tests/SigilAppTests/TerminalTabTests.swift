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

    @Test func journalUsesOnlyExactEventsAfterTheTurnStarts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        let oldCompletion = Self.completionEvent
        try Data(oldCompletion.utf8).write(to: journal)

        let tab = makeTab(
            mode: .new(sessionID: UUID()),
            completionEventsURL: journal
        )
        tab.noteTurnStarted()
        #expect(tab.activity == .working)

        // This is appended immediately, before the watcher gets a chance to
        // poll. It must still be observed, while the old completion above must
        // not be mistaken for this turn.
        try append(
            #"{"params":{"update":{"sessionUpdate":"tool_call","text":"turn_completed"}}}"#
                + "\n",
            to: journal
        )
        try await Task.sleep(for: .milliseconds(550))
        #expect(tab.activity == .working)

        try append(Self.completionEvent, to: journal)
        let completed = await waitUntil { tab.activity == .idle }

        #expect(completed)
        #expect(tab.hasUnseenActivity)
    }

    @Test func completionAppendedImmediatelyAfterSubmissionIsNotMissed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabFastEventTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        _ = FileManager.default.createFile(atPath: journal.path, contents: nil)
        let tab = makeTab(
            mode: .new(sessionID: UUID()),
            completionEventsURL: journal
        )

        tab.noteTurnStarted()
        try append(Self.completionEvent, to: journal)

        #expect(await waitUntil { tab.activity == .idle })
    }

    @Test func disabledDeliveryKeepsTheQueuedPrompt() {
        let tab = makeTab()
        tab.enqueueBridgePrompt("do not inject yet")

        tab.deliverNextBridgePrompt()

        #expect(tab.bridgeInbox.count == 1)
        #expect(!tab.canDeliverBridgePrompt)
    }

    @Test(
        "submit returns to idle when the journal cannot complete the turn",
        arguments: SilentSubmit.allCases
    )
    func submitReturnsToIdleWhenJournalCannotComplete(_ fixture: SilentSubmit) async throws {
        let (tab, directory) = try makeSilentSubmitTab(fixture)
        defer { if let directory { try? FileManager.default.removeItem(at: directory) } }

        tab.noteTurnStarted()
        #expect(tab.activity == .working)
        #expect(await waitUntil(timeout: .seconds(3)) { tab.activity == .idle })

        // A later submit must not stick in working either.
        tab.noteTurnStarted()
        #expect(tab.activity == .working)
        #expect(await waitUntil(timeout: .seconds(3)) { tab.activity == .idle })
    }

    @Test func ongoingOutputStaysWorkingUntilJournalCompletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabOutputHold.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        _ = FileManager.default.createFile(atPath: journal.path, contents: nil)
        let tab = makeTab(mode: .new(sessionID: UUID()), completionEventsURL: journal)

        tab.noteTurnStarted()
        #expect(tab.activity == .working)

        let holdUntil = ContinuousClock.now + TerminalTab.idleFallbackSilence + .milliseconds(400)
        while ContinuousClock.now < holdUntil {
            tab.noteTerminalOutput()
            #expect(tab.activity == .working)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(tab.activity == .working)

        try append(Self.completionEvent, to: journal)
        #expect(await waitUntil { tab.activity == .idle })

        tab.noteTerminalOutput()
        #expect(tab.activity == .idle)
    }

    @Test func journalWorkRemainsWorkingAcrossOutputSilence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabJournalWork.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        _ = FileManager.default.createFile(atPath: journal.path, contents: nil)
        let tab = makeTab(mode: .new(sessionID: UUID()), completionEventsURL: journal)

        tab.noteTurnStarted()
        #expect(tab.activity == .working)

        try append(
            #"{"params":{"update":{"sessionUpdate":"tool_call"}}}"# + "\n",
            to: journal
        )
        try await Task.sleep(for: TerminalTab.idleFallbackSilence + .milliseconds(400))
        #expect(tab.activity == .working)
        #expect(!tab.hasUnseenActivity)

        try append(Self.completionEvent, to: journal)
        #expect(await waitUntil { tab.activity == .idle })
        #expect(tab.hasUnseenActivity)
    }

    @Test func journalWorkStillIdlesIfCompletionNeverArrives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabJournalFallback.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        _ = FileManager.default.createFile(atPath: journal.path, contents: nil)
        let tab = makeTab(mode: .new(sessionID: UUID()), completionEventsURL: journal)
        tab.journalIdleFallbackSilence = .seconds(2)

        tab.noteTurnStarted()
        try append(
            #"{"params":{"update":{"sessionUpdate":"tool_call"}}}"# + "\n",
            to: journal
        )
        try await Task.sleep(for: TerminalTab.idleFallbackSilence + .milliseconds(400))
        #expect(tab.activity == .working)

        try await Task.sleep(for: tab.journalIdleFallbackSilence)
        #expect(tab.activity == .idle)
        #expect(tab.hasUnseenActivity)
    }

    @Test func stoppedJournalWatchRestartsFromTheCurrentOffset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabCancelledWatch.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        _ = FileManager.default.createFile(atPath: journal.path, contents: nil)
        let tab = makeTab(mode: .new(sessionID: UUID()), completionEventsURL: journal)

        tab.noteTurnStarted()
        #expect(tab.activity == .working)
        await Task.yield()
        tab.terminate()
        try append(Self.completionEvent, to: journal)
        await Task.yield()

        tab.noteTurnStarted()
        #expect(tab.activity == .working)
        try append(
            #"{"params":{"update":{"sessionUpdate":"tool_call"}}}"# + "\n",
            to: journal
        )
        try await Task.sleep(for: TerminalTab.idleFallbackSilence + .milliseconds(400))
        #expect(tab.activity == .working)
        #expect(!tab.hasUnseenActivity)

        try append(Self.completionEvent, to: journal)
        #expect(await waitUntil { tab.activity == .idle })
        #expect(tab.hasUnseenActivity)
    }

    @Test func resumedTabWithoutJournalStillCompletesWhenTheFileAppears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TerminalTabResumeJournal.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("updates.jsonl")
        let tab = makeTab(
            mode: .resume(sessionID: "pre-journal-session"),
            completionEventsURL: journal
        )

        tab.noteTurnStarted()
        #expect(tab.activity == .working)

        // Output keeps the silence fallback from firing so only the watcher
        // can take the tab idle once the journal shows up.
        let holdUntil = ContinuousClock.now + TerminalTab.idleFallbackSilence + .milliseconds(400)
        while ContinuousClock.now < holdUntil {
            tab.noteTerminalOutput()
            #expect(tab.activity == .working)
            try await Task.sleep(for: .milliseconds(200))
        }

        try Data(Self.completionEvent.utf8).write(to: journal)
        #expect(await waitUntil { tab.activity == .idle })
    }

    private static let completionEvent =
        #"{"params":{"update":{"sessionUpdate":"turn_completed"}}}"# + "\n"

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    enum SilentSubmit: String, Sendable, CaseIterable {
        case resumeWithoutJournal
        case emptyPrompt
        case newWithoutJournal
    }

    private func makeSilentSubmitTab(_ fixture: SilentSubmit) throws -> (
        TerminalTab, URL?
    ) {
        switch fixture {
        case .emptyPrompt:
            return (makeTab(), nil)
        case .resumeWithoutJournal, .newWithoutJournal:
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "TerminalTabSilent.\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let journal = directory.appendingPathComponent("updates.jsonl")
            let mode: GrokLaunchSpec.Mode =
                fixture == .resumeWithoutJournal
                ? .resume(sessionID: "pre-journal-session")
                : .new(sessionID: UUID())
            return (makeTab(mode: mode, completionEventsURL: journal), directory)
        }
    }

    private func makeTab(
        mode: GrokLaunchSpec.Mode = .continueLatest,
        completionEventsURL: URL? = nil
    ) -> TerminalTab {
        let suite = "TerminalTabTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let spec = GrokLaunchSpec(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            workingDirectory: FileManager.default.temporaryDirectory,
            mode: mode
        )
        return TerminalTab(
            spec: spec,
            settings: settings,
            completionEventsURL: completionEventsURL
        )
    }
}
