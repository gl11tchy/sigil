import Foundation
import Testing

@testable import SigilKit

/// Find keeps one buffer snapshot per content version and reuses its hits.
@Suite("MacFind ScrollbackSearch")
struct MacFindScrollbackSearchTests {

    private static func rows(_ lines: [String]) -> [ScrollbackSearch.Row] {
        lines.map { ScrollbackSearch.Row(text: $0) }
    }

    /// Wide, extended, folded, wrapped and plain rows in one buffer.
    private static let mixed: [ScrollbackSearch.Row] = [
        ScrollbackSearch.Row(text: "needle one"),
        ScrollbackSearch.Row(text: "👩‍💻界 needle", cellColumns: [0, 2, 4, 5, 6, 7, 8, 9, 10, 11]),
        ScrollbackSearch.Row(text: "Straße NEEDLE"),
        ScrollbackSearch.Row(text: "ab nee"),
        ScrollbackSearch.Row(text: "dle 界 café", cellColumns: [0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11], isWrapped: true),
        ScrollbackSearch.Row(text: "Café CAFE cafè"),
        ScrollbackSearch.Row(text: "foo foo foo"),
        ScrollbackSearch.Row(text: ""),
        ScrollbackSearch.Row(text: "neédle"),
    ]

    @Test func theSameVersionAndQueryReuseTheHitsWithoutSearchingAgain() {
        var search = ScrollbackSearch()
        search.setQuery("needle", in: ScrollbackSearch.Text(Self.rows(["needle", "x", "needle"]), version: 7))
        let hits = search.matches
        #expect(hits.count == 2)

        // Different rows under the same version: a reused result cannot see them.
        let decoy = ScrollbackSearch.Text(Self.rows(["no hits here"]), version: 7)
        search.update(decoy)
        #expect(search.matches == hits)
        search.setQuery("needle", in: decoy, startingAtOrAbove: 0)
        #expect(search.matches == hits)
        #expect(search.current == 0)
    }

    @Test func aNewVersionSearchesTheNewRows() {
        var search = ScrollbackSearch()
        search.setQuery("needle", in: ScrollbackSearch.Text(Self.rows(["needle"]), version: 1))
        #expect(search.matchCount == 1)

        search.update(ScrollbackSearch.Text(Self.rows(["needle", "needle", "needle"]), version: 2))
        #expect(search.matchCount == 3)
        #expect(search.current == 0)
    }

    @Test func textWithoutAVersionIsAlwaysSearched() {
        var search = ScrollbackSearch()
        search.setQuery("needle", in: ScrollbackSearch.Text(Self.rows(["needle"])))
        search.update(ScrollbackSearch.Text(Self.rows(["needle", "needle"])))
        #expect(search.matchCount == 2)

        search.updateRows(Self.rows(["plain"]))
        #expect(search.matchCount == 0)
        #expect(search.current == nil)
    }

    @Test func aDifferentQueryOnTheSameVersionSearchesAgain() {
        let text = ScrollbackSearch.Text(Self.rows(["alpha beta", "beta"]), version: 3)
        var search = ScrollbackSearch()
        search.setQuery("alpha", in: text)
        #expect(search.matchCount == 1)

        search.setQuery("beta", in: text)
        #expect(search.matchCount == 2)
    }

    @Test func aCanonicallyEquivalentQueryIsSearchedAgain() {
        var search = ScrollbackSearch()
        search.setQuery("\u{E9}", in: ScrollbackSearch.Text(Self.rows(["\u{E9}"]), version: 4))
        #expect(search.matchCount == 1)

        search.setQuery("e\u{301}", in: ScrollbackSearch.Text(Self.rows(["x"]), version: 4))
        #expect(search.matchCount == 0)
    }

    @Test func clearingForgetsTheVersion() {
        var search = ScrollbackSearch()
        search.setQuery("needle", in: ScrollbackSearch.Text(Self.rows(["needle"]), version: 5))
        search.clear()
        #expect(search == ScrollbackSearch())

        search.setQuery("needle", in: ScrollbackSearch.Text(Self.rows(["x"]), version: 5))
        #expect(search.matchCount == 0)
    }

    /// Every step of a find session gives the same hits and current hit as the
    /// row path, which searches from scratch each time.
    @Test(arguments: ["needle", "NEEDLE", "cafe", "界", "👩‍💻", "strasse", "foo", "e", "zz"])
    func versionedSearchMatchesSearchingFromScratch(query: String) {
        let text = ScrollbackSearch.Text(Self.mixed, version: 1)
        var cached = ScrollbackSearch()
        var fresh = ScrollbackSearch()

        cached.setQuery(query, in: text, startingAtOrAbove: 5)
        fresh.setQuery(query, in: Self.mixed, startingAtOrAbove: 5)
        #expect(cached.matches == fresh.matches)
        #expect(cached.current == fresh.current)

        for step in 0..<12 {
            cached.update(text)
            fresh.updateRows(Self.mixed)
            if step % 4 == 3 {
                cached.findPrevious()
                fresh.findPrevious()
            } else {
                cached.findNext()
                fresh.findNext()
            }
            #expect(cached.matches == fresh.matches)
            #expect(cached.current == fresh.current)
            #expect(cached.currentMatch == fresh.currentMatch)
        }
    }

    @Test func wideWrappedAndFoldedHitsKeepTheirCells() {
        var search = ScrollbackSearch()
        search.setQuery("needle", in: ScrollbackSearch.Text(Self.mixed, version: 1))

        #expect(search.matches.map(\.line) == [0, 1, 2, 3, 8])
        #expect(search.matches[1].columns == 5..<11)
        let wrapped = search.matches[3]
        #expect(wrapped.columns == 3..<4)
        #expect(wrapped.endLine == 4)
        #expect(wrapped.endColumn == 3)

        search.setQuery("界 café", in: ScrollbackSearch.Text(Self.mixed, version: 1))
        #expect(search.matchCount == 1)
        #expect(search.currentMatch?.line == 4)
        #expect(search.currentMatch?.columns == 4..<11)
    }

    /// Several search chunks, with wrapped, wide and folded rows in each and a
    /// few long lines soft-wrapped over five rows.
    private static func manyChunks() -> [ScrollbackSearch.Row] {
        var rows: [ScrollbackSearch.Row] = []
        for block in 0..<420 {
            rows += mixed
            if block % 50 == 0 {
                rows.append(ScrollbackSearch.Row(text: "needle " + String(repeating: "y", count: 33)))
                let middle = String(repeating: "y", count: 17)
                for _ in 0..<4 {
                    rows.append(ScrollbackSearch.Row(text: middle + "needle" + middle, isWrapped: true))
                }
            }
        }
        return rows
    }

    @Test(arguments: ["needle", "NEEDLE", "e", "cafe", "界", "👩‍💻", "strasse", "y", "yn", "zz"])
    func chunkedSearchMatchesOneFullPass(query: String) {
        let rows = Self.manyChunks()
        #expect(rows.filter { !$0.isWrapped }.count > 4 * ScrollbackSearch.linesPerChunk)
        let expected = Self.referenceMatches(query, in: rows)
        var search = ScrollbackSearch()

        search.setQuery(query, in: ScrollbackSearch.Text(rows, version: 1), startingAtOrAbove: 2_000)

        #expect(search.matches == expected)
        #expect(search.current == (expected.isEmpty ? nil : expected.lastIndex { $0.line <= 2_000 } ?? 0))
    }

    @Test(arguments: [
        ScrollbackSearch.linesPerChunk - 1, ScrollbackSearch.linesPerChunk,
        ScrollbackSearch.linesPerChunk + 1, 2 * ScrollbackSearch.linesPerChunk + 1,
    ])
    func chunkEdgesKeepEveryHitInLineOrder(lineCount: Int) {
        let rows = (0..<lineCount).map { ScrollbackSearch.Row(text: "needle \($0) needle") }
        var search = ScrollbackSearch()

        search.setQuery("needle", in: rows)

        #expect(search.matches == Self.referenceMatches("needle", in: rows))
        #expect(search.matches.map(\.line) == (0..<lineCount).flatMap { [$0, $0] })
    }

    /// The search as it was before chunking: every logical line in one pass.
    private static func referenceMatches(
        _ query: String,
        in rows: [ScrollbackSearch.Row]
    ) -> [ScrollbackSearch.Match] {
        let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var lines: [(text: String, positions: [(row: Int, column: Int)])] = []
        for (rowIndex, row) in rows.enumerated() {
            let columns =
                row.cellColumns.count == row.text.count + 1
                ? row.cellColumns : Array(0...row.text.count)
            if lines.isEmpty || !row.isWrapped {
                lines.append(("", []))
            }
            let index = lines.count - 1
            if lines[index].positions.isEmpty {
                lines[index].positions.append((rowIndex, columns[0]))
            } else {
                lines[index].positions[lines[index].positions.count - 1] = (rowIndex, columns[0])
            }
            lines[index].text += row.text
            for boundary in columns.dropFirst() {
                lines[index].positions.append((rowIndex, boundary))
            }
        }
        return lines.flatMap { logical in
            var found: [ScrollbackSearch.Match] = []
            var searchRange = logical.text.startIndex..<logical.text.endIndex
            var offset = 0
            while let hit = logical.text.range(of: query, options: fold, range: searchRange) {
                let startOffset = offset + logical.text.distance(from: searchRange.lowerBound, to: hit.lowerBound)
                let endOffset = startOffset + logical.text.distance(from: hit.lowerBound, to: hit.upperBound)
                guard logical.positions.indices.contains(startOffset),
                    logical.positions.indices.contains(endOffset)
                else { break }
                let start = logical.positions[startOffset]
                let end = logical.positions[endOffset]
                let sameRowEnd = end.row == start.row ? end.column : start.column + 1
                found.append(
                    ScrollbackSearch.Match(
                        line: start.row,
                        columns: start.column..<max(start.column, sameRowEnd),
                        endLine: end.row,
                        endColumn: end.column
                    )
                )
                searchRange = hit.upperBound..<logical.text.endIndex
                offset = endOffset
            }
            return found
        }
    }
}
