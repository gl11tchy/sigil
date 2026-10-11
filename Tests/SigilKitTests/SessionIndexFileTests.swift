import Darwin
import Foundation
import Testing
import os

@testable import SigilKit

@Suite struct SessionIndexFileTests {
    @Test(arguments: ["default", "system-alias", "grok-id"])
    func restartReusesAllProvidersAndCodexTitlesWithoutBodies(_ variant: String) throws {
        let fixture = try HistoryIndexFixture(
            temporaryRoot: variant == "system-alias" ? URL(fileURLWithPath: "/tmp") : nil,
            grokID: variant == "grok-id" ? "generated-grok-id" : nil)
        defer { fixture.cleanup() }
        let titles = CodexTitleIndexCache()
        let cold = fixture.scan(titles: titles)
        #expect(cold.sessions.count == 3)
        #expect(fixture.file.save(fixture.snapshot(cold.cache, titles: titles)))
        let saved = try #require(fixture.file.load(roots: fixture.roots))
        #expect(saved.entries.values.allSatisfy { !$0.session.isHistoryValidated && $0.contents.isEmpty })
        #expect(saved.entries.values.allSatisfy { $0.claudeScan == nil })
        let bytes = try String(contentsOf: fixture.file.url, encoding: .utf8)
        #expect(!bytes.contains("contents") && !bytes.contains("claudeScan") && !bytes.contains("isHistoryValidated"))
        let freshTitles = CodexTitleIndexCache()
        freshTitles.restoreDisplaySnapshots(saved.titleIndexes)
        let meter = HistoryIndexMeter()
        let unchanged = fixture.scan(cache: saved.entries, titles: freshTitles, meter: meter)
        #expect(unchanged.sessions.count == 3)
        #expect(meter.count == 0)
        #expect(unchanged.sessions.first { $0.provider == .codex }?.summary == "Generated index title")
        #expect(unchanged.sessions.allSatisfy { !$0.isHistoryValidated })

        try FileManager.default.removeItem(at: fixture.claudeFile)
        #expect(fixture.file.load(roots: fixture.roots) != nil)
        try Data("{\"id\":\"\(fixture.id)\",\"thread_name\":\"Changed index title\"}\n".utf8)
            .write(to: fixture.titleFile)
        let changed = fixture.scan(cache: unchanged.cache, titles: freshTitles, meter: meter)
        #expect(changed.sessions.count == 2)
        #expect(changed.sessions.first { $0.provider == .codex }?.summary == "Changed index title")
        #expect(changed.sessions.allSatisfy { !$0.isHistoryValidated })
        #expect(meter.count > 0)
    }

    @Test func privateAtomicWriteAndPreparationFailureKeepLastIndex() throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let snapshot = fixture.snapshot(fixture.scan().cache)
        #expect(fixture.file.save(snapshot))
        let old = try Data(contentsOf: fixture.file.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.file.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let failing = SessionIndexFile(
            url: fixture.file.url,
            beforeCommit: {
                // Temporary titles are private before the atomic replacement, too.
                let parent = fixture.file.url.deletingLastPathComponent()
                let temporary = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                    .first { $0.pathExtension == "tmp" }
                guard let temporary else { throw CocoaError(.fileWriteUnknown) }
                let mode =
                    try FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? NSNumber
                guard mode?.intValue == 0o600 else { throw CocoaError(.fileWriteNoPermission) }
                throw CocoaError(.fileWriteUnknown)
            })
        #expect(!failing.save(snapshot))
        #expect(try Data(contentsOf: fixture.file.url) == old)
        let permissionRace = SessionIndexFile(
            url: fixture.file.url,
            beforeCommit: {
                let temporary = try FileManager.default.contentsOfDirectory(
                    at: fixture.file.url.deletingLastPathComponent(), includingPropertiesForKeys: nil
                )
                .first { $0.pathExtension == "tmp" }!
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
            })
        #expect(!permissionRace.save(snapshot))
        #expect(try Data(contentsOf: fixture.file.url) == old)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.file.url.deletingLastPathComponent().path)
                == ["history-index.json"])
    }

    @Test(arguments: [
        "corrupt", "version", "roots", "escape", "directory", "count", "bytes", "permissions", "date", "authority",
    ])
    func untrustedEnvelopesAreBoundedAndNeverTouchSourceHistory(_ problem: String) throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let snapshot = fixture.snapshot(fixture.scan().cache)
        #expect(fixture.file.save(snapshot))
        let source = try Data(contentsOf: fixture.grokSummary)
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file.url)) as? [String: Any])
        switch problem {
        case "corrupt": try Data("{".utf8).write(to: fixture.file.url)
        case "bytes": try Data(repeating: 0x20, count: SessionIndexFile.byteLimit + 1).write(to: fixture.file.url)
        case "permissions":
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.file.url.path)
        default:
            switch problem {
            case "version": object["version"] = 999
            case "roots": object["roots"] = []
            case "escape":
                var entries = try #require(object["entries"] as? [String: Any])
                entries[fixture.grok.path + "/../outside"] = entries.removeValue(forKey: fixture.grokDirectory.path)
                object["entries"] = entries
            case "count":
                object["entries"] = Dictionary(
                    uniqueKeysWithValues: (0...SessionIndexFile.entryLimit).map {
                        ("/outside/\($0)", (object["entries"] as! [String: Any]).values.first!)
                    })
            case "date":
                var entries = try #require(object["entries"] as? [String: [String: Any]])
                let key = entries.keys.first!
                var entry = entries[key]!
                var session = entry["session"] as! [String: Any]
                session["updatedAt"] = 1e300
                entry["session"] = session
                entries[key] = entry
                object["entries"] = entries
            case "directory":
                var entries = try #require(object["entries"] as? [String: [String: Any]])
                let key = entries.keys.first!
                var entry = entries[key]!
                var session = entry["session"] as! [String: Any]
                let source = URL(fileURLWithPath: key)
                session["directory"] =
                    source.deletingLastPathComponent().absoluteString + "./" + source.lastPathComponent
                entry["session"] = session
                entries[key] = entry
                object["entries"] = entries
            case "authority":
                var entries = try #require(object["entries"] as? [String: [String: Any]])
                for key in Array(entries.keys) {
                    var entry = entries[key]!
                    var session = entry["session"] as! [String: Any]
                    session["isHistoryValidated"] = true
                    entry["session"] = session
                    entries[key] = entry
                }
                object["entries"] = entries
            default: break
            }
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.file.url)
        }
        if problem == "authority" {
            let decoded = try #require(fixture.file.load(roots: fixture.roots))
            #expect(decoded.entries.values.allSatisfy { !$0.session.isHistoryValidated })
        } else {
            #expect(fixture.file.load(roots: fixture.roots) == nil)
        }
        #expect(try Data(contentsOf: fixture.grokSummary) == source)
        #expect(fixture.file.save(snapshot))
        #expect(fixture.file.load(roots: fixture.roots) != nil)
    }

    @Test func symlinksHardlinksAndReplacedParentFailClosed() throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let snapshot = fixture.snapshot(fixture.scan().cache)
        #expect(fixture.file.save(snapshot))
        let victim = fixture.base.appendingPathComponent("victim")
        try Data("unchanged".utf8).write(to: victim)
        try FileManager.default.removeItem(at: fixture.file.url)
        try FileManager.default.createSymbolicLink(at: fixture.file.url, withDestinationURL: victim)
        #expect(fixture.file.load(roots: fixture.roots) == nil)
        #expect(!fixture.file.save(snapshot))
        #expect(try String(contentsOf: victim, encoding: .utf8) == "unchanged")
        try FileManager.default.removeItem(at: fixture.file.url)
        #expect(link(victim.path, fixture.file.url.path) == 0)
        #expect(!fixture.file.save(snapshot))
        try FileManager.default.removeItem(at: fixture.file.url)
        #expect(fixture.file.save(snapshot))
        let parent = fixture.file.url.deletingLastPathComponent()
        let moved = fixture.base.appendingPathComponent("moved-private")
        let racing = SessionIndexFile(
            url: fixture.file.url,
            beforeCommit: {
                try FileManager.default.moveItem(at: parent, to: moved)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            })
        let previous = try Data(contentsOf: fixture.file.url)
        #expect(!racing.save(snapshot))
        #expect(try Data(contentsOf: moved.appendingPathComponent("history-index.json")) == previous)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.url.path))

        try FileManager.default.removeItem(at: fixture.grokSummary)
        try FileManager.default.createSymbolicLink(at: fixture.grokSummary, withDestinationURL: victim)
        #expect(!fixture.file.save(snapshot))
        #expect(SessionScanner.scan(root: fixture.grok, cache: [:]).sessions.isEmpty)
        var readRejected = false
        do { _ = try SessionScanner.ContentReader.disk.read(fixture.grokSummary) } catch { readRejected = true }
        #expect(readRejected)
        let movedSession = fixture.base.appendingPathComponent("moved-session")
        try FileManager.default.moveItem(at: fixture.grokDirectory, to: movedSession)
        try FileManager.default.createSymbolicLink(at: fixture.grokDirectory, withDestinationURL: movedSession)
        let alias = SessionScanner.scan(root: fixture.grok, cache: [:])
        #expect(alias.sessions.isEmpty && alias.loadError != nil)
        #expect(!fixture.file.save(snapshot))
    }

    @Test func olderQueuedWriteCannotReplaceANewerAppliedScan() async throws {
        let fixture = try HistoryIndexFixture()
        defer { fixture.cleanup() }
        let writer = SessionIndexWriter()
        let newer = fixture.snapshot(fixture.scan().cache)
        var older = newer
        older.entries = [:]
        await writer.save(newer, to: fixture.file, sequence: 2)
        await writer.save(older, to: fixture.file, sequence: 1)
        #expect(fixture.file.load(roots: fixture.roots)?.entries.count == 3)
    }
}

final class HistoryIndexMeter: Sendable {
    private let reads = OSAllocatedUnfairLock(initialState: 0)
    var count: Int { reads.withLock { $0 } }
    var grok: SessionScanner.ContentReader {
        .init { url in
            self.reads.withLock { $0 += 1 }
            return try SessionScanner.ContentReader.disk.read(url)
        }
    }
    var native: NativeSessionScanner.ContentReader {
        .init { file, offset, count in
            self.reads.withLock { $0 += 1 }
            return try NativeSessionScanner.ContentReader.disk.read(file, offset, count)
        }
    }
}

struct HistoryIndexFixture: Sendable {
    let base: URL
    let grok: URL
    let claude: URL
    let codex: URL
    let project: URL
    let id = "11111111-1111-4111-8111-111111111111"
    let grokID: String
    var nativeRoots: [(CLIProvider, URL)] { [(.claudeCode, claude), (.codex, codex)] }
    var roots: [SessionIndexFile.Root] { SessionIndexFile.roots(grok: grok, native: nativeRoots) }
    var file: SessionIndexFile { SessionIndexFile(url: base.appendingPathComponent("private/history-index.json")) }
    var grokDirectory: URL {
        grok.appendingPathComponent(GrokPaths.sessionFolderName(forCanonicalPath: project.path)).appendingPathComponent(
            grokID)
    }
    var grokSummary: URL { grokDirectory.appendingPathComponent("summary.json") }
    var claudeFile: URL { claude.appendingPathComponent("generated.jsonl") }
    var titleFile: URL { codex.deletingLastPathComponent().appendingPathComponent("session_index.jsonl") }

    init(temporaryRoot: URL? = nil, grokID: String? = nil) throws {
        self.grokID = grokID ?? id
        base = (temporaryRoot ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath())
            .appendingPathComponent("Sigil-SavedHistory-\(UUID().uuidString)")
        grok = base.appendingPathComponent("grok/sessions")
        claude = base.appendingPathComponent("claude/projects")
        codex = base.appendingPathComponent("codex/sessions")
        let projectPath = base.appendingPathComponent("generated-project")
        try FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
        project = URL(fileURLWithPath: GrokPaths.canonicalPath(projectPath.path))
        for folder in [project, grokDirectory, claude, codex] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try JSONSerialization.data(withJSONObject: [
            "info": ["id": self.grokID, "cwd": project.path],
            "session_summary": "Generated Grok title", "num_chat_messages": 1,
        ]).write(to: grokSummary)
        try Data(
            "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"\(project.path)\",\"version\":\"2.1.283\",\"message\":{\"content\":\"Generated Claude title\"}}\n"
                .utf8
        ).write(to: claudeFile)
        try Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(project.path)\",\"cli_version\":\"0.160.0\"}}\n{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Generated Codex title\"}}\n"
                .utf8
        ).write(to: codex.appendingPathComponent("generated.jsonl"))
        try Data("{\"id\":\"\(id)\",\"thread_name\":\"Generated index title\"}\n".utf8).write(to: titleFile)
    }

    func scan(
        cache: [String: SessionCacheEntry] = [:], titles: CodexTitleIndexCache = .init(),
        meter: HistoryIndexMeter = .init(), ignoringCache: Bool = false
    ) -> SessionScanner.Result {
        var result = SessionScanner.scan(
            root: grok, cache: cache.filter { $0.value.session.provider == .grokBuild },
            ignoringCache: ignoringCache, contentReader: meter.grok)
        for (provider, root) in nativeRoots {
            let native = NativeSessionScanner.scan(
                provider: provider, root: root, cache: cache, ignoringCache: ignoringCache,
                contentReader: meter.native, titleIndexCache: titles)
            result.sessions += native.sessions
            result.cache.merge(native.cache) { _, new in new }
            result.coverage.merge(native.coverage)
        }
        result.sessions.sort(by: SessionScanner.isNewer)
        return result
    }

    func snapshot(_ cache: [String: SessionCacheEntry], titles: CodexTitleIndexCache = .init())
        -> SessionIndexFile.Snapshot
    {
        .init(roots: roots, entries: cache, titleIndexes: titles.displaySnapshots())
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}
