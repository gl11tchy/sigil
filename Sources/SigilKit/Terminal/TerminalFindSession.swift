import Foundation
import SwiftTerm

/// Only immutable values cross from the main-actor snapshot into this operation.
enum TerminalFindScan {
    struct Output: Sendable {
        let matches: [ScrollbackSearch.Match]
        let milliseconds: Double
        let ranOnMainThread: Bool
    }

    typealias Operation = @Sendable ([[ScrollbackSearch.Row]], String, Int) async -> Output

    static let run: Operation = { chunks, query, origin in
        await Task.detached(priority: .userInitiated) {
            let start = ContinuousClock.now
            var search = ScrollbackSearch()
            search.setQuery(query, in: chunks.flatMap { $0 })
            let matches = search.matches.map {
                ScrollbackSearch.Match(
                    line: $0.line + origin, columns: $0.columns,
                    endLine: $0.endLine + origin, endColumn: $0.endColumn)
            }
            return Output(
                matches: matches, milliseconds: milliseconds(start.duration(to: .now)),
                ranOnMainThread: Thread.isMainThread)
        }.value
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

struct TerminalFindBufferState {
    let buffer: ObjectIdentifier
    let columns: Int
    let rows: Int
    let count: Int
    let trimmed: Int
    let generation: Int
    let resizeGeneration: Int
    let firstLine: ObjectIdentifier?
    let firstLineGeneration: UInt64?
    let viewportBottom: Int

    var end: Int { trimmed + count }
    // Also exclude the boundary whose cell conversion can depend on the next row.
    var historyEnd: Int { trimmed + max(0, count - rows - 1) }
}

/// A query owns one bounded snapshot/scan pipeline. Output requests another pass
/// rather than repeatedly canceling a scan of otherwise unchanged scrollback.
@MainActor
final class TerminalFindSession {
    nonisolated static let rowsPerPass = 64
    nonisolated static let snapshotBudget: Duration = .milliseconds(2)
    nonisolated static let debounce: Duration = .milliseconds(80)

    struct Diagnostics {
        var rowCopies = 0
        var rowCacheHits = 0
        var snapshotPasses = 0
        var snapshotsCompleted = 0
        var largestSnapshotRows = 0
        var largestSnapshotMilliseconds = 0.0
        var snapshotsRanOnMainThread = true
        var scansStarted = 0
        var acceptedResults = 0
        var rejectedResults = 0
        var lastScanMilliseconds = 0.0
        var lastScanRanOnMainThread = false
        var lastQueryDelayMilliseconds = 0.0
    }

    private struct CapturedRow {
        let epoch: UInt64
        let absolute: Int
        let line: BufferLine
        let generation: UInt64
        let nextLine: BufferLine?
        let nextGeneration: UInt64?
        let row: ScrollbackSearch.Row
    }

    private struct Snapshot {
        let request: UInt64
        let epoch: UInt64
        let query: String
        let origin: Int
        let count: Int
        let historyEnd: Int
        let startGeneration: Int
        let endGeneration: Int
        let rows: [[ScrollbackSearch.Row]]
        let stamps: [[CapturedRow?]]

        var end: Int { origin + count }

        func stamp(at absolute: Int) -> CapturedRow? {
            let index = absolute - origin
            guard index >= 0, index < count else { return nil }
            return stamps[index / TerminalFindSession.rowsPerPass][index % TerminalFindSession.rowsPerPass]
        }
    }

    private struct Result {
        let snapshot: Snapshot
        let matches: [ScrollbackSearch.Match]
    }

    private let state: @MainActor () -> TerminalFindBufferState?
    private let line: @MainActor (Int) -> BufferLine?
    private let readRow: @MainActor (Int) -> ScrollbackSearch.Row?
    private let scan: TerminalFindScan.Operation
    private let select: @MainActor (ScrollbackSearch.Match?, Bool) -> Void
    private let changed: @MainActor () -> Void
    private var previousState: TerminalFindBufferState?
    private var epoch: UInt64 = 0
    private var request: UInt64 = 0
    private var query = ""
    private var queryAnchor = 0
    private var queryTime = ContinuousClock.now
    private var notBefore = ContinuousClock.now
    private var needsWork = false
    private var pipeline: Task<Void, Never>?
    private var cache: [Int: CapturedRow] = [:]
    // A cache bound, not a search bound: capture still visits every buffer row.
    private let cacheCapacity = 16_384
    private var result: Result?
    private var ranges: [Range<Int>] = []
    private var current: Int?
    private var navigation = 0
    private var initialSelectionCompleted = false
    private var validationOffset = 0
    private(set) var diagnostics = Diagnostics()

    init(
        state: @escaping @MainActor () -> TerminalFindBufferState?,
        line: @escaping @MainActor (Int) -> BufferLine?,
        readRow: @escaping @MainActor (Int) -> ScrollbackSearch.Row?,
        scan: @escaping TerminalFindScan.Operation,
        select: @escaping @MainActor (ScrollbackSearch.Match?, Bool) -> Void,
        changed: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.line = line
        self.readRow = readRow
        self.scan = scan
        self.select = select
        self.changed = changed
    }

    var isSearching: Bool { !query.isEmpty && (needsWork || pipeline != nil) }
    var matchCount: Int { ranges.reduce(0) { $0 + $1.count } }
    var matchIndex: Int {
        guard let current, let index = ordinal(current) else { return 0 }
        return index + 1
    }

    private var currentMatch: ScrollbackSearch.Match? {
        guard let result, let current, contains(current), result.matches.indices.contains(current) else { return nil }
        return result.matches[current]
    }

    func setQuery(_ next: String) {
        guard !next.isEmpty else {
            clear()
            return
        }
        guard let state = synchronize() else { return }
        if next.unicodeScalars.elementsEqual(query.unicodeScalars), let result,
            result.snapshot.startGeneration == state.generation,
            result.snapshot.endGeneration == state.generation, !isSearching
        {
            queryAnchor = state.viewportBottom
            current = defaultIndex(above: queryAnchor)
            emitSelection(reveal: true, state: state)
            changed()
            schedule()
            return
        }
        request &+= 1
        query = next
        queryAnchor = state.viewportBottom
        queryTime = .now
        notBefore = queryTime + Self.debounce
        result = nil
        ranges = []
        current = nil
        navigation = 0
        initialSelectionCompleted = false
        needsWork = true
        select(nil, false)
        changed()
        schedule()
    }

    func clear() {
        request &+= 1
        query = ""
        needsWork = false
        result = nil
        ranges = []
        current = nil
        navigation = 0
        initialSelectionCompleted = false
        select(nil, false)
        changed()
    }

    func bufferChanged() {
        guard !query.isEmpty, let state = synchronize() else { return }
        if !needsWork, pipeline == nil { notBefore = .now + Self.debounce }
        needsWork = true
        updateRanges(state)
        emitSelection(reveal: false, state: state)
        changed()
        schedule()
    }

    func navigate(_ delta: Int) {
        guard !query.isEmpty, let state = synchronize() else { return }
        updateRanges(state)
        navigation &+= delta
        if isSearching || result == nil {
            needsWork = true
            schedule()
        } else {
            consumeNavigation()
            emitSelection(reveal: true, state: state)
        }
        changed()
    }

    /// Layout/reset invalidation is separate from ordinary content generations.
    private func synchronize() -> TerminalFindBufferState? {
        guard let next = state() else { return nil }
        if let old = previousState {
            let geometryChanged =
                next.buffer != old.buffer || next.columns != old.columns
                || next.rows != old.rows || next.resizeGeneration != old.resizeGeneration
            let historyChanged =
                next.trimmed < old.trimmed || next.end < old.end
                || (next.trimmed == old.trimmed && old.historyEnd > old.trimmed
                    && (next.firstLine != old.firstLine || next.firstLineGeneration != old.firstLineGeneration))
            if geometryChanged || historyChanged {
                epoch &+= 1
                result = nil
                ranges = []
                current = nil
                initialSelectionCompleted = false
                validationOffset = 0
                needsWork = !query.isEmpty
                select(nil, false)
            }
        }
        previousState = next
        return next
    }

    private func schedule() {
        guard pipeline == nil, needsWork, !query.isEmpty else { return }
        pipeline = Task { [weak self] in
            while let deadline = self?.notBefore, ContinuousClock.now < deadline {
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
            guard let snapshot = await self?.capture(), let operation = self?.scan else {
                self?.finish()
                return
            }
            self?.diagnostics.scansStarted += 1
            let rows = snapshot.rows
            let query = snapshot.query
            let origin = snapshot.origin
            let output = await operation(rows, query, origin)
            self?.publish(snapshot, output)
            self?.finish()
        }
    }

    private func finish() {
        pipeline = nil
        changed()
        schedule()
    }

    private func capture() async -> Snapshot? {
        guard !query.isEmpty, let first = synchronize() else { return nil }
        let capturedRequest = request
        let capturedEpoch = epoch
        let capturedQuery = query
        needsWork = false
        diagnostics.lastQueryDelayMilliseconds = TerminalFindScan.milliseconds(queryTime.duration(to: .now))
        var chunks: [[ScrollbackSearch.Row]] = []
        var stamps: [[CapturedRow?]] = []
        var chunk: [ScrollbackSearch.Row] = []
        var stampChunk: [CapturedRow?] = []
        var offset = 0
        while offset < first.count {
            let start = ContinuousClock.now
            guard capturedRequest == request, capturedEpoch == epoch, let now = synchronize(),
                capturedEpoch == epoch
            else {
                diagnostics.rejectedResults += 1
                return nil
            }
            var processed = 0
            repeat {
                let entry = captureRow(absolute: first.trimmed + offset, state: now)
                chunk.append(entry?.row ?? ScrollbackSearch.Row(text: ""))
                stampChunk.append(entry)
                if chunk.count == Self.rowsPerPass {
                    chunks.append(chunk)
                    stamps.append(stampChunk)
                    chunk = []
                    stampChunk = []
                }
                offset += 1
                processed += 1
            } while offset < first.count && processed < Self.rowsPerPass
                && start.duration(to: .now) < Self.snapshotBudget
            diagnostics.snapshotPasses += 1
            diagnostics.largestSnapshotRows = max(diagnostics.largestSnapshotRows, processed)
            diagnostics.largestSnapshotMilliseconds = max(
                diagnostics.largestSnapshotMilliseconds, TerminalFindScan.milliseconds(start.duration(to: .now)))
            diagnostics.snapshotsRanOnMainThread = diagnostics.snapshotsRanOnMainThread && Thread.isMainThread
            if offset < first.count { try? await Task.sleep(for: .milliseconds(1)) }
        }
        if !chunk.isEmpty {
            chunks.append(chunk)
            stamps.append(stampChunk)
        }
        guard capturedRequest == request, let last = synchronize(), capturedEpoch == epoch else {
            diagnostics.rejectedResults += 1
            return nil
        }
        diagnostics.snapshotsCompleted += 1
        return Snapshot(
            request: capturedRequest, epoch: capturedEpoch, query: capturedQuery,
            origin: first.trimmed, count: first.count, historyEnd: first.historyEnd,
            startGeneration: first.generation, endGeneration: last.generation,
            rows: chunks, stamps: stamps)
    }

    private func captureRow(absolute: Int, state: TerminalFindBufferState) -> CapturedRow? {
        let index = absolute - state.trimmed
        guard index >= 0, index < state.count, let currentLine = line(index) else { return nil }
        let next = line(index + 1)
        let slot = absolute % cacheCapacity
        if let entry = cache[slot], entry.epoch == epoch, entry.absolute == absolute, isCurrent(entry, state: state) {
            diagnostics.rowCacheHits += 1
            return entry
        }
        guard let row = readRow(index) else { return nil }
        let entry = CapturedRow(
            epoch: epoch, absolute: absolute, line: currentLine, generation: currentLine.generation,
            nextLine: next, nextGeneration: next?.generation, row: row)
        cache[slot] = entry
        diagnostics.rowCopies += 1
        return entry
    }

    private func isCurrent(_ entry: CapturedRow, state: TerminalFindBufferState) -> Bool {
        let index = entry.absolute - state.trimmed
        guard index >= 0, index < state.count, line(index) === entry.line,
            entry.line.generation == entry.generation
        else { return false }
        let next = line(index + 1)
        return next === entry.nextLine && next?.generation == entry.nextGeneration
    }

    private func publish(_ snapshot: Snapshot, _ output: TerminalFindScan.Output) {
        guard snapshot.request == request, snapshot.epoch == epoch,
            snapshot.query.unicodeScalars.elementsEqual(query.unicodeScalars),
            let state = synchronize(), snapshot.epoch == epoch
        else {
            diagnostics.rejectedResults += 1
            return
        }
        let previous = currentMatch
        current = nil
        result = Result(snapshot: snapshot, matches: output.matches)
        diagnostics.lastScanMilliseconds = output.milliseconds
        diagnostics.lastScanRanOnMainThread = output.ranOnMainThread
        diagnostics.acceptedResults += 1
        let complete = snapshot.startGeneration == state.generation && snapshot.endGeneration == state.generation
        if !complete { needsWork = true }
        updateRanges(state, preserving: previous)
        if initialSelectionCompleted, let previous, let index = index(of: previous), contains(index) {
            current = index
        } else {
            current = defaultIndex(above: queryAnchor)
        }
        let explicitNavigation = navigation != 0
        consumeNavigation()
        if complete, matchCount == 0 { navigation = 0 }
        let reveal = explicitNavigation || (complete && !initialSelectionCompleted)
        if complete { initialSelectionCompleted = true }
        emitSelection(reveal: reveal, state: state)
        changed()
    }

    /// Validate only bounded row metadata. The immutable history prefix can be
    /// retained while live rows change; a partial counter never claims completion.
    private func updateRanges(_ state: TerminalFindBufferState, preserving preferred: ScrollbackSearch.Match? = nil) {
        guard let result, result.snapshot.epoch == epoch else {
            ranges = []
            current = nil
            return
        }
        let snapshot = result.snapshot
        if snapshot.startGeneration == state.generation && snapshot.endGeneration == state.generation {
            ranges = result.matches.isEmpty ? [] : [0..<result.matches.count]
            return
        }
        var rows: [Range<Int>] = []
        let historyStart = max(state.trimmed, snapshot.origin)
        let historyEnd = min(state.historyEnd, snapshot.historyEnd)
        if historyStart < historyEnd { rows.append(historyStart..<historyEnd) }
        let tailStart = max(state.trimmed, snapshot.historyEnd)
        let tailEnd = min(state.end, snapshot.end)
        if tailStart < tailEnd {
            var checked = Set<Int>()
            var valid: [Int] = []
            func check(_ absolute: Int) {
                guard checked.count < Self.rowsPerPass, checked.insert(absolute).inserted else { return }
                if let stamp = snapshot.stamp(at: absolute), isCurrent(stamp, state: state) { valid.append(absolute) }
            }
            if let selected = preferred ?? currentMatch, selected.line >= tailStart, selected.endLine < tailEnd,
                selected.endLine - selected.line < Self.rowsPerPass
            {
                for absolute in selected.line...selected.endLine { check(absolute) }
            }
            let count = tailEnd - tailStart
            for step in 0..<min(Self.rowsPerPass, count) {
                check(tailStart + (validationOffset + step) % count)
            }
            validationOffset = (validationOffset + Self.rowsPerPass) % count
            for absolute in valid.sorted() {
                if let last = rows.last, last.upperBound == absolute {
                    rows[rows.count - 1] = last.lowerBound..<(absolute + 1)
                } else {
                    rows.append(absolute..<(absolute + 1))
                }
            }
        }
        ranges = []
        for rowRange in rows {
            let lower = lowerBound { $0.line >= rowRange.lowerBound }
            let upper = lowerBound { $0.endLine >= rowRange.upperBound }
            guard lower < upper else { continue }
            if let last = ranges.last, last.upperBound >= lower {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, upper)
            } else {
                ranges.append(lower..<upper)
            }
        }
        if let current, !contains(current) { self.current = nil }
    }

    private func lowerBound(_ predicate: (ScrollbackSearch.Match) -> Bool) -> Int {
        guard let result else { return 0 }
        var lower = 0
        var upper = result.matches.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if predicate(result.matches[middle]) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }

    private func contains(_ index: Int) -> Bool { ranges.contains { $0.contains(index) } }

    private func ordinal(_ index: Int) -> Int? {
        var offset = 0
        for range in ranges {
            if range.contains(index) { return offset + index - range.lowerBound }
            offset += range.count
        }
        return nil
    }

    private func defaultIndex(above anchor: Int) -> Int? {
        let end = lowerBound { $0.line > anchor }
        return ranges.reversed().compactMap { range in
            let index = min(end, range.upperBound) - 1
            return index >= range.lowerBound ? index : nil
        }.first ?? ranges.first?.lowerBound
    }

    private func index(of match: ScrollbackSearch.Match) -> Int? {
        let index = lowerBound {
            $0.line > match.line || ($0.line == match.line && $0.columns.lowerBound >= match.columns.lowerBound)
        }
        guard let result, result.matches.indices.contains(index), result.matches[index] == match else { return nil }
        return index
    }

    private func consumeNavigation() {
        let count = matchCount
        guard count > 0 else { return }
        if current == nil { current = defaultIndex(above: queryAnchor) }
        guard navigation != 0 else { return }
        let old = current.flatMap(ordinal) ?? 0
        var target = (old + navigation % count + count) % count
        for range in ranges {
            if target < range.count {
                current = range.lowerBound + target
                break
            }
            target -= range.count
        }
        navigation = 0
        initialSelectionCompleted = true
    }

    private func emitSelection(reveal: Bool, state: TerminalFindBufferState) {
        guard let result, let match = currentMatch else {
            select(nil, false)
            return
        }
        guard let start = result.snapshot.stamp(at: match.line),
            let end = result.snapshot.stamp(at: match.endLine),
            isCurrent(start, state: state), isCurrent(end, state: state)
        else {
            self.result = nil
            ranges = []
            current = nil
            needsWork = true
            select(nil, false)
            schedule()
            return
        }
        select(match, reveal)
    }
}
