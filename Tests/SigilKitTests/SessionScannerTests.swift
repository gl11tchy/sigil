import Foundation
import Testing

@testable import SigilKit

@Suite
struct SessionScannerTests {

    @Test func anOverlappingScanRemembersRootAvailabilityBeforeTheEarlierScanFinishes() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        let file = try fixture.write(summary: "Generated", cwd: "/tmp/generated-project", id: "generated")
        let data = try Data(contentsOf: file)
        let root = fixture.root
        let availability = SessionScanner.RootAvailability()
        let earlier = SessionScanner.scan(
            root: root, cache: [:],
            contentReader: .init { _ in
                // The first scan already inspected the root but has not returned its result.
                try FileManager.default.removeItem(at: root)
                let overlapping = SessionScanner.scan(root: root, cache: [:], rootAvailability: availability)
                #expect(overlapping.loadError != nil)
                #expect(overlapping.coverage.uncertainRoots.contains(root.standardizedFileURL.path))
                return data
            }, rootAvailability: availability)
        #expect(earlier.sessions.count == 1)
    }

    @Test func unchangedFileSkipsContentReadOnSecondScan() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        try fixture.write(summary: "Hello", cwd: "/proj", id: "s1")
        let counter = ContentReadCounter()

        let first = SessionScanner.scan(
            root: fixture.root,
            cache: [:],
            contentReader: counter.reader
        )
        #expect(first.loadError == nil)
        #expect(first.sessions.map(\.id) == ["s1"])
        #expect(counter.count == 1)

        let second = SessionScanner.scan(
            root: fixture.root,
            cache: first.cache,
            contentReader: counter.reader
        )
        #expect(second.loadError == nil)
        #expect(second.sessions.map(\.id) == ["s1"])
        #expect(second.sessions == first.sessions)
        #expect(counter.count == 1)
    }

    @Test func sameSizeContentChangeWithNewMtimeReloads() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        let url = try fixture.write(summary: "AAAA", cwd: "/proj", id: "s1")
        let counter = ContentReadCounter()

        let first = SessionScanner.scan(
            root: fixture.root,
            cache: [:],
            contentReader: counter.reader
        )
        #expect(first.sessions.first?.title == "AAAA")
        #expect(counter.count == 1)

        try fixture.replace(at: url, summary: "BBBB", atomic: false)
        let later = Date(timeIntervalSinceNow: 30)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
        let newMtime = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        #expect(newMtime.fileSize == first.cache.values.first?.size)
        #expect(newMtime.contentModificationDate != first.cache.values.first?.modificationDate)

        let second = SessionScanner.scan(
            root: fixture.root,
            cache: first.cache,
            contentReader: counter.reader
        )
        #expect(second.loadError == nil)
        #expect(second.sessions.first?.title == "BBBB")
        #expect(counter.count == 2)
    }

    @Test func matchesDisplayedTitleWithoutRequiringCLISummary() {
        let session = GrokSession(
            id: "s1",
            cwd: "/tmp/project",
            summary: "CLI summary",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            messageCount: 4,
            modelID: nil,
            agentName: nil,
            reasoningEffort: nil,
            directory: URL(fileURLWithPath: "/tmp/project/s1")
        )
        #expect(SessionScanner.matches(session, query: "Auth", displayedTitle: "Auth rewrite"))
        #expect(!SessionScanner.matches(session, query: "Auth"))
        #expect(SessionScanner.matches(session, query: "project"))
        #expect(SessionScanner.matches(session, query: "project Auth", displayedTitle: "Auth rewrite"))
        #expect(SessionScanner.matches(session, query: "rewrite auth", displayedTitle: "Auth rewrite"))
        #expect(!SessionScanner.matches(session, query: "project missing", displayedTitle: "Auth rewrite"))

    }

    @Test func matchesTildeDisplayPathWithoutRequiringRawCwd() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let session = GrokSession(
            id: "s1",
            cwd: home + "/repos/sigil",
            summary: "CLI summary",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            messageCount: 4,
            modelID: nil,
            agentName: nil,
            reasoningEffort: nil,
            directory: URL(fileURLWithPath: home + "/repos/sigil/s1")
        )
        #expect(session.displayPath == "~/repos/sigil")
        #expect(SessionScanner.matches(session, query: "~"))
        #expect(SessionScanner.matches(session, query: "~/repos"))
        #expect(!SessionScanner.matches(session, query: "~/nope"))
    }

    @Test func sessionKindIsReadFromSummary() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        try fixture.write(
            data: try ScannerFixture.summaryData(
                id: "child", cwd: "/proj", text: "Verify nav", kind: "subagent"),
            cwd: "/proj",
            id: "child"
        )
        try fixture.write(summary: "Parent chat", cwd: "/proj", id: "parent")

        let result = SessionScanner.scan(root: fixture.root, cache: [:])
        let child = try #require(result.sessions.first { $0.id == "child" })
        let parent = try #require(result.sessions.first { $0.id == "parent" })
        #expect(child.isSubagent)
        #expect(child.kind == "subagent")
        #expect(!parent.isSubagent)
        #expect(parent.kind == nil)
    }

    @Test func invalidSummaryIsReportedWithoutSession() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        try fixture.write(data: Data("this is not json {".utf8), cwd: "/tmp/bad", id: "bad")

        let result = SessionScanner.scan(root: fixture.root, cache: [:])
        #expect(result.sessions.isEmpty)
        #expect(result.loadError == nil)
        #expect(result.notice?.contains("incomplete or unsupported") == true)
    }

    @Test func unreadableSummaryIsReportedWithoutSession() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        let url = try fixture.write(summary: "Hello", cwd: "/proj", id: "s1")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }

        let result = SessionScanner.scan(root: fixture.root, cache: [:])
        #expect(result.sessions.isEmpty)
        #expect(result.loadError?.contains("summary.json could not be read") == true)
    }

    @Test(arguments: ["partial", "missing", "directory"])
    func invalidUpdatePreservesOnlyItsOwnCachedSession(kind: String) throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        let url = try fixture.write(summary: "Hello", cwd: "/proj", id: "s1")
        let deleted = try fixture.write(summary: "Deleted", cwd: "/proj", id: "s2")
        let first = SessionScanner.scan(root: fixture.root, cache: [:])
        #expect(first.sessions.count == 2)

        try FileManager.default.removeItem(at: deleted.deletingLastPathComponent())
        if kind == "partial" {
            try Data("not valid json".utf8).write(to: url, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: url)
            if kind == "directory" {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        let second = SessionScanner.scan(root: fixture.root, cache: first.cache)
        #expect(second.sessions.map(\.id) == ["s1"])
        #expect(second.sessions.first?.title == "Hello")
        #expect(second.loadError == nil)
        #expect(second.notice?.contains("incomplete or unsupported") == true)
        #expect(
            second.coverage.unrecognizedGrokDirectories == [url.deletingLastPathComponent().standardizedFileURL.path])
    }

    @Test func sameSizeSameMtimeAtomicReplaceStillReloads() throws {
        let fixture = try ScannerFixture()
        defer { fixture.tearDown() }
        let url = try fixture.write(summary: "Initial", cwd: "/proj", id: "s1")
        let counter = ContentReadCounter()
        let first = SessionScanner.scan(
            root: fixture.root,
            cache: [:],
            contentReader: counter.reader
        )
        let initialValues = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let initialDate = try #require(initialValues.contentModificationDate)
        let initialSize = try #require(initialValues.fileSize)

        try fixture.replace(at: url, summary: "Changed", atomic: true)
        try FileManager.default.setAttributes(
            [.modificationDate: initialDate],
            ofItemAtPath: url.path
        )
        let changedValues = try url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        #expect(changedValues.fileSize == initialSize)
        #expect(changedValues.contentModificationDate == initialDate)

        let second = SessionScanner.scan(
            root: fixture.root,
            cache: first.cache,
            contentReader: counter.reader
        )
        #expect(second.sessions.first?.title == "Changed")
        #expect(counter.count == 2)
    }
}

private final class ContentReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var reader: SessionScanner.ContentReader {
        SessionScanner.ContentReader { url in
            try self.read(url)
        }
    }

    func read(_ url: URL) throws -> Data {
        lock.lock()
        reads += 1
        lock.unlock()
        return try Data(contentsOf: url)
    }
}

private struct ScannerFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sigil-SessionScanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func write(summary: String, cwd: String, id: String) throws -> URL {
        try write(data: try Self.summaryData(id: id, cwd: cwd, text: summary), cwd: cwd, id: id)
    }

    @discardableResult
    func write(data: Data, cwd: String, id: String) throws -> URL {
        let dir =
            root
            .appendingPathComponent(GrokPaths.encode(path: cwd), isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("summary.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func replace(at url: URL, summary: String, atomic: Bool) throws {
        let id = url.deletingLastPathComponent().lastPathComponent
        let cwd = try #require(Self.cwd(from: url))
        let data = try Self.summaryData(id: id, cwd: cwd, text: summary)
        if atomic {
            try data.write(to: url, options: .atomic)
        } else {
            try data.write(to: url, options: [])
        }
    }

    private static func cwd(from summaryURL: URL) -> String? {
        let encoded = summaryURL.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent
        return GrokPaths.decode(directoryName: encoded)
    }

    static func summaryData(
        id: String, cwd: String, text: String, kind: String? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "info": ["id": id, "cwd": cwd],
            "session_summary": text,
            "created_at": "2026-08-01T00:00:00Z",
            "updated_at": "2026-08-01T00:00:01Z",
            "num_messages": 1,
            "num_chat_messages": 1,
        ]
        if let kind {
            object["session_kind"] = kind
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }
}
