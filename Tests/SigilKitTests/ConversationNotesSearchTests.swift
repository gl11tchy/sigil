import Foundation
import Observation
import Testing
import os

@testable import SigilKit

@Suite @MainActor
struct ConversationNotesSearchTests {
    @Test func unsavedEditsInvalidateObservationWithoutScanningPerQuery() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let session = fixture.session("draft")
        let store = ConversationNotesStore(root: fixture.root)
        store.prepareSearch(for: [session])
        try await waitUntil { store.searchPublishedCount > 0 }
        let observed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.foldedNote(for: session.reference)
        } onChange: {
            observed.withLock { $0 = true }
        }
        store.setNote("Café zirconia", for: session.id, cwd: session.cwd)
        #expect(!store.isSaved(for: session.id, cwd: session.cwd))
        #expect(observed.withLock { $0 })
        let scans = store.searchScanCount
        let keys = SessionScanner.searchKeys(for: [session])
        for query in ["cafe", "zirconia", "cafe zirconia"] {
            store.prepareSearch(for: [session])
            #expect(
                SessionScanner.search(
                    query, sessions: [session], keys: keys,
                    foldedNotes: { store.foldedNote(for: $0.reference) }) == [session])
        }
        #expect(store.searchScanCount == scans)
        store.deleteNote(for: session.id, cwd: session.cwd)
        #expect(store.foldedNote(for: session.reference) == nil)
        store.flushNow()
    }

    @Test func externalEditsDeletionAndRecreationRefreshUnopenedNotes() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let session = fixture.session("outside")
        try fixture.write("first", for: session.reference)
        let meter = NoteIndexMeter()
        let store = ConversationNotesStore(root: fixture.root, searchReader: meter.reader)
        store.prepareSearch(for: [session])
        try await waitUntil { store.foldedNote(for: session.reference) == "first" }
        let reads = meter.counts.reads
        let publications = store.searchPublishedCount
        store.invalidateSearchPaths()
        try await waitUntil { store.searchPublishedCount > publications }
        #expect(meter.counts.reads == reads)
        let file = fixture.file(session.reference)
        try Data("replacement".utf8).write(to: file, options: .atomic)
        try await waitUntil { store.foldedNote(for: session.reference) == "replacement" }
        try FileManager.default.removeItem(at: file)
        try await waitUntil { store.foldedNote(for: session.reference) == nil }
        try Data("recreated".utf8).write(to: file, options: .atomic)
        try await waitUntil { store.foldedNote(for: session.reference) == "recreated" }
        // Loading the editor creates its overlay; idle outside changes still win.
        #expect(store.note(for: session.id, cwd: session.cwd) == "recreated")
        try Data("idle update".utf8).write(to: file, options: .atomic)
        try await waitUntil { store.foldedNote(for: session.reference) == "idle update" }
        try FileManager.default.removeItem(at: file)
        try await waitUntil { store.foldedNote(for: session.reference) == nil }
    }

    @Test func inFlightDiskReadCannotReplaceAnUnsavedOverlay() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let session = fixture.session("race")
        try fixture.write("stale disk", for: session.reference)
        let gate = NoteSearchGate()
        defer { gate.release() }
        let store = ConversationNotesStore(root: fixture.root, searchReader: gate.reader)
        store.prepareSearch(for: [session])
        try await waitUntil { gate.entered }
        store.setNote("unsaved zirconia", for: session.id, cwd: session.cwd)
        #expect(!store.isSaved(for: session.id, cwd: session.cwd))
        #expect(store.foldedNote(for: session.reference) == "unsaved zirconia")
        store.prepareSearchQuery("zirconia")
        try await waitUntil { store.matchesSearch(for: session.reference) }
        // The reader is still held: matching only the explicit overlay is independent.
        gate.release()
        try await waitUntil { store.searchPublishedCount > 0 }
        #expect(store.foldedNote(for: session.reference) == "unsaved zirconia")
        store.flushNow()
    }

    @Test func rapidQueryChangesPublishOnlyTheLatestMatches() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let session = fixture.session("query")
        try fixture.write("zirconia café", for: session.reference)
        let store = ConversationNotesStore(root: fixture.root)
        store.prepareSearch(for: [session])
        try await waitUntil { store.searchPublishedCount > 0 }
        store.prepareSearchQuery("zirconia")
        store.prepareSearchQuery("missing")
        store.prepareSearchQuery("cafe zirconia")
        try await waitUntil { store.searchMatchIsCurrent }
        #expect(store.matchesSearch(for: session.reference))
        store.prepareSearchQuery("zirconia missing")
        #expect(!store.matchesSearch(for: session.reference))
        try await waitUntil { store.searchMatchIsCurrent }
        #expect(!store.matchesSearch(for: session.reference))
        store.prepareSearchQuery(" \n ")
        #expect(store.searchMatchIsCurrent && !store.matchesSearch(for: session.reference))
    }

    @Test func changedMembershipCancelsAFormerlyUnambiguousLegacyRead() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let first = fixture.session("shared")
        let other = fixture.session("shared", cwd: fixture.root.appendingPathComponent("second").path)
        let flat = fixture.root.appendingPathComponent("shared.md")
        try Data("legacy zirconia".utf8).write(to: flat)
        let gate = NoteSearchGate()
        defer { gate.release() }
        let store = ConversationNotesStore(root: fixture.root, searchReader: gate.reader)
        store.prepareSearch(for: [first])
        try await waitUntil { gate.entered }
        store.prepareSearch(for: [first, other])
        gate.release()
        try await waitUntil { store.searchPublishedCount > 0 }
        #expect(store.foldedNote(for: first.reference) == nil)
        #expect(store.foldedNote(for: other.reference) == nil)
        #expect(try String(contentsOf: flat, encoding: .utf8) == "legacy zirconia")
        #expect(!FileManager.default.fileExists(atPath: fixture.file(first.reference).path))
    }

    @Test func invalidationDuringAReadDiscardsTheOldSnapshot() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let session = fixture.session("invalidated")
        try fixture.write("old", for: session.reference)
        let gate = NoteSearchGate()
        defer { gate.release() }
        let store = ConversationNotesStore(root: fixture.root, searchReader: gate.reader)
        store.prepareSearch(for: [session])
        try await waitUntil { gate.entered }
        try Data("current".utf8).write(to: fixture.file(session.reference), options: .atomic)
        store.invalidateSearchPaths()
        store.invalidateSearchPaths()
        gate.release()
        try await waitUntil { store.foldedNote(for: session.reference) == "current" }
        #expect(store.searchPublishedCount < store.searchScanCount)
    }

    @Test func retargetedWorkspaceAliasesUseTheirNewCanonicalNote() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let second = fixture.root.appendingPathComponent("second-project")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("project-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.project)
        let first = fixture.session("alias")
        let other = fixture.session("alias", cwd: second.path)
        let displayed = fixture.session("alias", cwd: alias.path)
        try fixture.write("first", for: first.reference)
        try fixture.write("second", for: other.reference)
        let store = ConversationNotesStore(root: fixture.root)
        store.prepareSearch(for: [displayed])
        try await waitUntil { store.foldedNote(for: displayed.reference) == "first" }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
        store.invalidateSearchPaths()
        try await waitUntil { store.foldedNote(for: displayed.reference) == "second" }
    }

    @Test func externalConflictCopiesStayOutsideSearchWhileTheDraftWins() async throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let session = fixture.session("conflict")
        let store = ConversationNotesStore(root: fixture.root)
        store.setNote("original", for: session.id, cwd: session.cwd)
        store.flushNow()
        store.prepareSearch(for: [session])
        try await waitUntil { store.searchPublishedCount > 0 }
        store.setNote("local zirconia", for: session.id, cwd: session.cwd)
        try Data("outside sapphire".utf8).write(to: fixture.file(session.reference), options: .atomic)
        store.flushNow()
        guard case .conflictPreserved(let backup) = store.notice(for: session.id, cwd: session.cwd) else {
            Issue.record("Expected REA-1195 conflict preservation")
            return
        }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "outside sapphire")
        let publications = store.searchPublishedCount
        store.invalidateSearchPaths()
        try await waitUntil { store.searchPublishedCount > publications }
        #expect(store.foldedNote(for: session.reference) == "local zirconia")
        #expect(store.foldedNote(for: session.reference)?.contains("sapphire") == false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

/// Holds only the first background read so tests can mutate the main-actor state.
private final class NoteSearchGate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    private let semaphore = DispatchSemaphore(value: 0)
    var entered: Bool { state.withLock { $0 } }
    func release() { semaphore.signal() }
    var reader: ConversationNotesIndex.Reader {
        .init(
            metadata: ConversationNotesIndex.Reader.disk.metadata,
            read: { url, stamp in
                let bytes = ConversationNotesIndex.Reader.disk.read(url, stamp)
                let first = self.state.withLock { entered in
                    if entered { return false }
                    entered = true
                    return true
                }
                if first { _ = self.semaphore.wait(timeout: .now() + 4) }
                return bytes
            })
    }
}
