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
}
