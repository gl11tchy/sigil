import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import SigilKit

/// Find reads the buffer rows once per buffer version, and gives the same
/// hits, selection and scroll position as reading them on every step.
@Suite("MacFind TerminalController", .serialized)
@MainActor
struct MacFindTerminalControllerTests {

    init() {
        TerminalTestSupport.prepareAppKit()
    }

    @Test func streamingTenThousandRowQueriesDoNotSynchronouslyReadTheBuffer() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        defer { controller.clearFind() }
        let lines = (0..<10_000).map { "row \($0) needle café 界 👩‍💻 " + String(repeating: "x", count: 32) }
        output(view, lines.joined(separator: "\r\n") + "\r\n")
        #expect(view.getTerminal().bufferLine(atRow: 9_999) != nil)
        let clock = ContinuousClock()
        var inputMilliseconds: [Double] = []
        var synchronousReads = 0
        for (index, query) in ["n", "ne", "nee", "need", "needl", "needle"].enumerated() {
            output(view, "stream \(index) needle\r\n")
            let before = controller.bufferRowReads
            let elapsed = clock.measure { controller.setFindQuery(query) }
            inputMilliseconds.append(Self.milliseconds(elapsed))
            synchronousReads += controller.bufferRowReads - before
        }
        await settled(controller)
        let terminal = view.getTerminal()
        var expected = 0
        var row = 0
        while let line = terminal.bufferLine(atRow: row) {
            let text = line.translateToString(trimRight: true, characterProvider: { terminal.getCharacter(for: $0) })
            if text.contains("needle") { expected += 1 }
            row += 1
        }
        #expect(expected > 9_000)
        #expect(controller.findMatchCount == expected)
        #expect(controller.findMatchIndex == expected)
        #expect(controller.findDiagnostics.scansStarted == 1)
        #expect(controller.findDiagnostics.largestSnapshotRows <= TerminalFindSession.rowsPerPass)
        #expect(controller.findDiagnostics.snapshotsRanOnMainThread)
        #expect(!controller.findDiagnostics.lastScanRanOnMainThread)
        #expect(controller.findDiagnostics.lastQueryDelayMilliseconds >= 75)
        let rows = lines.map { ScrollbackSearch.Row(text: $0) }
        let text = ScrollbackSearch.Text(rows, version: 1)
        var scanner = ScrollbackSearch()
        let scan = clock.measure { scanner.setQuery("needle", in: text) }
        let receipt: [String: Any] = [
            "fixtureRows": 10_000, "inputMilliseconds": inputMilliseconds,
            "synchronousFullBufferReads": synchronousReads,
            "immutableScanMilliseconds": Self.milliseconds(scan), "matches": scanner.matchCount,
            "controllerMatches": controller.findMatchCount, "expectedControllerMatches": expected,
            "controllerScanMilliseconds": controller.findDiagnostics.lastScanMilliseconds,
            "largestSnapshotMilliseconds": controller.findDiagnostics.largestSnapshotMilliseconds,
            "largestSnapshotRows": controller.findDiagnostics.largestSnapshotRows,
            "rowCopies": controller.findDiagnostics.rowCopies, "scansStarted": controller.findDiagnostics.scansStarted,
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        print("REA-1193 streaming Find measurement \(String(decoding: data, as: UTF8.self))")
        #expect(
            synchronousReads == 0, "Typing must defer bounded snapshot work and scanning away from the input callback")
        #expect(scanner.matchCount == 10_000)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private func settled(_ controller: TerminalController) async {
        #expect(await TerminalTestSupport.waitUntil(timeout: .seconds(10)) { !controller.isFinding })
    }

    private struct State: Equatable {
        let count: Int
        let index: Int
        let selected: Bool
        let start: Position
        let end: Position
        let top: Int
    }

    private enum Step {
        case query(String)
        case next
        case previous
    }

    private func terminal(_ controller: TerminalController) throws -> GrokProcessTerminalView {
        try #require(controller.view as? GrokProcessTerminalView)
    }

    /// The same path child output takes in the app.
    private func output(_ view: GrokProcessTerminalView, _ text: String) {
        view.dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    private func state(_ controller: TerminalController, _ view: GrokProcessTerminalView) -> State {
        State(
            count: controller.findMatchCount,
            index: controller.findMatchIndex,
            selected: view.selection.active,
            start: view.selection.start,
            end: view.selection.end,
            top: view.getTerminal().buffer.yDisp
        )
    }

    private func run(_ step: Step, on controller: TerminalController) async {
        switch step {
        case .query(let query): controller.setFindQuery(query)
        case .next: controller.findNext()
        case .previous: controller.findPrevious()
        }
        await settled(controller)
    }

    /// Wide and extended characters, folded text, soft-wrapped hits, and enough
    /// rows that a hit can be above the viewport.
    private func mixedOutput(columns: Int) -> String {
        var lines = ["needle at the top", "界界 needle 👩‍💻 NEEDLE", "Straße café CAFE cafè"]
        lines.append(String(repeating: "x", count: columns - 3) + "needle across the wrap")
        lines.append(String(repeating: "界", count: columns / 2) + "needle after wide cells")
        lines += (0..<120).map { $0 % 17 == 0 ? "row \($0) neédle" : "row \($0) filler" }
        lines.append("needle at the bottom")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    @Test func anEmptyQueryClearsWithoutReadingTheRows() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        output(view, "needle one\r\nneedle two\r\n")

        controller.setFindQuery("")
        await settled(controller)
        #expect(controller.findDiagnostics.snapshotsCompleted == 0)

        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findMatchCount == 2)
        #expect(view.selection.active)
        let reads = controller.findDiagnostics.snapshotsCompleted

        controller.setFindQuery("")
        await settled(controller)
        #expect(controller.findDiagnostics.snapshotsCompleted == reads)
        #expect(controller.findMatchCount == 0)
        #expect(controller.findMatchIndex == 0)
        #expect(!view.selection.active)

        controller.findNext()
        await settled(controller)
        controller.findPrevious()
        await settled(controller)
        #expect(controller.findDiagnostics.snapshotsCompleted == reads)
        #expect(controller.findMatchIndex == 0)
    }

    @Test func nextPreviousAndQueryEditsOnUnchangedOutputReadTheRowsOnce() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        output(view, (0..<300).map { $0 % 10 == 0 ? "needle \($0)" : "filler \($0)" }.joined(separator: "\r\n"))

        for query in ["n", "ne", "nee", "need", "needl", "needle"] {
            controller.setFindQuery(query)  // coalesced
        }
        await settled(controller)
        #expect(controller.findDiagnostics.snapshotsCompleted == 1)
        #expect(controller.findMatchCount == 30)

        for _ in 0..<5 { controller.findNext() }
        await settled(controller)
        for _ in 0..<3 { controller.findPrevious() }
        await settled(controller)
        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findDiagnostics.snapshotsCompleted == 1)
    }

    @Test func outputBetweenNextCallsIsSearched() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        output(view, "needle one\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        controller.findNext()
        await settled(controller)
        #expect(controller.findMatchCount == 1)
        #expect(controller.findDiagnostics.snapshotsCompleted == 1)

        output(view, "needle two\r\n")
        controller.findNext()
        await settled(controller)

        #expect(controller.findDiagnostics.snapshotsCompleted == 2)
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: 0, row: 1))

        output(view, "needle three\r\n")
        controller.findPrevious()
        await settled(controller)
        #expect(controller.findDiagnostics.snapshotsCompleted == 3)
        #expect(controller.findMatchCount == 3)
        #expect(controller.findMatchIndex == 1)
    }

    @Test func aWiderViewReflowsTheRowsAndIsSearchedAgain() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let columns = view.getTerminal().cols
        output(view, String(repeating: "x", count: columns - 3) + "needle\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        #expect(view.selection.start == Position(col: columns - 3, row: 0))
        #expect(view.selection.end.row == 1)

        view.setFrameSize(NSSize(width: view.frame.width * 2, height: view.frame.height))
        #expect(view.getTerminal().cols > columns + 6)
        controller.findNext()
        await settled(controller)

        #expect(controller.findDiagnostics.snapshotsCompleted == 2)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: columns - 3, row: 0))
        #expect(view.selection.end == Position(col: columns + 3, row: 0))
    }

    @Test func aLargerFontRewrapsTheRowsAndIsSearchedAgain() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let columns = view.getTerminal().cols
        output(view, String(repeating: "x", count: columns - 10) + "needle\r\n")
        controller.setFindQuery("needle")
        await settled(controller)
        #expect(view.selection.start == Position(col: columns - 10, row: 0))

        controller.setFontSize(26)
        let narrower = view.getTerminal().cols
        #expect(narrower < columns - 10)
        controller.findPrevious()
        await settled(controller)

        #expect(controller.findDiagnostics.snapshotsCompleted == 2)
        #expect(controller.findMatchCount == 1)
        #expect(
            view.selection.start
                == Position(col: (columns - 10) % narrower, row: (columns - 10) / narrower))
    }

    /// Each step matches a controller that reads every row again, as Find did
    /// before, including the start at the newest hit and the scroll position.
    @Test func cachedStepsMatchReadingTheRowsEveryTime() async throws {
        let cached = TerminalController()
        let reread = TerminalController()
        let cachedView = try terminal(cached)
        let rereadView = try terminal(reread)
        let text = mixedOutput(columns: cachedView.getTerminal().cols)
        output(cachedView, text)
        output(rereadView, text)

        var steps: [Step] = [.query("needle")]
        steps += Array(repeating: .previous, count: 4)
        steps += Array(repeating: .next, count: 13)
        steps += [.query("NEEDLE"), .previous, .previous, .query("cafe"), .next, .next, .next, .next]
        steps += [.query("界"), .next, .previous, .previous, .query("👩‍💻"), .next]
        steps += [.query("strasse"), .query("needle"), .previous, .query("zz"), .next, .query("x"), .previous]

        var copies: Int?
        for step in steps {
            // An empty write changes the output generation but not any row.
            output(rereadView, "")
            await run(step, on: cached)
            await run(step, on: reread)
            if let copies {
                #expect(cached.findDiagnostics.rowCopies == copies)
                #expect(reread.findDiagnostics.rowCopies == copies)
            } else {
                copies = cached.findDiagnostics.rowCopies
            }
            #expect(state(cached, cachedView) == state(reread, rereadView))
        }
    }

    @Test func wideCellsAndWrappedHitsSelectTheirCells() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let columns = view.getTerminal().cols
        output(view, "界界 needle\r\n" + String(repeating: "x", count: columns - 2) + "needle\r\n")

        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: columns - 2, row: 1))
        #expect(view.selection.end == Position(col: 4, row: 2))

        controller.findNext()
        await settled(controller)
        #expect(view.selection.start == Position(col: 5, row: 0))
        #expect(view.selection.end == Position(col: 11, row: 0))
        #expect(controller.findDiagnostics.snapshotsCompleted == 1)
    }

    @Test func theFirstHitIsTheNewestOnScreenAndTheViewDoesNotMove() async throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let filler = (0..<300).map { "filler \($0)" }.joined(separator: "\r\n")
        output(view, "needle old\r\n" + filler + "\r\nneedle new\r\n")
        let top = view.getTerminal().buffer.yDisp

        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findMatchIndex == 2)
        #expect(view.getTerminal().buffer.yDisp == top)

        controller.findPrevious()
        await settled(controller)
        #expect(controller.findMatchIndex == 1)
        #expect(view.getTerminal().buffer.yDisp < top)

        // The same query again starts from the new viewport, with no new read.
        controller.setFindQuery("needle")
        await settled(controller)
        #expect(controller.findMatchIndex == 1)
        #expect(controller.findDiagnostics.snapshotsCompleted == 1)
    }
}
