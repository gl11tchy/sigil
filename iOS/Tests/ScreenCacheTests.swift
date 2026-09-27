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
        ("cache: a Mac's ground is there at once and goes with its cache", groundIsThereAtOnce),
        ("cache: a corrupt or truncated file is ignored", corruptOrTruncatedFileIsIgnored),
        ("cache: restore lands only while current", restoreLandsOnlyWhileCurrent),
        ("cache: only the newest restore of the Mac on screen is current", onlyTheNewestRestoreIsCurrent),
        ("cache: live state with no tabs keeps a late restore off screen", liveEmptyStateBeatsALateRestore),
        ("cache: queued work holds the app until the last change is written", queuedWorkHoldsTheApp),
        ("cache: launch waits only for a cache on disk", launchWaitsOnlyForACacheOnDisk),
        ("cache: the read starts at once, off the main actor", readStartsAtOnce),
        ("cache: the wait ends when the restore lands, finds nothing or goes stale", waitEnds),
        ("cache: the wait is bounded while the read is held", waitIsBounded),
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

    private static func snapshot(_ label: String, rows: Int = 40, ground: String? = nil) -> CachedScreen {
        var model = ScreenModel()
        model.apply(
            RemoteScreen(
                tab: "t1", gen: 1, alt: nil, first: 0, end: rows,
                rows: (0..<rows).map { RemoteScreenRow(i: $0, t: "\(label) row \($0)", w: nil, s: nil) },
                palette: nil, fg: nil, bg: ground))
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

    /// Launch colours its wait from this before the file is read, so it must not wait on the queue.
    static func groundIsThereAtOnce() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.lastPathComponent
        let grounds = try Expect.notNil(UserDefaults(suiteName: suite), "a throwaway defaults suite")
        defer {
            try? FileManager.default.removeItem(at: folder)
            grounds.removePersistentDomain(forName: suite)
        }
        let writer = ScreenCacheWriter(directory: { folder }, grounds: grounds)
        let studio = mac()
        let laptop = mac()
        try Expect.equal(writer.ground(for: studio), "", "no ground before a save")

        let gate = Gate(on: writer.queue)
        gate.waitUntilHeld()
        writer.save(snapshot("studio", ground: "1E1E1E"), for: studio)
        writer.save(snapshot("laptop", ground: "FAFAFA"), for: laptop)
        try Expect.equal(writer.ground(for: studio), "1E1E1E", "the ground is there while the write waits")
        try Expect.equal(writer.ground(for: laptop), "FAFAFA", "each Mac keeps its own ground")
        try Expect.true(
            !grounds.dictionaryRepresentation().keys.contains { $0.contains(studio.deviceKey) },
            "the key never carries the device key")

        writer.save(snapshot("studio"), for: studio)
        try Expect.equal(writer.ground(for: studio), "", "a screen with no ground leaves none")
        writer.save(snapshot("studio", ground: "1E1E1E"), for: studio)
        writer.delete(for: studio)
        try Expect.equal(writer.ground(for: studio), "", "forgetting the Mac drops its ground")
        try Expect.equal(writer.ground(for: laptop), "FAFAFA", "the other Mac keeps its ground")
        gate.release()
        let forgotten = await load(writer, studio)
        try Expect.equal(forgotten, nil, "and its cache")
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

    /// The store's steps, in its order: `activate` begins a restore, `clearMacState`
    /// invalidates, every live state supersedes, and the check names the Mac on screen.
    static func onlyTheNewestRestoreIsCurrent() throws {
        var gate = RestoreGate()

        // Launch on Mac A.
        let launch = gate.begin(macID: "A")
        try Expect.true(gate.isCurrent(launch, activeMacID: "A"), "a restore for the Mac on screen is current")
        try Expect.true(!gate.isCurrent(launch, activeMacID: "B"), "never current while another Mac is on screen")
        try Expect.true(!gate.isCurrent(launch, activeMacID: nil), "never current with no Mac on screen")
        // A's first live state, whatever its tabs.
        gate.supersede()
        try Expect.true(!gate.isCurrent(launch, activeMacID: "A"), "live state makes the restore stale")

        // Switch A to B and back to A before either read finishes.
        let firstA = gate.begin(macID: "A")
        gate.invalidate()
        let b = gate.begin(macID: "B")
        try Expect.true(!gate.isCurrent(firstA, activeMacID: "B"), "switching away drops A's restore")
        try Expect.true(gate.isCurrent(b, activeMacID: "B"), "B's restore is current")
        gate.invalidate()
        let secondA = gate.begin(macID: "A")
        try Expect.true(!gate.isCurrent(firstA, activeMacID: "A"), "A's first restore stays stale once A is back")
        try Expect.true(!gate.isCurrent(b, activeMacID: "A"), "B's restore is stale")
        try Expect.true(gate.isCurrent(secondA, activeMacID: "A"), "only A's newest restore is current")

        // Forget A: its state is cleared, then B or nothing comes on screen.
        gate.invalidate()
        try Expect.true(!gate.isCurrent(secondA, activeMacID: nil), "a forgotten Mac's restore is dropped")
        let next = gate.begin(macID: "B")
        try Expect.true(!gate.isCurrent(secondA, activeMacID: "B"), "a forgotten Mac's restore never reaches the next Mac")
        try Expect.true(gate.isCurrent(next, activeMacID: "B"), "the next Mac's restore is current")

        // Pair another Mac while B's read is in flight: B is cleared, then C is saved with no restore.
        gate.invalidate()
        try Expect.true(!gate.isCurrent(next, activeMacID: nil), "pairing another Mac drops the restore")
        try Expect.true(!gate.isCurrent(next, activeMacID: "C"), "the new Mac never shows B's cache")
        // Or the pairing is cancelled: B comes back with a restore of its own.
        let back = gate.begin(macID: "B")
        try Expect.true(!gate.isCurrent(next, activeMacID: "B"), "the restore from before pairing stays stale")
        try Expect.true(gate.isCurrent(back, activeMacID: "B"), "the restore after cancelling is current")
    }

    @MainActor
    private final class Shown {
        var gate = RestoreGate()
        var activeMacID: String?
    }

    /// A Mac whose sessions all closed sends an empty tab list. A cache read that
    /// finishes after it must not bring yesterday's sessions back.
    static func liveEmptyStateBeatsALateRestore() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = mac()
        let a = mac()
        writer.save(snapshot("yesterday"), for: a)

        // Switching from the previous Mac queues its last save; A's read waits behind it.
        let shown = Shown()
        let held = Gate(on: writer.queue)
        writer.save(snapshot("previous"), for: previous)
        shown.gate.invalidate()
        shown.activeMacID = a.id
        let ticket = shown.gate.begin(macID: a.id, awaited: true)
        let late = Task { @MainActor in
            await writer.restore(for: a) { shown.gate.isCurrent(ticket, activeMacID: shown.activeMacID) }
        }
        await Task.yield()
        // A's watch reply lands first, with no tabs and nothing selected.
        shown.gate.supersede()
        try Expect.true(shown.gate.isAwaiting, "live state keeps the wait until its output is drawn")
        shown.gate.endWait()
        try Expect.true(!shown.gate.isAwaiting, "drawing the live output ends the wait")
        held.release()
        let dropped = await late.value
        try Expect.equal(dropped, nil, "a late restore never replaces live state, even an empty one")

        // With nothing live meanwhile, the same cache lands.
        let fresh = shown.gate.begin(macID: a.id)
        let restored = await writer.restore(for: a) { shown.gate.isCurrent(fresh, activeMacID: shown.activeMacID) }
        try Expect.equal(restored, snapshot("yesterday"), "a restore with nothing live lands")
    }

    /// The hold is let go from a main-actor task once the queue is idle.
    private static func waitForRelease(_ writer: ScreenCacheWriter) async throws {
        for _ in 0..<200 where writer.holdingApp {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The save made on the way to the background must reach the disk before iOS
    /// may suspend the app.
    static func queuedWorkHoldsTheApp() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        let file = folder.appendingPathComponent(ScreenCache.fileName(for: mac))
        try Expect.true(!writer.holdingApp, "no hold with nothing queued")

        let first = Gate(on: writer.queue)
        writer.save(snapshot("a"), for: mac)
        try Expect.true(writer.holdingApp, "a queued save holds the app")
        try await Task.sleep(for: .milliseconds(20))
        try Expect.true(writer.holdingApp, "still held while the save waits")
        first.release()
        _ = await load(writer, mac)
        try await waitForRelease(writer)
        try Expect.true(!writer.holdingApp, "let go once the save is written")
        try Expect.equal(ScreenCache.read(file), snapshot("a"), "the save is on disk")

        // The queue goes idle and asks to let go; a save made before that request runs keeps the hold.
        writer.save(snapshot("b"), for: mac)
        writer.queue.sync {}
        let second = Gate(on: writer.queue)
        writer.save(snapshot("c"), for: mac)
        try await Task.sleep(for: .milliseconds(20))
        try Expect.true(writer.holdingApp, "a save queued as the queue went idle keeps the hold")
        second.release()
        _ = await load(writer, mac)
        try await waitForRelease(writer)
        try Expect.true(!writer.holdingApp, "let go once the last save is written")
        try Expect.equal(ScreenCache.read(file), snapshot("c"), "the last save is on disk")
    }

    /// A cache on disk or waiting to be written makes the launch wait; with none, the
    /// screen shows the empty Mac at once, as before.
    static func launchWaitsOnlyForACacheOnDisk() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        let file = folder.appendingPathComponent(ScreenCache.fileName(for: mac))
        try Expect.true(!writer.hasCache(for: mac), "no cache on a first run")
        var gate = RestoreGate()
        _ = gate.begin(macID: mac.id, awaited: writer.hasCache(for: mac))
        try Expect.true(!gate.isAwaiting, "with no cache the screen does not wait")

        let held = Gate(on: writer.queue)
        writer.save(snapshot("a"), for: mac)
        try Expect.true(writer.hasCache(for: mac), "a waiting save counts")
        writer.delete(for: mac)
        try Expect.true(!writer.hasCache(for: mac), "a waiting delete does not")
        writer.save(snapshot("b"), for: mac)
        held.release()
        _ = await load(writer, mac)
        try Expect.true(writer.hasCache(for: mac), "a written cache counts")

        // A corrupt file still makes the launch wait; its read finds nothing and ends it.
        try Data("not json".utf8).write(to: file)
        try Expect.true(writer.hasCache(for: mac), "a file on disk counts, whatever is in it")
        let ticket = gate.begin(macID: mac.id, awaited: writer.hasCache(for: mac))
        try Expect.true(gate.isAwaiting, "the launch waits for it")
        let found = await load(writer, mac)
        try Expect.equal(found, nil, "the corrupt cache is ignored")
        gate.finish(ticket)
        try Expect.true(!gate.isAwaiting, "a read that finds nothing ends the wait")
    }

    /// The launch read must not wait for a main-actor turn: those come late while the
    /// first screen is built.
    static func readStartsAtOnce() throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        writer.save(snapshot("a"), for: mac)
        let done = DispatchSemaphore(value: 0)
        final class Result: @unchecked Sendable { var cached: CachedScreen?; var onMain = true }
        let result = Result()
        writer.read(for: mac) { cached in
            result.cached = cached
            result.onMain = Thread.isMainThread
            done.signal()
        }
        // The main actor stays blocked here; the read finishes all the same.
        try Expect.true(done.wait(timeout: .now() + 2) == .success, "the read finishes with the main actor busy")
        try Expect.equal(result.cached, snapshot("a"), "the read sees the queued save")
        try Expect.true(!result.onMain, "the result comes back off the main thread")
    }

    /// The store's steps: a launch that waits, then what ends the wait.
    static func waitEnds() throws {
        var gate = RestoreGate()
        let launch = gate.begin(macID: "A", awaited: true)
        try Expect.true(gate.isAwaiting, "a launch with a cache on disk waits")
        gate.finish(launch)
        try Expect.true(!gate.isAwaiting, "the restore landing ends the wait")
        try Expect.true(gate.isCurrent(launch, activeMacID: "A"), "ending the wait does not make the restore stale")

        // Live state comes first: the restore is stale, and the wait ends once the live output is drawn.
        let second = gate.begin(macID: "A", awaited: true)
        gate.supersede()
        try Expect.true(!gate.isCurrent(second, activeMacID: "A"), "the late restore stays off screen")
        try Expect.true(gate.isAwaiting, "live state keeps the wait until its output is drawn")
        gate.endWait()
        try Expect.true(!gate.isAwaiting, "drawing the live output ends the wait")

        // A switch to another Mac during the launch wait, as a notification opens it:
        // the store keeps waiting, for the new Mac's cache only.
        let bHasCache = true, bHasNone = false
        _ = gate.begin(macID: "A", awaited: true)
        var waiting = gate.isAwaiting
        gate.invalidate()
        let other = gate.begin(macID: "B", awaited: waiting && bHasCache)
        try Expect.true(gate.isAwaiting, "a switch during the launch wait keeps waiting for B's cache")
        gate.finish(other)
        try Expect.true(!gate.isAwaiting, "B's restore ends it")
        _ = gate.begin(macID: "A", awaited: true)
        waiting = gate.isAwaiting
        gate.invalidate()
        _ = gate.begin(macID: "B", awaited: waiting && bHasNone)
        try Expect.true(!gate.isAwaiting, "with no cache for B the switch does not wait")

        // A switch after the wait ended never waits, and an old restore cannot end a newer wait.
        let third = gate.begin(macID: "A", awaited: true)
        gate.finish(third)
        waiting = gate.isAwaiting
        gate.invalidate()
        _ = gate.begin(macID: "B", awaited: waiting && bHasCache)
        try Expect.true(!gate.isAwaiting, "a later switch does not start a wait")
        let fourth = gate.begin(macID: "A", awaited: true)
        gate.finish(third)
        try Expect.true(gate.isAwaiting, "a stale restore does not end the newer wait")
        gate.finish(fourth)
        try Expect.true(!gate.isAwaiting, "the newer restore does")
    }

    /// A read stuck behind a slow disk ends the wait after `RestoreGate.patience`, as
    /// the store does; the cache still lands when it comes, if nothing live came first.
    static func waitIsBounded() async throws {
        let (writer, folder) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mac = mac()
        writer.save(snapshot("a"), for: mac)
        _ = await load(writer, mac)
        try Expect.true(RestoreGate.patience <= .seconds(1), "the wait is short")

        let shown = Shown()
        shown.activeMacID = mac.id
        let held = Gate(on: writer.queue)
        let ticket = shown.gate.begin(macID: mac.id, awaited: writer.hasCache(for: mac))
        let late = Task { @MainActor in
            await writer.restore(for: mac) { shown.gate.isCurrent(ticket, activeMacID: shown.activeMacID) }
        }
        let started = ContinuousClock.now
        try await Task.sleep(for: RestoreGate.patience)
        shown.gate.finish(ticket)
        try Expect.true(!shown.gate.isAwaiting, "the wait ends with the read still held")
        try Expect.true(ContinuousClock.now - started < RestoreGate.patience + .milliseconds(500), "on time")
        held.release()
        let landed = await late.value
        try Expect.equal(landed, snapshot("a"), "the cache lands when the read finishes")
    }
}
