import Foundation
import Testing
import os

@testable import SigilKit

@Suite struct ConversationNotesIndexTests {
    @Test func nineHundredSessionsWithOneHundredNotesSearchWithoutReads() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let sessions = (0..<900).map { fixture.session("note-\($0)") }
        for session in sessions.prefix(100) { try fixture.write("Zirconia café", for: session.reference) }
        let meter = NoteIndexMeter()
        let catalog = ConversationNotesIndex.catalog(root: fixture.root, references: Set(sessions.map(\.reference)))
        let index = try #require(ConversationNotesIndex.scan(catalog: catalog, reader: meter.reader))
        #expect(meter.counts.reads == 100)
        let keys = SessionScanner.searchKeys(for: sessions)
        let before = meter.counts
        for query in ["zirconia", "CAFE", "zirconia cafe", "missing"] {
            let found = SessionScanner.search(
                query, sessions: sessions, keys: keys, foldedNotes: { index.foldedNote(for: $0.reference) })
            #expect(found.count == (query == "missing" ? 0 : 100))
        }
        #expect(meter.counts == before)
        let warm = try #require(ConversationNotesIndex.scan(catalog: catalog, cache: index.cache, reader: meter.reader))
        #expect(warm.folded == index.folded)
        #expect(meter.counts.reads == 100)
    }

    @Test func identitiesIncludeProviderAndCanonicalFolder() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let second = fixture.root.appendingPathComponent("second-project")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let alias = fixture.root.appendingPathComponent("alias-project")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.project)
        let id = "11111111-1111-4111-8111-111111111111"
        let refs = [
            fixture.session(id).reference, fixture.session(id, cwd: second.path).reference,
            fixture.session(id, provider: .codex).reference, fixture.session(id, provider: .claudeCode).reference,
            fixture.session(id, cwd: alias.path).reference,
        ]
        for (reference, text) in zip(refs.prefix(4), ["grok first", "grok second", "codex", "claude"]) {
            try fixture.write(text, for: reference)
        }
        try Data("ambiguous flat".utf8).write(to: fixture.root.appendingPathComponent(id + ".md"))
        let backup = fixture.file(refs[0]).deletingLastPathComponent().appendingPathComponent(id + ".conflict-1-0.md")
        try Data("excluded conflict".utf8).write(to: backup)
        let meter = NoteIndexMeter()
        let catalog = ConversationNotesIndex.catalog(root: fixture.root, references: Set(refs))
        let index = try #require(ConversationNotesIndex.scan(catalog: catalog, reader: meter.reader))
        #expect(index.catalog.items.count == 4)
        #expect(
            refs.map { index.foldedNote(for: $0) } == ["grok first", "grok second", "codex", "claude", "grok first"])
        #expect(meter.counts.reads == 4)
        #expect(try String(contentsOf: backup, encoding: .utf8) == "excluded conflict")
    }

    @Test func flatNotesAreReadOnlyAndAmbiguityNeverChoosesAFolder() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let second = fixture.root.appendingPathComponent("second-project")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let first = fixture.session("shared").reference
        let other = fixture.session("shared", cwd: second.path).reference
        let flat = fixture.root.appendingPathComponent("shared.md")
        try Data("flat zirconia".utf8).write(to: flat)
        let ambiguous = ConversationNotesIndex.catalog(root: fixture.root, references: [first, other])
        let omitted = try #require(ConversationNotesIndex.scan(catalog: ambiguous))
        #expect(omitted.folded.isEmpty)
        let unique = ConversationNotesIndex.catalog(root: fixture.root, references: [first])
        let indexed = try #require(ConversationNotesIndex.scan(catalog: unique))
        #expect(indexed.foldedNote(for: first) == "flat zirconia")
        #expect(FileManager.default.fileExists(atPath: flat.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.file(first).path))
        let uuid = "11111111-1111-4111-8111-111111111111"
        try Data("grok-only flat".utf8).write(to: fixture.root.appendingPathComponent(uuid + ".md"))
        let native = fixture.session(uuid, provider: .codex).reference
        let nativeOnly = try #require(
            ConversationNotesIndex.scan(
                catalog: ConversationNotesIndex.catalog(root: fixture.root, references: [native])))
        #expect(nativeOnly.foldedNote(for: native) == nil)
    }

    @Test func readsAndUnsavedProjectionsStopAtTheBytePrefix() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let ref = fixture.session("bounded").reference
        let text = "Café " + String(repeating: "x", count: ConversationNotesIndex.byteLimit - 7) + "é hidden-tail"
        try fixture.write(text, for: ref)
        let meter = NoteIndexMeter()
        let index = try #require(
            ConversationNotesIndex.scan(
                catalog: ConversationNotesIndex.catalog(root: fixture.root, references: [ref]), reader: meter.reader))
        let folded = try #require(index.foldedNote(for: ref))
        #expect(folded.hasPrefix("cafe "))
        #expect(!folded.contains("hidden-tail"))
        #expect(meter.counts.bytes == ConversationNotesIndex.byteLimit)
        #expect(ConversationNotesIndex.foldedPrefix(text) == folded)
        #expect(index.foldedNote(for: ref, overlays: [fixture.file(ref).path: "unsaved"]) == "unsaved")
        #expect(index.foldedNote(for: ref, overlays: [fixture.file(ref).path: ""]) == nil)
    }

    @Test func changedAndDeletedFilesInvalidateMetadataCache() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let ref = fixture.session("changed").reference
        try fixture.write("first", for: ref)
        let file = fixture.file(ref)
        let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let catalog = ConversationNotesIndex.catalog(root: fixture.root, references: [ref])
        let meter = NoteIndexMeter()
        let first = try #require(ConversationNotesIndex.scan(catalog: catalog, reader: meter.reader))
        try Data("other".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let rewritten = try #require(
            ConversationNotesIndex.scan(catalog: catalog, cache: first.cache, reader: meter.reader))
        #expect(rewritten.foldedNote(for: ref) == "other")
        #expect(meter.counts.reads == 2)
        try Data("third".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let replaced = try #require(
            ConversationNotesIndex.scan(catalog: catalog, cache: rewritten.cache, reader: meter.reader))
        #expect(replaced.foldedNote(for: ref) == "third")
        #expect(meter.counts.reads == 3)
        try FileManager.default.removeItem(at: file)
        let deleted = try #require(
            ConversationNotesIndex.scan(catalog: catalog, cache: replaced.cache, reader: meter.reader))
        #expect(deleted.folded.isEmpty && deleted.cache.isEmpty)
    }

    @Test func failedReadsRetryAndCancelledScansCannotPublish() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let ref = fixture.session("race").reference
        try fixture.write("current", for: ref)
        let catalog = ConversationNotesIndex.catalog(root: fixture.root, references: [ref])
        let unavailable = ConversationNotesIndex.Reader(
            metadata: ConversationNotesIndex.Reader.disk.metadata, read: { _, _ in nil })
        let failed = try #require(ConversationNotesIndex.scan(catalog: catalog, reader: unavailable))
        #expect(failed.cache.isEmpty && failed.folded.isEmpty)
        let recovered = try #require(ConversationNotesIndex.scan(catalog: catalog, cache: failed.cache))
        #expect(recovered.foldedNote(for: ref) == "current")
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let reader = ConversationNotesIndex.Reader(
            metadata: ConversationNotesIndex.Reader.disk.metadata,
            read: { url, stamp in
                let bytes = ConversationNotesIndex.Reader.disk.read(url, stamp)
                cancelled.withLock { $0 = true }
                return bytes
            })
        #expect(
            ConversationNotesIndex.scan(catalog: catalog, reader: reader, isCancelled: { cancelled.withLock { $0 } })
                == nil)
    }

    @Test func symlinksAndMalformedUTF8DoNotBecomeMatches() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let ref = fixture.session("link").reference
        let target = fixture.root.appendingPathComponent("outside.md")
        try Data("excluded".utf8).write(to: target)
        let file = fixture.file(ref)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let catalog = ConversationNotesIndex.catalog(root: fixture.root, references: [ref])
        #expect(try #require(ConversationNotesIndex.scan(catalog: catalog)).folded.isEmpty)
        try FileManager.default.removeItem(at: file)
        try Data([0xFF, 0xFE]).write(to: file)
        #expect(try #require(ConversationNotesIndex.scan(catalog: catalog)).folded.isEmpty)
        for invalid: [UInt8] in [[0xFF], [0xE0, 0x80], [0xED, 0xA0], [0xF0, 0x80], [0xF4, 0x90]] {
            var malformedBoundary = Data(repeating: 0x61, count: ConversationNotesIndex.byteLimit - invalid.count)
            malformedBoundary.append(contentsOf: invalid + [0x61])
            try malformedBoundary.write(to: file)
            #expect(try #require(ConversationNotesIndex.scan(catalog: catalog)).folded.isEmpty)
        }
    }

    @Test(arguments: ["é", "界", "🪐"])
    func everyMultibytePrefixBoundaryKeepsOnlyCompleteScalars(_ scalar: String) throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let ref = fixture.session("unicode").reference
        for partial in 1..<scalar.utf8.count {
            let text = String(repeating: "a", count: ConversationNotesIndex.byteLimit - partial) + scalar + "tail"
            try fixture.write(text, for: ref)
            let index = try #require(
                ConversationNotesIndex.scan(
                    catalog:
                        ConversationNotesIndex.catalog(root: fixture.root, references: [ref])))
            let expected = String(repeating: "a", count: ConversationNotesIndex.byteLimit - partial)
            #expect(index.foldedNote(for: ref) == expected)
            #expect(ConversationNotesIndex.foldedPrefix(text) == expected)
        }
    }

    @Test func malformedIdentitiesNeverInspectNotePaths() throws {
        let fixture = try NoteIndexFixture()
        defer { fixture.cleanup() }
        let sessions = [
            fixture.session("../escape"), fixture.session(""),
            fixture.session("valid", cwd: "relative"), fixture.session("not-a-uuid", provider: .codex),
        ]
        let meter = NoteIndexMeter()
        let index = try #require(
            ConversationNotesIndex.scan(
                catalog:
                    ConversationNotesIndex.catalog(root: fixture.root, references: Set(sessions.map(\.reference))),
                reader: meter.reader))
        #expect(index.catalog.items.isEmpty && index.folded.isEmpty)
        #expect(meter.counts.metadata == 0 && meter.counts.reads == 0)
    }
}

struct NoteIndexFixture {
    let root: URL
    let project: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Sigil-NotesIndex-\(UUID())")
        project = root.appendingPathComponent("generated-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func session(_ id: String, cwd: String? = nil, provider: CLIProvider = .grokBuild) -> GrokSession {
        GrokSession(
            id: id, cwd: cwd ?? project.path, summary: "Weekly", createdAt: .distantPast,
            updatedAt: .distantPast, messageCount: 4, modelID: nil, agentName: nil, reasoningEffort: nil,
            directory: root, provider: provider)
    }
    func file(_ ref: ProviderSessionReference) -> URL {
        let folder = GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(ref.cwd))
        let base = ref.provider == .grokBuild ? root : root.appendingPathComponent(ref.provider.rawValue)
        return base.appendingPathComponent(folder).appendingPathComponent(ref.sessionID + ".md")
    }
    func write(_ text: String, for ref: ProviderSessionReference) throws {
        let file = file(ref)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}

final class NoteIndexMeter: Sendable {
    struct Counts: Equatable {
        var metadata = 0
        var reads = 0
        var bytes = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: Counts())
    var counts: Counts { state.withLock { $0 } }
    var reader: ConversationNotesIndex.Reader {
        .init(
            metadata: { url in
                self.state.withLock { $0.metadata += 1 }
                return ConversationNotesIndex.Reader.disk.metadata(url)
            },
            read: { url, stamp in
                let bytes = ConversationNotesIndex.Reader.disk.read(url, stamp)
                self.state.withLock {
                    $0.reads += 1
                    $0.bytes += bytes?.count ?? 0
                }
                return bytes
            })
    }
}
