#if canImport(Sigil)
@testable import Sigil
#endif
import Foundation

/// IOS-1: the output is formatted and styled on one ordered worker that owns its formatter.
enum IOSOutputWorkerTests {
    /// The worker's answers, which arrive on its queue.
    private final class Answers: @unchecked Sendable {
        typealias Answer = (generation: Int, styled: StyledText?, onMain: Bool)
        private let lock = NSLock()
        private var items: [Answer] = []
        private let arrived = DispatchSemaphore(value: 0)
        private(set) var formatters = 0
        private(set) var formatterOnMain = false

        func add(_ generation: Int, _ styled: StyledText?) {
            lock.withLock { items.append((generation, styled, Thread.isMainThread)) }
            arrived.signal()
        }

        func madeFormatter() {
            lock.withLock {
                formatters += 1
                formatterOnMain = formatterOnMain || Thread.isMainThread
            }
        }

        func wait(for count: Int) throws -> [Answer] {
            for _ in 0..<count {
                if arrived.wait(timeout: .now() + 20) == .timedOut { throw TestFailure("the worker did not answer") }
            }
            return lock.withLock { items }
        }
    }

    private static func snapshots(_ rng: inout IOSOutputFixtures.Seeded) -> [OutputSnapshot] {
        var result: [OutputSnapshot] = []
        for index in 0..<8 {
            let model = IOSOutputFixtures.model(
                count: 60 + index * 20, grounded: index % 2 == 0, footer: index % 3 == 0, using: &rng)
            result.append(OutputSnapshot(screen: model, history: nil, raw: index % 4 == 1))
        }
        var history = TerminalHistory()
        history.apply((0..<50).map { _ in IOSOutputFixtures.text(using: &rng) }.joined(separator: "\n")
            + IOSOutputFixtures.footer.joined(separator: "\n"))
        result.append(OutputSnapshot(screen: nil, history: history, raw: false))
        result.append(OutputSnapshot(screen: nil, history: history, raw: true))
        result.append(OutputSnapshot(screen: nil, history: nil, raw: false))
        return result
    }

    /// Off the main thread, the worker builds exactly what the main thread would,
    /// with one formatter of its own that it makes on its queue.
    static func workerMatchesTheMainThread() throws {
        let script = try String(contentsOfFile: "Sigil/Resources/readable-output.js", encoding: .utf8)
        let reference = ReadableOutput(script: script)
        let answers = Answers()
        let worker = OutputWorker {
            answers.madeFormatter()
            return ReadableOutput(script: script)
        }
        var rng = IOSOutputFixtures.Seeded(state: 11)
        let all = snapshots(&rng)
        for (index, snapshot) in all.enumerated() {
            worker.submit(snapshot, generation: index + 1) { answers.add(index + 1, $0) }
            _ = try answers.wait(for: 1)
        }
        let results = try answers.wait(for: 0)
        try Expect.equal(results.count, all.count, "one answer each")
        for (index, snapshot) in all.enumerated() {
            let expected = snapshot.render(with: reference)
            try Expect.equal(results[index].styled, expected, "snapshot \(index) matches the main thread")
            try Expect.true(!results[index].onMain, "built off the main thread")
        }
        try Expect.true(results.contains { ($0.styled?.spans.count ?? 0) > 0 }, "styled output was built")
        try Expect.true(results.contains { ($0.styled?.panels.count ?? 0) > 0 }, "panels were built")
        try Expect.equal(answers.formatters, 1, "one formatter for the worker's life")
        try Expect.true(!answers.formatterOnMain, "the formatter was made on the worker's queue")
    }

    /// Snapshots that a newer one replaced while the worker was busy are skipped;
    /// every answer still comes back, in order, and the newest is built in full.
    static func workerSkipsReplacedSnapshotsInOrder() throws {
        let script = try String(contentsOfFile: "Sigil/Resources/readable-output.js", encoding: .utf8)
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let worker = OutputWorker {
            entered.signal()
            gate.wait()
            return ReadableOutput(script: script)
        }
        let answers = Answers()
        var rng = IOSOutputFixtures.Seeded(state: 23)
        let all = Array(snapshots(&rng).prefix(4))
        worker.submit(all[0], generation: 1) { answers.add(1, $0) }
        guard entered.wait(timeout: .now() + 20) == .success else { throw TestFailure("the worker did not start") }
        for generation in 2...4 {
            worker.submit(all[generation - 1], generation: generation) { answers.add(generation, $0) }
        }
        gate.signal()
        let results = try answers.wait(for: 4)
        try Expect.equal(results.map(\.generation), [1, 2, 3, 4], "answers come back in order")
        try Expect.equal(results.map { $0.styled != nil }, [true, false, false, true], "replaced snapshots are skipped")
        let reference = ReadableOutput(script: script)
        try Expect.equal(results[0].styled, all[0].render(with: reference), "the one already started finishes")
        try Expect.equal(results[3].styled, all[3].render(with: reference), "the newest is built")
    }
}
