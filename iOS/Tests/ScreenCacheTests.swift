import Foundation

/// The screen cache writer: work off the caller, in order, one write per burst,
/// and never a forgotten Mac's screen back.
@MainActor
enum ScreenCacheTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("cache: save returns before the write; a burst is one write", burstIsOneWrite),
        ("cache: the newest snapshot wins", newestSnapshotWins),
        ("cache: forgetting a Mac drops its waiting save", forgettingDropsAWaitingSave),
        ("cache: each Mac keeps its own file", eachMacKeepsItsOwnFile),
        ("cache: a corrupt or truncated file is ignored", corruptOrTruncatedFileIsIgnored),
        ("cache: restore lands only while current", restoreLandsOnlyWhileCurrent),
    ]

    /// Holds the writer's queue once everything queued before it has run.
    private final class Gate: @unchecked Sendable {
        private let reached = DispatchSemaphore(value: 0)
        private let open = DispatchSemaphore(value: 0)

        init(on queue: DispatchQueue) {
            queue.async {
                self.reached.signal()
                self.open.wait()
            }
        }

        func waitUntilHeld() { reached.wait() }
        func release() { open.signal() }
    }

    @MainActor
    private final class Screen {
        var current = true
        var released = false
        var checks: [Bool] = []
    }

    private static func makeWriter() throws -> (ScreenCacheWriter, URL) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (ScreenCacheWriter { folder }, folder)
    }

    private static func mac() -> PairingCredential {
        PairingCredential(
            origin: URL(string: "https://relay.example")!, room: String(repeating: "0", count: 32),
            deviceKey: RemoteCrypto.randomKey(), ticket: nil)
    }

    private static func snapshot(_ label: String, rows: Int = 40) -> CachedScreen {
        var model = ScreenModel()
        model.apply(
            RemoteScreen(
                tab: "t1", gen: 1, alt: nil, first: 0, end: rows,
                rows: (0..<rows).map { RemoteScreenRow(i: $0, t: "\(label) row \($0)", w: nil, s: nil) },
                palette: nil, fg: nil, bg: nil))
        return CachedScreen(
            tabs: [RemoteTab(id: "t1", title: label, status: .idle)], selectedTabID: "t1", mac: label,
            screens: ["t1": model], savedAt: Date(timeIntervalSince1970: 1_000))
    }

    private static func load(_ writer: ScreenCacheWriter, _ mac: PairingCredential) async -> CachedScreen? {
        await writer.restore(for: mac) { true }
    }

    static func burstIsOneWrite() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        let file = folder.appendingPathComponent(ScreenCache.fileName(for: mac))
        let gate = Gate(on: writer.queue)
        for i in 1...50 { writer.save(snapshot("v\(i)"), for: mac) }
        try Expect.true(!FileManager.default.fileExists(atPath: file.path), "save returns before anything is written")
        try Expect.equal(writer.writeCount, 0, "nothing written while the queue is held")
        gate.release()
        let cached = await load(writer, mac)
        try Expect.equal(cached, snapshot("v50"), "the last snapshot is on disk")
        try Expect.equal(writer.writeCount, 1, "fifty saves while one waited cost one write")
    }

    static func newestSnapshotWins() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        let file = folder.appendingPathComponent(ScreenCache.fileName(for: mac))

        // One write already done, then two saves while the queue is busy.
        let first = Gate(on: writer.queue)
        writer.save(snapshot("a"), for: mac)
        let second = Gate(on: writer.queue)
        first.release()
        second.waitUntilHeld()
        try Expect.equal(ScreenCache.read(file), snapshot("a"), "the first save is written")
        writer.save(snapshot("b"), for: mac)
        writer.save(snapshot("c"), for: mac)
        try Expect.equal(ScreenCache.read(file), snapshot("a"), "later saves wait their turn")
        second.release()
        let cached = await load(writer, mac)
        try Expect.equal(cached, snapshot("c"), "the newest snapshot replaces the older one")
        try Expect.equal(writer.writeCount, 2, "b was replaced before it was written")

        // Saves racing the queue: some wait, some are taken mid-burst. The last one always ends on disk.
        for i in 1...200 {
            writer.save(snapshot("r\(i)", rows: 4), for: mac)
            if i % 7 == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        let raced = await load(writer, mac)
        try Expect.equal(raced, snapshot("r200", rows: 4), "the newest of a racing burst is on disk")
        try Expect.true(writer.writeCount <= 202, "never more writes than saves")
    }

    static func forgettingDropsAWaitingSave() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        let file = folder.appendingPathComponent(ScreenCache.fileName(for: mac))

        let gate = Gate(on: writer.queue)
        writer.save(snapshot("a"), for: mac)
        writer.delete(for: mac)
        gate.release()
        let dropped = await load(writer, mac)
        try Expect.equal(dropped, nil, "a save waiting when the Mac was forgotten never lands")
        try Expect.equal(writer.writeCount, 0, "the dropped save cost no write")
        try Expect.true(!FileManager.default.fileExists(atPath: file.path), "no file left")

        // A save already written, then forget: the delete runs after it.
        writer.save(snapshot("b"), for: mac)
        let held = Gate(on: writer.queue)
        held.waitUntilHeld()
        try Expect.true(FileManager.default.fileExists(atPath: file.path), "the save was written")
        writer.delete(for: mac)
        held.release()
        let deleted = await load(writer, mac)
        try Expect.equal(deleted, nil, "the delete comes after the write it followed")
        try Expect.true(!FileManager.default.fileExists(atPath: file.path), "no file left after the write")
    }

    static func eachMacKeepsItsOwnFile() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let studio = mac()
        let laptop = mac()
        try Expect.true(ScreenCache.fileName(for: studio) != ScreenCache.fileName(for: laptop), "one file per pairing")
        let gate = Gate(on: writer.queue)
        writer.save(snapshot("studio"), for: studio)
        writer.save(snapshot("laptop"), for: laptop)
        writer.delete(for: studio)
        gate.release()
        let forgotten = await load(writer, studio)
        let kept = await load(writer, laptop)
        try Expect.equal(forgotten, nil, "the forgotten Mac has no cache")
        try Expect.equal(kept, snapshot("laptop"), "the other Mac keeps its cache")
    }

    static func corruptOrTruncatedFileIsIgnored() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        let file = folder.appendingPathComponent(ScreenCache.fileName(for: mac))
        writer.save(snapshot("good"), for: mac)
        let good = await load(writer, mac)
        try Expect.equal(good, snapshot("good"), "a saved cache loads")

        // A save that cannot be written leaves the last good file in place.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        writer.save(snapshot("unwritable"), for: mac)
        let kept = await load(writer, mac)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try Expect.equal(kept, snapshot("good"), "a failed write keeps the last good cache")

        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count / 2).write(to: file)
        let truncated = await load(writer, mac)
        try Expect.equal(truncated, nil, "a truncated cache is ignored")
        try Data("not json".utf8).write(to: file)
        let corrupt = await load(writer, mac)
        try Expect.equal(corrupt, nil, "a corrupt cache is ignored")

        writer.save(snapshot("fresh"), for: mac)
        let fresh = await load(writer, mac)
        try Expect.equal(fresh, snapshot("fresh"), "the next save replaces the bad file")
    }

    static func restoreLandsOnlyWhileCurrent() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()

        // A restore asked for while a save still waits reads that save.
        let gate = Gate(on: writer.queue)
        writer.save(snapshot("a"), for: mac)
        let waiting = Task { @MainActor in await writer.restore(for: mac) { true } }
        await Task.yield()
        gate.release()
        let restored = await waiting.value
        try Expect.equal(restored, snapshot("a"), "restore reads behind the queued save")

        // The screen moves on while the read waits: the cache is dropped, checked after the read.
        let screen = Screen()
        let held = Gate(on: writer.queue)
        let stale = Task { @MainActor in
            await writer.restore(for: mac) {
                screen.checks.append(screen.released)
                return screen.current
            }
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))
        try Expect.equal(screen.checks, [], "nothing is checked before the read")
        screen.current = false
        screen.released = true
        held.release()
        let dropped = await stale.value
        try Expect.equal(dropped, nil, "a cache for a screen that moved on is dropped")
        try Expect.equal(screen.checks, [true], "checked once, after the read")
    }
}
