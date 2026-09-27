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

    private func run(_ step: Step, on controller: TerminalController) {
        switch step {
        case .query(let query): controller.setFindQuery(query)
        case .next: controller.findNext()
        case .previous: controller.findPrevious()
        }
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

    @Test func anEmptyQueryClearsWithoutReadingTheRows() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        output(view, "needle one\r\nneedle two\r\n")

        controller.setFindQuery("")
        #expect(controller.bufferRowReads == 0)

        controller.setFindQuery("needle")
        #expect(controller.findMatchCount == 2)
        #expect(view.selection.active)
        let reads = controller.bufferRowReads

        controller.setFindQuery("")
        #expect(controller.bufferRowReads == reads)
        #expect(controller.findMatchCount == 0)
        #expect(controller.findMatchIndex == 0)
        #expect(!view.selection.active)

        controller.findNext()
        controller.findPrevious()
        #expect(controller.bufferRowReads == reads)
        #expect(controller.findMatchIndex == 0)
    }

    @Test func nextPreviousAndQueryEditsOnUnchangedOutputReadTheRowsOnce() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        output(view, (0..<300).map { $0 % 10 == 0 ? "needle \($0)" : "filler \($0)" }.joined(separator: "\r\n"))

        for query in ["n", "ne", "nee", "need", "needl", "needle"] {
            controller.setFindQuery(query)
        }
        #expect(controller.bufferRowReads == 1)
        #expect(controller.findMatchCount == 30)

        for _ in 0..<5 { controller.findNext() }
        for _ in 0..<3 { controller.findPrevious() }
        controller.setFindQuery("needle")
        #expect(controller.bufferRowReads == 1)
    }

    @Test func outputBetweenNextCallsIsSearched() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        output(view, "needle one\r\n")
        controller.setFindQuery("needle")
        controller.findNext()
        #expect(controller.findMatchCount == 1)
        #expect(controller.bufferRowReads == 1)

        output(view, "needle two\r\n")
        controller.findNext()

        #expect(controller.bufferRowReads == 2)
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: 0, row: 1))

        output(view, "needle three\r\n")
        controller.findPrevious()
        #expect(controller.bufferRowReads == 3)
        #expect(controller.findMatchCount == 3)
        #expect(controller.findMatchIndex == 1)
    }

    @Test func aWiderViewReflowsTheRowsAndIsSearchedAgain() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let columns = view.getTerminal().cols
        output(view, String(repeating: "x", count: columns - 3) + "needle\r\n")
        controller.setFindQuery("needle")
        #expect(view.selection.start == Position(col: columns - 3, row: 0))
        #expect(view.selection.end.row == 1)

        view.setFrameSize(NSSize(width: view.frame.width * 2, height: view.frame.height))
        #expect(view.getTerminal().cols > columns + 6)
        controller.findNext()

        #expect(controller.bufferRowReads == 2)
        #expect(controller.findMatchCount == 1)
        #expect(view.selection.start == Position(col: columns - 3, row: 0))
        #expect(view.selection.end == Position(col: columns + 3, row: 0))
    }

    @Test func aLargerFontRewrapsTheRowsAndIsSearchedAgain() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let columns = view.getTerminal().cols
        output(view, String(repeating: "x", count: columns - 10) + "needle\r\n")
        controller.setFindQuery("needle")
        #expect(view.selection.start == Position(col: columns - 10, row: 0))

        controller.setFontSize(26)
        let narrower = view.getTerminal().cols
        #expect(narrower < columns - 10)
        controller.findPrevious()

        #expect(controller.bufferRowReads == 2)
        #expect(controller.findMatchCount == 1)
        #expect(
            view.selection.start
                == Position(col: (columns - 10) % narrower, row: (columns - 10) / narrower))
    }

    /// Each step matches a controller that reads every row again, as Find did
    /// before, including the start at the newest hit and the scroll position.
    @Test func cachedStepsMatchReadingTheRowsEveryTime() throws {
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

        var rereads = reread.bufferRowReads
        for step in steps {
            // An empty write moves the buffer version without changing a row.
            output(rereadView, "")
            run(step, on: cached)
            run(step, on: reread)
            #expect(reread.bufferRowReads == rereads + 1)
            rereads = reread.bufferRowReads
            #expect(state(cached, cachedView) == state(reread, rereadView))
        }
        #expect(cached.bufferRowReads == 1)
    }

    @Test func wideCellsAndWrappedHitsSelectTheirCells() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let columns = view.getTerminal().cols
        output(view, "界界 needle\r\n" + String(repeating: "x", count: columns - 2) + "needle\r\n")

        controller.setFindQuery("needle")
        #expect(controller.findMatchCount == 2)
        #expect(controller.findMatchIndex == 2)
        #expect(view.selection.start == Position(col: columns - 2, row: 1))
        #expect(view.selection.end == Position(col: 4, row: 2))

        controller.findNext()
        #expect(view.selection.start == Position(col: 5, row: 0))
        #expect(view.selection.end == Position(col: 11, row: 0))
        #expect(controller.bufferRowReads == 1)
    }

    @Test func theFirstHitIsTheNewestOnScreenAndTheViewDoesNotMove() throws {
        let controller = TerminalController()
        let view = try terminal(controller)
        let filler = (0..<300).map { "filler \($0)" }.joined(separator: "\r\n")
        output(view, "needle old\r\n" + filler + "\r\nneedle new\r\n")
        let top = view.getTerminal().buffer.yDisp

        controller.setFindQuery("needle")
        #expect(controller.findMatchIndex == 2)
        #expect(view.getTerminal().buffer.yDisp == top)

        controller.findPrevious()
        #expect(controller.findMatchIndex == 1)
        #expect(view.getTerminal().buffer.yDisp < top)

        // The same query again starts from the new viewport, with no new read.
        controller.setFindQuery("needle")
        #expect(controller.findMatchIndex == 1)
        #expect(controller.bufferRowReads == 1)
    }
}
