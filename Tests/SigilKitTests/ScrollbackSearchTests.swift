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

    @Test func queryLongerThanEveryLineFindsNothing() {
        let lines = ["short", "also short", "tiny"]
        let longest = lines.map(\.count).max() ?? 0
        var search = ScrollbackSearch()
        search.setQuery(String(repeating: "q", count: longest + 1), in: lines)

        #expect(search.matches.isEmpty)
        #expect(search.current == nil)
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

    private func slice(_ lines: [String], _ match: ScrollbackSearch.Match) -> String {
        let line = lines[match.line]
        let start = line.index(line.startIndex, offsetBy: match.columns.lowerBound)
        let end = line.index(line.startIndex, offsetBy: match.columns.upperBound)
        return String(line[start..<end])
    }
}
