import Foundation
import Testing

@testable import SigilKit

@Suite("ScrollbackSearch")
struct ScrollbackSearchTests {

    private static let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    @Test func matchesEveryLineThatContainsTheQueryAndNoOther() {
        let lines = ["alpha beta", "gamma", "beta beta", "delta"]
        var search = ScrollbackSearch()
        search.setQuery("beta", in: lines)

        let hitLines = Set(search.matches.map(\.line))
        let expected = Set(lines.indices.filter { lines[$0].range(of: "beta", options: Self.fold) != nil })
        #expect(hitLines == expected)

        for match in search.matches {
            #expect(slice(lines, match).compare("beta", options: Self.fold) == .orderedSame)
        }
    }

    @Test func foldingIgnoresCaseAndDiacritics() {
        let lines = ["Café", "CAFE", "cafe", "cafè", "other"]
        var search = ScrollbackSearch()
        search.setQuery("cafe", in: lines)

        #expect(search.matchCount == lines.filter { $0.range(of: "cafe", options: Self.fold) != nil }.count)
        for match in search.matches {
            #expect(slice(lines, match).compare("cafe", options: Self.fold) == .orderedSame)
        }
        #expect(!search.matches.contains { $0.line == lines.firstIndex(of: "other") })
    }

    @Test func nextAndPreviousWrapAroundTheHitList() {
        let lines = ["one", "two", "one", "one"]
        var search = ScrollbackSearch()
        search.setQuery("one", in: lines)
        #expect(search.matchCount > 1)

        let first = search.currentMatch
        for _ in 0..<search.matchCount {
            _ = search.findNext()
        }
        #expect(search.currentMatch == first)

        let last = search.findPrevious()
        #expect(last == search.matches.last)
        #expect(search.findNext() == first)
    }

    @Test func queryStartsAtTheLastHitOnOrAboveTheGivenLine() {
        let lines = ["one", "x", "one", "x", "one"]
        var search = ScrollbackSearch()

        search.setQuery("one", in: lines.map { ScrollbackSearch.Row(text: $0) }, startingAtOrAbove: 3)
        #expect(search.currentMatch?.line == 2)

        search.setQuery("one", in: lines.map { ScrollbackSearch.Row(text: $0) }, startingAtOrAbove: 4)
        #expect(search.currentMatch?.line == 4)

        search.setQuery("x", in: lines.map { ScrollbackSearch.Row(text: $0) }, startingAtOrAbove: 0)
        #expect(search.currentMatch?.line == 1)
    }

    @Test func emptyQueryClearsHitsAndCurrent() {
        var search = ScrollbackSearch()
        search.setQuery("keep", in: ["keep this", "and that"])
        #expect(search.matchCount > 0)
        #expect(search.current != nil)

        search.setQuery("", in: ["keep this", "and that"])
        #expect(search.matchCount == 0)
        #expect(search.current == nil)
        #expect(search.query.isEmpty)
        #expect(search.findNext() == nil)
        #expect(search.findPrevious() == nil)
    }

    @Test func queryLongerThanEveryHardLineFindsNothing() {
        let lines = ["short", "also short", "tiny"]
        let longest = lines.map(\.count).max() ?? 0
        var search = ScrollbackSearch()
        search.setQuery(String(repeating: "q", count: longest + 1), in: lines)

        #expect(search.matches.isEmpty)
        #expect(search.current == nil)
    }

    @Test func findsAcrossSoftWrappedRowsAndReturnsCellEndpoints() {
        let rows = [
            ScrollbackSearch.Row(text: "abc", cellColumns: [0, 1, 2, 3]),
            ScrollbackSearch.Row(
                text: "def", cellColumns: [0, 1, 2, 3], isWrapped: true),
        ]
        var search = ScrollbackSearch()
        search.setQuery("cde", in: rows)

        #expect(search.matchCount == 1)
        #expect(search.currentMatch?.line == 0)
        #expect(search.currentMatch?.columns.lowerBound == 2)
        #expect(search.currentMatch?.endLine == 1)
        #expect(search.currentMatch?.endColumn == 2)
    }

    @Test func doesNotSearchAcrossHardLineBreaks() {
        let rows = [
            ScrollbackSearch.Row(text: "abc"),
            ScrollbackSearch.Row(text: "def"),
        ]
        var search = ScrollbackSearch()
        search.setQuery("cde", in: rows)

        #expect(search.matches.isEmpty)
    }

    @Test func spacesAtASoftWrapRemainPartOfTheLogicalLine() {
        let rows = [
            ScrollbackSearch.Row(text: "abc  "),
            ScrollbackSearch.Row(text: "def", isWrapped: true),
        ]
        var search = ScrollbackSearch()
        search.setQuery("c  d", in: rows)

        #expect(search.matchCount == 1)
        #expect(search.currentMatch?.line == 0)
        #expect(search.currentMatch?.columns.lowerBound == 2)
        #expect(search.currentMatch?.endLine == 1)
        #expect(search.currentMatch?.endColumn == 1)
    }

    @Test func extendedAndWideCharactersMapBackToTerminalCells() {
        let rows = [
            ScrollbackSearch.Row(
                text: "👩‍💻界a",
                cellColumns: [0, 2, 4, 5]
            )
        ]
        var search = ScrollbackSearch()
        search.setQuery("👩‍💻界a", in: rows)

        #expect(search.matchCount == 1)
        #expect(search.currentMatch?.columns == 0..<5)
        #expect(search.currentMatch?.endLine == 0)
        #expect(search.currentMatch?.endColumn == 5)
    }

    @Test func foldedMatchWithDifferentUTF8LengthKeepsCharacterColumns() {
        let rows = [ScrollbackSearch.Row(text: "Straße", cellColumns: [0, 1, 2, 3, 4, 5, 6])]
        var search = ScrollbackSearch()
        search.setQuery("STRASSE", in: rows)

        #expect(search.matchCount == 1)
        #expect(search.currentMatch?.columns == 0..<6)
    }

    @Test func hitsOnOneLineDoNotOverlap() {
        let lines = ["foo foo foo"]
        var search = ScrollbackSearch()
        search.setQuery("foo", in: lines)

        #expect(search.matchCount == 3)
        for (earlier, later) in zip(search.matches, search.matches.dropFirst()) {
            #expect(earlier.line == later.line)
            #expect(earlier.columns.upperBound <= later.columns.lowerBound)
        }
    }

    @Test func aLongSoftWrappedLineIsSearchedInLinearTime() {
        // One minified JSON line of 192k characters, soft-wrapped over 1,600 rows.
        let chunk = String(repeating: "{\"key\":\"value\"},", count: 8)
        let rows = (0..<1_600).map { ScrollbackSearch.Row(text: chunk, isWrapped: $0 > 0) }
        var search = ScrollbackSearch()
        let clock = ContinuousClock()

        let elapsed = clock.measure { search.setQuery("e", in: rows) }

        #expect(search.matchCount == 1_600 * 8 * 2)
        #expect(search.matches.last?.line == 1_599)
        #expect(search.matches.last?.columns == (chunk.count - 4)..<(chunk.count - 3))
        #expect(elapsed < .milliseconds(500))
    }

    private func slice(_ lines: [String], _ match: ScrollbackSearch.Match) -> String {
        let line = lines[match.line]
        let start = line.index(line.startIndex, offsetBy: match.columns.lowerBound)
        let end = line.index(line.startIndex, offsetBy: match.columns.upperBound)
        return String(line[start..<end])
    }
}
