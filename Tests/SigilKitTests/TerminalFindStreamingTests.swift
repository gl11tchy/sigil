import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import SigilKit

private actor FindScanGate {
    private var released = false
    private let holdingAfter: Int
    private var calls = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(holdingAfter: Int = 0) { self.holdingAfter = holdingAfter }

    func wait() async {
        calls += 1
        guard calls > holdingAfter else { return }
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

@Suite("Streaming terminal Find", .serialized)
@MainActor
struct TerminalFindStreamingTests {
    init() { TerminalTestSupport.prepareAppKit() }

    private func output(_ view: GrokProcessTerminalView, _ text: String) {
        view.dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    private func settled(_ controller: TerminalController) async {
        #expect(await TerminalTestSupport.waitUntil(timeout: .seconds(10)) { !controller.isFinding })
    }

    private func holdScans(_ controller: TerminalController, with gate: FindScanGate) {
        controller.findScanOperation = { rows, query, origin in
            await gate.wait()
            return await TerminalFindScan.run(rows, query, origin)
        }
    }

    @Test func anOldQueryCannotPublishAfterTheNewQuery() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate()
        holdScans(controller, with: gate)
        output(view, "old needle\r\nnew value\r\n")
        controller.setFindQuery("old")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 1 })
        var sawOldSelection = false
        controller.onFindChange = { [weak controller, weak view] in
            if let controller, let view, controller.findMatchCount > 0,
                view.selection.active, view.selection.start.row == 0
            {
                sawOldSelection = true
            }
        }
        defer {
            controller.onFindChange = nil
            controller.clearFind()
        }
        controller.setFindQuery("new")
        await gate.release()
        await settled(controller)
        #expect(!sawOldSelection)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: 0, row: 1))
        #expect(controller.findDiagnostics.rejectedResults >= 1)
    }

    @Test func clearingDuringAnInFlightScanDoesNotRestoreSelection() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate()
        holdScans(controller, with: gate)
        output(view, "needle\r\n")
        controller.setFindQuery("needle")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 1 })
        controller.clearFind()
        #expect(!controller.isFinding)
        #expect(controller.findMatchCount == 0)
        await gate.release()
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.rejectedResults >= 1 })
        #expect(controller.findMatchCount == 0)
        #expect(!view.selection.active)
    }

    @Test func changedRowGenerationsCannotSelectTheOldCells() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate()
        holdScans(controller, with: gate)
        output(view, "old needle\r\n")
        controller.setFindQuery("needle")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 1 })
        output(view, "\u{1b}[H\u{1b}[2Kreplacement")
        var selectedChangedCells = false
        controller.onFindChange = { [weak view] in
            if view?.selection.active == true { selectedChangedCells = true }
        }
        defer {
            controller.onFindChange = nil
            controller.clearFind()
        }
        await gate.release()
        await settled(controller)
        #expect(!selectedChangedCells)
        #expect(controller.findMatchCount == 0)
        #expect(!view.selection.active)
        output(view, "\u{1b}[H\u{1b}[2Knew needle")
        await settled(controller)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: 4, row: 0))
    }

    @Test func resizeRejectsTheOldWrappedCoordinates() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate()
        holdScans(controller, with: gate)
        let columns = view.getTerminal().cols
        output(view, String(repeating: "x", count: columns - 3) + "needle\r\n")
        controller.setFindQuery("needle")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 1 })
        view.setFrameSize(NSSize(width: view.frame.width * 2, height: view.frame.height))
        #expect(!view.selection.active)
        await gate.release()
        await settled(controller)
        #expect(controller.findDiagnostics.rejectedResults >= 1)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: columns - 3, row: 0))
        #expect(view.selection.end == Position(col: columns + 3, row: 0))
        controller.clearFind()
    }

    @Test func alternateBufferAndResetNeverReuseTheNormalBufferResult() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate()
        holdScans(controller, with: gate)
        output(view, "normal needle\r\n")
        controller.setFindQuery("needle")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 1 })
        output(view, "\u{1b}[?1049h\u{1b}[Halternate needle")
        await gate.release()
        await settled(controller)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: 10, row: 0))
        output(view, "\u{1b}[?1049l")
        await settled(controller)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: 7, row: 0))
        output(view, "\u{1b}cfresh output")
        await settled(controller)
        #expect(controller.findMatchCount == 0)
        #expect(!view.selection.active)
        controller.clearFind()
    }

    @Test func clearingScrollbackInvalidatesItsOldAbsoluteRows() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        output(view, "history needle\r\n" + (0..<300).map { "filler \($0)" }.joined(separator: "\r\n"))
        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findMatchCount == 1)
        output(view, "\u{1b}[3J")
        await settled(controller)
        #expect(controller.findMatchCount == 0)
        #expect(!view.selection.active)
        controller.clearFind()
    }

    @Test func navigationQueuedBeforeTheFirstScanUsesTheLatestQuery() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        output(view, "needle one\r\nneedle two\r\nneedle three\r\n")
        controller.setFindQuery("needle")
        controller.findNext()
        await settled(controller)
        #expect(controller.findMatchCount == 3)
        #expect(controller.findMatchIndex == 1)
        #expect(view.selection.start == Position(col: 0, row: 0))
        controller.findPrevious()
        #expect(controller.findMatchIndex == 3)
        #expect(view.selection.start == Position(col: 0, row: 2))
        controller.clearFind()
    }

    @Test func trimmingScrollbackRebasesQueuedNavigationWithoutChangingTheTargetText() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        output(view, (0..<10_000).map { "row \($0) needle" }.joined(separator: "\r\n") + "\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        controller.findPrevious()
        let absolute = view.selection.start.row + view.getTerminal().buffer.totalLinesTrimmed
        output(view, (0..<100).map { "stream \($0) needle" }.joined(separator: "\r\n") + "\r\n")
        #expect(view.getTerminal().buffer.totalLinesTrimmed > 0)
        controller.findNext()
        await settled(controller)
        let row = absolute + 1 - view.getTerminal().buffer.totalLinesTrimmed
        #expect(view.selection.start.row == row)
        let selected = try #require(view.getTerminal().bufferLine(atRow: row))
        #expect(selected.translateToString(trimRight: true).contains("row 9999 needle"))
        controller.clearFind()
    }

    @Test func noMatchNavigationIsNotReplayedAgainstLaterOutput() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        output(view, "no hits\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findMatchCount == 0)
        controller.findNext()
        output(view, "\u{1b}[Hneedle one\r\nneedle two\r\n")
        await settled(controller)
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: 0, row: 1))
        controller.clearFind()
    }

    @Test func aChangedRowKeepsOnlyTheNavigationAnchorUntilItsHitIsVerifiedAgain() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        output(view, "needle one\r\nneedle two\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        controller.findPrevious()
        #expect(view.selection.start == Position(col: 0, row: 0))
        output(view, "\u{1b}[1;20Hchanged")
        #expect(!view.selection.active)
        controller.findNext()
        await settled(controller)
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: 0, row: 1))
        controller.clearFind()
    }

    @Test func nextDoesNotWrapWithinAPartialSnapshotBeforeNewRowsAreScanned() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate(holdingAfter: 1)
        holdScans(controller, with: gate)
        defer { controller.clearFind() }
        output(view, "needle one\r\nfiller\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        output(view, "")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 2 })
        controller.findNext()
        output(view, "needle two\r\n")
        await gate.release()
        await settled(controller)
        #expect(controller.findDiagnostics.acceptedResults >= 3)
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: 0, row: 2))
    }

    @Test func aPartialFallbackDoesNotReplaceTheUnverifiedPreviousNavigationOrigin() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate(holdingAfter: 1)
        holdScans(controller, with: gate)
        defer { controller.clearFind() }
        output(view, "needle one\r\nfiller\r\nneedle two\r\nfiller\r\nneedle three\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        controller.findNext()
        #expect(view.selection.start == Position(col: 0, row: 0))
        output(view, "")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 2 })
        controller.findPrevious()
        output(view, "\u{1b}[2;1Hchanged filler")
        await gate.release()
        await settled(controller)
        #expect(controller.findDiagnostics.acceptedResults >= 3)
        #expect(controller.findMatchCount == 3)
        #expect(controller.findMatchIndex == 3)
        #expect(view.selection.start == Position(col: 0, row: 4))
    }

    @Test func partialResultsCanNavigateWithinTheirVerifiedHistoryBeforeCompletion() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let gate = FindScanGate(holdingAfter: 1)
        holdScans(controller, with: gate)
        output(view, (0..<500).map { "row \($0) needle" }.joined(separator: "\r\n") + "\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        controller.findNext()
        #expect(view.selection.start.row == 0)
        var navigatedBeforeCompletion = false
        controller.onFindChange = { [weak controller, weak view] in
            if let controller, let view, controller.findDiagnostics.acceptedResults == 2,
                controller.isFinding, view.selection.active, view.selection.start.row == 1
            {
                navigatedBeforeCompletion = true
            }
        }
        defer {
            controller.onFindChange = nil
            controller.clearFind()
        }
        output(view, "")
        #expect(await TerminalTestSupport.waitUntil { controller.findDiagnostics.scansStarted == 2 })
        controller.findNext()
        output(view, "new needle\r\n")
        await gate.release()
        await settled(controller)
        #expect(navigatedBeforeCompletion)
        #expect(controller.findMatchCount == 501)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: 6, row: 1))
    }

    @MainActor
    private final class StreamProbe {
        var active = true
        var writes = 0
        var heartbeatDelays: [Double] = []
    }

    @Test func continuousCappedOutputMakesProgressWithBoundedMainActorWork() async throws {
        let controller = TerminalController()
        let view = try #require(controller.view as? GrokProcessTerminalView)
        output(view, (0..<10_000).map { "row \($0) needle 界 👩‍💻" }.joined(separator: "\r\n") + "\r\n")
        let probe = StreamProbe()
        let stream = Task { @MainActor in
            for index in 0..<400 {
                if Task.isCancelled { break }
                view.dataReceived(slice: ArraySlice(Array("stream \(index) needle\r\n".utf8)))
                probe.writes += 1
                try? await Task.sleep(for: .milliseconds(5), tolerance: .zero)
            }
            probe.active = false
        }
        let heartbeat = Task { @MainActor in
            while probe.active, !Task.isCancelled {
                let start = ContinuousClock.now
                try? await Task.sleep(for: .milliseconds(1), tolerance: .zero)
                probe.heartbeatDelays.append(max(0, TerminalFindScan.milliseconds(start.duration(to: .now)) - 1))
            }
        }
        defer {
            stream.cancel()
            heartbeat.cancel()
            controller.clearFind()
        }
        let start = ContinuousClock.now
        controller.setFindQuery("needle")
        let progressed = await TerminalTestSupport.waitUntil(timeout: .milliseconds(1_500)) {
            probe.active && controller.findMatchCount > 5_000
        }
        let firstProgress = TerminalFindScan.milliseconds(start.duration(to: .now))
        #expect(progressed, "Continuous output must not continually restart and starve the scan")
        #expect(controller.findDiagnostics.acceptedResults > 0)
        #expect(controller.findDiagnostics.largestSnapshotRows <= TerminalFindSession.rowsPerPass)
        #expect(controller.findDiagnostics.snapshotsRanOnMainThread)
        #expect(!controller.findDiagnostics.lastScanRanOnMainThread)
        if view.selection.active {
            let selected = try #require(view.getTerminal().bufferLine(atRow: view.selection.start.row))
            #expect(selected.translateToString(trimRight: true).contains("needle"))
        }
        await stream.value
        await heartbeat.value
        await settled(controller)
        #expect(controller.findMatchCount > 9_000)
        #expect(probe.writes == 400)
        let delays = probe.heartbeatDelays.sorted()
        let receipt: [String: Any] = [
            "fixtureRows": 10_000, "streamWrites": probe.writes,
            "firstProgressMilliseconds": firstProgress,
            "heartbeatDelayP95Milliseconds": delays.isEmpty
                ? 0 : delays[min(delays.count - 1, delays.count * 95 / 100)],
            "heartbeatDelayMaxMilliseconds": delays.last ?? 0,
            "largestSnapshotRows": controller.findDiagnostics.largestSnapshotRows,
            "largestSnapshotMilliseconds": controller.findDiagnostics.largestSnapshotMilliseconds,
            "lastScanMilliseconds": controller.findDiagnostics.lastScanMilliseconds,
            "acceptedResults": controller.findDiagnostics.acceptedResults,
            "finalMatches": controller.findMatchCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("REA-1193 continuous output measurement \(String(decoding: data, as: UTF8.self))")
    }
}
