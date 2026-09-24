import Foundation
import Testing

@testable import SigilKit

struct RemoteScreenTests {
    private func window(
        _ texts: [String], first: Int = 0, gen: Int = 0, alt: Bool = false, styles: [Int: [[Int]]] = [:]
    ) -> RemoteScreenWindow {
        let rows = texts.enumerated().map { offset, text in
            RemoteScreen.Row(i: first + offset, t: text, s: styles[first + offset])
        }
        return RemoteScreenWindow(
            gen: gen, alt: alt, first: first, end: first + texts.count, rows: rows, palette: ["000000"],
            fg: "ffffff", bg: "000000")
    }

    @Test func firstWindowIsFullAndCarriesTheTheme() throws {
        var stream = RemoteScreenStream()
        let screenUpdate = stream.update(window(["a", "b"]), tabID: "T1")

        let screen = try #require(screenUpdate)
        #expect(screen.rows.map(\.t) == ["a", "b"])
        #expect(screen.palette == ["000000"])
        #expect(screen.fg == "ffffff")
        #expect(screen.first == 0 && screen.end == 2)
        #expect(stream.update(window(["a", "b"]), tabID: "T1") == nil)
    }

    @Test func onlyChangedRowsAreSentAndTheThemeIsNotRepeated() throws {
        var stream = RemoteScreenStream()
        _ = stream.update(window(["a", "b", "c"]), tabID: "T1")
        let screenUpdate = stream.update(window(["a", "B", "c", "d"]), tabID: "T1")

        let screen = try #require(screenUpdate)
        #expect(screen.rows.map(\.i) == [1, 3])
        #expect(screen.rows.map(\.t) == ["B", "d"])
        #expect(screen.palette == nil)
        #expect(screen.end == 4)
    }

    @Test func aStyleChangeAloneIsAChange() throws {
        var stream = RemoteScreenStream()
        _ = stream.update(window(["ok"]), tabID: "T1")
        let screenUpdate = stream.update(window(["ok"], styles: [0: [[0, 2, 2, -1, 1]]]), tabID: "T1")

        let screen = try #require(screenUpdate)
        #expect(screen.rows.count == 1)
        #expect(screen.rows[0].s == [[0, 2, 2, -1, 1]])
    }

    @Test func scrollingSendsTheNewRowsAndMovesTheBounds() throws {
        var stream = RemoteScreenStream()
        _ = stream.update(window(["a", "b", "c"]), tabID: "T1")
        // The window slid down by one: "a" is history now, "d" is new.
        let screenUpdate = stream.update(window(["b", "c", "d"], first: 1), tabID: "T1")

        let screen = try #require(screenUpdate)
        #expect(screen.rows.map(\.t) == ["d"])
        #expect(screen.first == 1 && screen.end == 4)
    }

    @Test func shrinkingWithoutRowChangesStillReportsTheEnd() throws {
        var stream = RemoteScreenStream()
        _ = stream.update(window(["a", "b", "c"]), tabID: "T1")
        let screenUpdate = stream.update(window(["a", "b"]), tabID: "T1")

        let screen = try #require(screenUpdate)
        #expect(screen.rows.isEmpty)
        #expect(screen.end == 2)
    }

    @Test func aNewTabOrGenerationStartsOver() throws {
        var stream = RemoteScreenStream()
        _ = stream.update(window(["a"]), tabID: "T1")
        let otherUpdate = stream.update(window(["a"]), tabID: "T2")

        let other = try #require(otherUpdate)
        #expect(other.rows.map(\.t) == ["a"])
        #expect(other.palette != nil)
        let resetUpdate = stream.update(window(["a"], gen: 1), tabID: "T2")

        let reset = try #require(resetUpdate)
        #expect(reset.gen == 1)
        #expect(reset.rows.count == 1)
        #expect(stream.update(window(["a"], gen: 1), tabID: "T2") == nil)
        let forcedUpdate = stream.update(window(["a"], gen: 1), tabID: "T2", force: true)

        let forced = try #require(forcedUpdate)
        #expect(forced.rows.count == 1)
    }

    @Test func alternateScreenIsFlaggedOnlyWhenActive() throws {
        var stream = RemoteScreenStream()
        let normalUpdate = stream.update(window(["a"]), tabID: "T1")

        let normal = try #require(normalUpdate)
        #expect(normal.alt == nil)
        let altUpdate = stream.update(window(["a"], gen: 2, alt: true), tabID: "T1")

        let alt = try #require(altUpdate)
        #expect(alt.alt == true)
    }

    @Test func styleRunsMergeEqualNeighboursAndSkipPlainText() throws {
        var runs = RemoteStyleRuns()
        let red = RemoteStyleRuns.Cell(fg: 1, bg: RemoteScreen.defaultColor, flags: 0)
        let bold = RemoteStyleRuns.Cell(fg: RemoteScreen.defaultColor, bg: RemoteScreen.defaultColor, flags: 1)
        for (offset, cell) in [red, red, .plain, bold, bold, bold, .plain].enumerated() {
            runs.append(cell, at: offset)
        }
        #expect(runs.finish() == [[0, 2, 1, -1, 0], [3, 3, -1, -1, 1]])
        var plain = RemoteStyleRuns()
        plain.append(.plain, at: 0)
        #expect(plain.finish() == nil)
    }

    @Test func trueColourAndHexEncodeAsTheSpecSays() {
        #expect(RemoteScreen.trueColor(red: 0x12, green: 0x34, blue: 0x56) == (1 << 24) + 0x123456)
        #expect(RemoteScreen.hex(0x00ff00) == "00ff00")
        #expect(RemoteScreen.hex(0xff12_3456) == "123456")
    }

    @Test func rowsEncodeOnlyTheFieldsTheyUse() throws {
        let row = RemoteScreen.Row(i: 3, t: "x")
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(json.contains("\"i\":3"))
        #expect(!json.contains("\"w\""))
        #expect(!json.contains("\"s\""))
        let decoded = try JSONDecoder().decode(RemoteScreen.Row.self, from: Data(json.utf8))
        #expect(decoded == row)
    }
}
