import Foundation
import Testing

@testable import SigilKit

@Suite("SearchMatchHighlight")
struct SearchMatchHighlightTests {

    @Test func emptyOrWhitespaceQueryYieldsNoRanges() {
        for query in ["", "   ", "\t", "\n", " \t\n "] {
            #expect(SearchMatchHighlight.ranges(in: "Auth rewrite", query: query).isEmpty)
            #expect(
                SearchMatchHighlight.runs(in: "Auth rewrite", query: query) == [
                    .init(text: "Auth rewrite", isMatch: false)
                ])
            #expect(!SearchMatchHighlight.contains("Auth rewrite", query: query))
            // Listing still shows every row; highlighting stays off.
            #expect(SessionScanner.matches(namedSession, query: query))
        }
    }

    @Test func emptyHaystackYieldsNoRanges() {
        #expect(SearchMatchHighlight.ranges(in: "", query: "auth").isEmpty)
        #expect(SearchMatchHighlight.runs(in: "", query: "auth").isEmpty)
        #expect(SearchMatchHighlight.runs(in: "", query: "").isEmpty)
        #expect(!SearchMatchHighlight.contains("", query: "auth"))
    }

    @Test func queryLongerThanHaystackMisses() {
        #expect(SearchMatchHighlight.ranges(in: "ab", query: "abcd").isEmpty)
        #expect(!SearchMatchHighlight.contains("ab", query: "abcd"))
    }

    @Test func wholeStringIsOneMatch() {
        #expect(slices("Auth", query: "Auth") == ["Auth"])
        #expect(
            SearchMatchHighlight.runs(in: "Auth", query: "Auth") == [
                .init(text: "Auth", isMatch: true)
            ])
    }

    @Test func matchAtStartMiddleAndEnd() {
        #expect(slices("Auth rewrite", query: "Auth") == ["Auth"])
        #expect(slices("Auth rewrite", query: "re") == ["re"])
        #expect(slices("Auth rewrite", query: "write") == ["write"])
        #expect(
            SearchMatchHighlight.runs(in: "Auth rewrite", query: "Auth") == [
                .init(text: "Auth", isMatch: true),
                .init(text: " rewrite", isMatch: false),
            ])
        #expect(
            SearchMatchHighlight.runs(in: "Auth rewrite", query: "write") == [
                .init(text: "Auth re", isMatch: false),
                .init(text: "write", isMatch: true),
            ])
    }

    @Test func multipleNonOverlappingHits() {
        #expect(slices("foo bar foo", query: "foo") == ["foo", "foo"])
        #expect(
            SearchMatchHighlight.runs(in: "foo bar foo", query: "foo") == [
                .init(text: "foo", isMatch: true),
                .init(text: " bar ", isMatch: false),
                .init(text: "foo", isMatch: true),
            ])
    }

    @Test func overlappingNeedleAdvancesPastEachHit() {
        // "aa" in "aaaa" is two adjacent hits, merged into one painted run.
        #expect(slices("aaaa", query: "aa") == ["aaaa"])
        #expect(
            SearchMatchHighlight.runs(in: "aaaa", query: "aa") == [
                .init(text: "aaaa", isMatch: true)
            ])
        #expect(slices("aaa", query: "aa") == ["aa"])
        #expect(
            SearchMatchHighlight.runs(in: "aaa", query: "aa") == [
                .init(text: "aa", isMatch: true),
                .init(text: "a", isMatch: false),
            ])
    }

    @Test func trimsQueryTheSameWayMatchesDoes() {
        #expect(slices("Auth rewrite", query: "  Auth  ") == ["Auth"])
        #expect(SearchMatchHighlight.contains("Auth rewrite", query: "\tAuth\n"))
        #expect(SessionScanner.matches(namedSession, query: "  Auth  ", displayedTitle: "Auth rewrite"))
    }

    @Test func caseInsensitive() {
        #expect(slices("Auth rewrite", query: "auth") == ["Auth"])
        #expect(slices("AUTH REWRITE", query: "auth") == ["AUTH"])
        #expect(slices("auth rewrite", query: "AUTH") == ["auth"])
        #expect(slices("HTTP client", query: "http") == ["HTTP"])
    }

    @Test func diacriticInsensitive() {
        #expect(slices("Café", query: "cafe") == ["Café"])
        #expect(slices("CAFE", query: "café") == ["CAFE"])
        #expect(slices("cafè", query: "CAFE") == ["cafè"])
        #expect(slices("naive", query: "naïve") == ["naive"])
        #expect(slices("naïve", query: "naive") == ["naïve"])
    }

    @Test func expandingClusterSharpS() {
        let hay = "Straße"
        #expect(SearchMatchHighlight.contains(hay, query: "ss"))
        #expect(slices(hay, query: "ss") == ["ß"])
        #expect(slices(hay, query: "strasse") == [hay])
        // fold("ß") is "ss", so query "s" hits both the leading S and ß.
        #expect(slices(hay, query: "s") == ["S", "ß"])
        #expect(SearchMatchHighlight.contains(hay, query: "s"))
        #expect(SessionScanner.matches(session(title: hay, cwd: "/tmp/x"), query: "ss"))
    }

    @Test func ligatureExpandsUnderFold() {
        let hay = "ﬁle"
        let needle = SearchMatchHighlight.fold("fi")
        let folded = SearchMatchHighlight.fold(hay)
        if folded.contains(needle) {
            #expect(!SearchMatchHighlight.ranges(in: hay, query: "fi").isEmpty)
            #expect(SearchMatchHighlight.contains(hay, query: "fi"))
        }
    }

    @Test func emojiAndCombiningStayOnGraphemeBoundaries() {
        let hay = "Fix 🚀 launch"
        #expect(slices(hay, query: "launch") == ["launch"])
        #expect(slices(hay, query: "🚀") == ["🚀"])
        let launch = SearchMatchHighlight.ranges(in: hay, query: "launch")
        #expect(launch.count == 1)
        #expect(String(hay[launch[0]]) == "launch")
        let naive = "nai\u{0308}ve"  // nai + combining diaeresis + ve
        #expect(SearchMatchHighlight.contains(naive, query: "naive"))
        let ranges = SearchMatchHighlight.ranges(in: naive, query: "naive")
        #expect(ranges.count == 1)
        #expect(String(naive[ranges[0]]) == naive)
    }

    @Test func literalSpecialCharactersAreNotARegex() {
        #expect(slices("a+b vs a-b", query: "a+b") == ["a+b"])
        #expect(slices("cost is $5", query: "$5") == ["$5"])
        #expect(slices("foo.bar", query: ".") == ["."])
        #expect(SearchMatchHighlight.ranges(in: "abc", query: "a.c").isEmpty)
    }

    @Test func asPrefixOfMapsOntoTheContainerAndIgnoresTheSuffix() {
        let subtitle = "sigil · 14m"
        let hits = SearchMatchHighlight.ranges(in: "sigil", query: "sig", asPrefixOf: subtitle)
        #expect(hits.map { String(subtitle[$0]) } == ["sig"])
        #expect(SearchMatchHighlight.ranges(in: "sigil", query: "m", asPrefixOf: subtitle).isEmpty)
        #expect(SearchMatchHighlight.ranges(in: "sigil", query: "14", asPrefixOf: subtitle).isEmpty)
        #expect(SearchMatchHighlight.ranges(in: "other", query: "o", asPrefixOf: subtitle).isEmpty)

        let pathSubtitle = "~/repos/sigil · 3h"
        let pathHits = SearchMatchHighlight.ranges(
            in: "~/repos/sigil", query: "repos", asPrefixOf: pathSubtitle)
        #expect(pathHits.map { String(pathSubtitle[$0]) } == ["repos"])

        let doubled = "foo-foo · now"
        let doubledHits = SearchMatchHighlight.ranges(
            in: "foo-foo", query: "foo", asPrefixOf: doubled)
        #expect(doubledHits.map { String(doubled[$0]) } == ["foo", "foo"])
    }

    @Test func asPrefixOfWhenContainerIsExactlyTheHaystack() {
        let name = "sigil"
        let hits = SearchMatchHighlight.ranges(in: name, query: "sig", asPrefixOf: name)
        #expect(hits.map { String(name[$0]) } == ["sig"])
    }

    @Test func displayedTitleAndCLISummaryUseTheSameFold() {
        let session = namedSession
        #expect(SessionScanner.matches(session, query: "Auth", displayedTitle: "Auth rewrite"))
        #expect(
            !SearchMatchHighlight.ranges(in: "Auth rewrite", query: "Auth").isEmpty)
        #expect(SearchMatchHighlight.ranges(in: session.title, query: "Auth").isEmpty)
        #expect(SessionScanner.matches(session, query: "CLI", displayedTitle: "Auth rewrite"))
        #expect(!SearchMatchHighlight.ranges(in: session.title, query: "CLI").isEmpty)
        #expect(
            SearchMatchHighlight.ranges(in: session.projectName, query: "project").map {
                String(session.projectName[$0])
            } == ["project"])
        #expect(!SearchMatchHighlight.ranges(in: session.cwd, query: "/tmp").isEmpty)
    }

    @Test func rangesAgreeWithFoldContainsOnACorpus() {
        let haystacks = [
            "", "a", "Auth rewrite", "Café CAFE cafe", "Straße", "strasse",
            "İstanbul", "naive", "naïve", "foo bar foo", "ß", "ﬁle",
            "Fix 🚀 launch", "a+b", "HTTP", "sigil · 14m",
            "nai\u{0308}ve", "  padded  ",
        ]
        let queries = [
            "", " ", "a", "auth", "  Auth  ", "cafe", "ss", "ß", "s", "i",
            "naive", "foo", "fi", "launch", "a+b", "http", "14", "🚀",
            "nope", "rewrite", "pad",
        ]
        for haystack in haystacks {
            for query in queries {
                let needle = SearchMatchHighlight.fold(
                    query.trimmingCharacters(in: .whitespacesAndNewlines))
                let expectHit =
                    !needle.isEmpty && SearchMatchHighlight.fold(haystack).contains(needle)
                let ranges = SearchMatchHighlight.ranges(in: haystack, query: query)
                #expect(
                    !ranges.isEmpty == expectHit,
                    "haystack: \(haystack.debugDescription) query: \(query.debugDescription)"
                )
                #expect(SearchMatchHighlight.contains(haystack, query: query) == expectHit)
                for range in ranges {
                    #expect(SearchMatchHighlight.fold(String(haystack[range])).contains(needle))
                }
            }
        }
    }

    @Test func perGraphemeFoldMatchesWholeStringFoldOnTheSameCorpus() {
        let samples = [
            "", "Auth rewrite", "Café", "Straße", "ßss", "İstanbul",
            "ﬁle", "naive", "naïve", "nai\u{0308}ve", "🚀", "Ångström",
            "é\u{0301}", "ΟΣ", "ßß", "  café CAFÉ  ",
        ]
        for sample in samples {
            let whole = SearchMatchHighlight.fold(sample)
            let mapped = SearchMatchHighlight.foldMap(sample).folded
            #expect(
                mapped == whole,
                "per-grapheme \(mapped.debugDescription) vs whole \(whole.debugDescription) for \(sample)"
            )
        }
    }

    @Test func scannerMatchIffSomeVisibleFieldHasARange() {
        let session = namedSession
        let queries = ["Auth", "CLI", "project", "/tmp", "nope", "  rewrite ", "s1"]
        let displayed = "Auth rewrite"
        for query in queries {
            let listed = SessionScanner.matches(session, query: query, displayedTitle: displayed)
            let painted = paintHaystacksContain(session, displayed: displayed, query: query)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                #expect(listed)
            } else {
                #expect(listed == painted)
            }
        }
    }

    @Test func listingMatchesTildeDisplayPathTheSameAsPaint() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let session = session(title: "CLI summary", cwd: home + "/repos/sigil")
        #expect(session.displayPath == "~/repos/sigil")
        let displayed = "Auth rewrite"
        for query in ["~", "~/repos", "repos", "sigil", "CLI", "Auth", "nope"] {
            let listed = SessionScanner.matches(session, query: query, displayedTitle: displayed)
            let painted = paintHaystacksContain(session, displayed: displayed, query: query)
            #expect(listed == painted, "query \(query.debugDescription)")
        }
        #expect(SessionScanner.matches(session, query: "~"))
        #expect(SessionScanner.matches(session, query: "~/repos"))
        let paint = SearchMatchHighlight.row(
            displayedTitle: displayed,
            cliTitle: session.title,
            projectName: session.projectName,
            cwd: session.cwd,
            displayPath: session.displayPath,
            relativeTime: "14m",
            showsProject: true,
            query: "~/repos"
        )
        #expect(paint.paints)
        #expect(paint.subtitle.hasPrefix("~/repos"))
    }

    @Test func matchedRunsCoverTheWholeHaystack() {
        let hay = "Café and CAFE and cafe"
        let runs = SearchMatchHighlight.runs(in: hay, query: "cafe")
        #expect(runs.map(\.text).joined() == hay)
        #expect(runs.filter(\.isMatch).map(\.text) == ["Café", "CAFE", "cafe"])
    }

    @Test func runsAsPrefixOfUsesTheSameSplitAsRanges() {
        let subtitle = "sigil · 14m"
        let runs = SearchMatchHighlight.runs(in: "sigil", query: "sig", asPrefixOf: subtitle)
        #expect(runs.map(\.text).joined() == subtitle)
        #expect(matched(runs) == ["sig"])
        let miss = SearchMatchHighlight.runs(in: "sigil", query: "14", asPrefixOf: subtitle)
        #expect(miss == [.init(text: subtitle, isMatch: false)])
    }

    @Test func emptyQueryRowKeepsDefaultSubtitleAndDoesNotPaint() {
        let recents = recentsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "")
        #expect(!recents.paints)
        #expect(recents.subtitle == "project · 14m")
        #expect(recents.subtitleRuns == [.init(text: "project · 14m", isMatch: false)])
        let projects = projectsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "")
        #expect(!projects.paints)
        #expect(projects.subtitle == "14m")
    }

    @Test func displayedTitleHitPaintsTitleAndLeavesDefaultSubtitle() {
        let paint = recentsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "Auth")
        #expect(matched(paint.titleRuns) == ["Auth"])
        #expect(paint.subtitle == "project · 14m")
        #expect(matched(paint.subtitleRuns).isEmpty)
        #expect(paint.paints)
    }

    @Test func cliTitleOnlyHitPaintsTheCliSummaryOnTheSubtitle() {
        let paint = recentsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "CLI")
        #expect(matched(paint.titleRuns).isEmpty)
        #expect(paint.subtitle == "CLI summary · 14m")
        #expect(matched(paint.subtitleRuns) == ["CLI"])
        #expect(paint.subtitleRuns.map(\.text).joined() == paint.subtitle)
        #expect(paint.paints)
        #expect(SessionScanner.matches(namedSession, query: "CLI", displayedTitle: "Auth rewrite"))
    }

    @Test func cwdOnlyHitPaintsTheVisiblePathOnTheSubtitle() {
        let paint = recentsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "/tmp")
        #expect(matched(paint.titleRuns).isEmpty)
        #expect(paint.subtitle.hasPrefix("/tmp/project"))
        #expect(matched(paint.subtitleRuns) == ["/tmp"])
        #expect(paint.paints)
    }

    @Test func displayPathHitIsPreferredOverRawCwd() {
        let paint = SearchMatchHighlight.row(
            displayedTitle: "Auth rewrite",
            cliTitle: "CLI summary",
            projectName: "sigil",
            cwd: "/Users/me/repos/sigil",
            displayPath: "~/repos/sigil",
            relativeTime: "14m",
            showsProject: true,
            query: "repos"
        )
        #expect(paint.subtitle == "~/repos/sigil · 14m")
        #expect(matched(paint.subtitleRuns) == ["repos"])
        #expect(matched(paint.titleRuns).isEmpty)
    }

    @Test func projectNameHitPaintsTheShortNameNotTheTimestamp() {
        let paint = recentsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "project")
        #expect(paint.subtitle == "project · 14m")
        #expect(matched(paint.subtitleRuns) == ["project"])
        #expect(!paint.subtitleRuns.contains { $0.isMatch && $0.text.contains("14") })
    }

    @Test func projectsSortLeavesFolderHitsToTheHeader() {
        let row = projectsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "project")
        #expect(matched(row.titleRuns).isEmpty)
        #expect(row.subtitle == "14m")
        #expect(!row.paints)
        let header = SearchMatchHighlight.projectHeader(
            name: "project",
            displayPath: "/tmp/project",
            cwd: "/tmp/project",
            count: 3,
            query: "project"
        )
        #expect(header.text == "project (3)")
        #expect(matched(header.runs) == ["project"])
        #expect(header.paints)
    }

    @Test func projectsHeaderCwdOnlyHitShowsTheMatchingPath() {
        let header = SearchMatchHighlight.projectHeader(
            name: "sigil",
            displayPath: "~/repos/sigil",
            cwd: "/Users/me/repos/sigil",
            count: 4,
            query: "repos"
        )
        #expect(header.text == "~/repos/sigil (4)")
        #expect(matched(header.runs) == ["repos"])
        #expect(header.paints)
    }

    @Test func projectsRowStillPaintsACliOnlyHit() {
        let paint = projectsRow(displayed: "Auth rewrite", cli: "CLI summary", query: "CLI")
        #expect(matched(paint.titleRuns).isEmpty)
        #expect(paint.subtitle == "CLI summary · 14m")
        #expect(matched(paint.subtitleRuns) == ["CLI"])
        #expect(paint.paints)
    }

    @Test func emptyQueryHeaderKeepsTheShortName() {
        let header = SearchMatchHighlight.projectHeader(
            name: "sigil",
            displayPath: "~/repos/sigil",
            cwd: "/Users/me/repos/sigil",
            count: 2,
            query: "  "
        )
        #expect(header.text == "sigil (2)")
        #expect(!header.paints)
    }

    @Test func recentsListedRowsPaintWhenTheQueryIsNonEmpty() {
        let displayed = "Auth rewrite"
        let queries = ["Auth", "CLI", "project", "/tmp", "  rewrite "]
        for query in queries {
            #expect(SessionScanner.matches(namedSession, query: query, displayedTitle: displayed))
            let paint = recentsRow(displayed: displayed, cli: "CLI summary", query: query)
            #expect(paint.paints, "silent Recents match for \(query.debugDescription)")
            #expect(paint.subtitleRuns.map(\.text).joined() == paint.subtitle)
        }
    }

    @Test func keepingMatchVisibleCollapsesALongPrefixAndKeepsTheHit() {
        let long =
            "/Users/me/Library/Developer/Xcode/DerivedData/sigil-abc/SourcePackages/checkouts"
        let visible = SearchMatchHighlight.keepingMatchVisible(long, query: "DerivedData")
        #expect(visible.hasPrefix("…"))
        #expect(visible.count < long.count)
        #expect(SearchMatchHighlight.contains(visible, query: "DerivedData"))
        #expect(!visible.hasPrefix("/Users/me/Library"))
        let runs = SearchMatchHighlight.runs(in: visible, query: "DerivedData")
        #expect(matched(runs) == ["DerivedData"])
    }

    @Test func keepingMatchVisibleLeavesAHitNearTheStartAlone() {
        #expect(
            SearchMatchHighlight.keepingMatchVisible("~/repos/sigil", query: "repos")
                == "~/repos/sigil")
        #expect(SearchMatchHighlight.keepingMatchVisible("~/repos/sigil", query: "~") == "~/repos/sigil")
        #expect(SearchMatchHighlight.keepingMatchVisible("/tmp/project", query: "/tmp") == "/tmp/project")
    }

    @Test func longPathRowStartsTheSubtitleAtTheMatch() {
        let paint = SearchMatchHighlight.row(
            displayedTitle: "Auth rewrite",
            cliTitle: "CLI summary",
            projectName: "checkouts",
            cwd: "/Users/me/Library/Developer/Xcode/DerivedData/sigil-abc/SourcePackages/checkouts",
            displayPath: "~/Library/Developer/Xcode/DerivedData/sigil-abc/SourcePackages/checkouts",
            relativeTime: "14m",
            showsProject: true,
            query: "DerivedData"
        )
        #expect(paint.subtitle.hasPrefix("…"))
        #expect(paint.subtitle.contains("DerivedData"))
        #expect(matched(paint.subtitleRuns) == ["DerivedData"])
        #expect(paint.paints)
    }

    @Test func projectHeaderUsesAMemberPathTheSampleDoesNotHave() {
        let header = SearchMatchHighlight.projectHeader(
            name: "x",
            paths: ["/var/folders/x", "/private/var/folders/x"],
            count: 2,
            query: "private"
        )
        #expect(header.text.hasPrefix("/private/var/folders/x"))
        #expect(matched(header.runs) == ["private"])
        #expect(header.paints)
    }

    @Test func projectsRowPaintsItsPathWhenTheHeaderDoesNotCover() {
        let paint = SearchMatchHighlight.row(
            displayedTitle: "Auth rewrite",
            cliTitle: "CLI summary",
            projectName: "x",
            cwd: "/private/var/folders/x",
            displayPath: "/private/var/folders/x",
            relativeTime: "14m",
            showsProject: false,
            headerCoversQuery: false,
            query: "private"
        )
        #expect(paint.paints)
        #expect(paint.subtitle.hasPrefix("/private/var/folders/x"))
        #expect(matched(paint.subtitleRuns) == ["private"])
    }

    @Test func projectsRowSkipsPathWhenHeaderAlreadyCovers() {
        let paint = SearchMatchHighlight.row(
            displayedTitle: "Auth rewrite",
            cliTitle: "CLI summary",
            projectName: "x",
            cwd: "/private/var/folders/x",
            displayPath: "/private/var/folders/x",
            relativeTime: "14m",
            showsProject: false,
            headerCoversQuery: true,
            query: "private"
        )
        #expect(paint.subtitle == "14m")
        #expect(!paint.paints)
    }

    @Test func pathSwappedHeaderSpeaksThePaintedPath() {
        let paint = SearchMatchHighlight.projectHeader(
            name: "sigil",
            displayPath: "~/repos/sigil",
            cwd: "/Users/me/repos/sigil",
            count: 4,
            query: "repos"
        )
        let searching = SearchMatchHighlight.headerAccessibilityLabel(
            paint: paint, shortName: "sigil", count: 4, isPinned: false, query: "repos")
        #expect(searching == paint.text)
        #expect(searching.contains("repos"))
        let idle = SearchMatchHighlight.headerAccessibilityLabel(
            paint: paint, shortName: "sigil", count: 4, isPinned: true, query: "")
        #expect(idle == "sigil, 4 conversations, pinned")
    }
}

private let namedSession = session(title: "CLI summary", cwd: "/tmp/project")

private func slices(_ haystack: String, query: String) -> [String] {
    SearchMatchHighlight.ranges(in: haystack, query: query).map { String(haystack[$0]) }
}

private func paintHaystacksContain(
    _ session: GrokSession, displayed: String, query: String
) -> Bool {
    SearchMatchHighlight.contains(displayed, query: query)
        || SearchMatchHighlight.contains(session.title, query: query)
        || SearchMatchHighlight.contains(session.projectName, query: query)
        || SearchMatchHighlight.contains(session.displayPath, query: query)
        || SearchMatchHighlight.contains(session.cwd, query: query)
}

private func matched(_ runs: [SearchMatchHighlight.Run]) -> [String] {
    runs.filter(\.isMatch).map(\.text)
}

private func recentsRow(displayed: String, cli: String, query: String) -> SearchMatchHighlight.RowPaint {
    SearchMatchHighlight.row(
        displayedTitle: displayed,
        cliTitle: cli,
        projectName: "project",
        cwd: "/tmp/project",
        displayPath: "/tmp/project",
        relativeTime: "14m",
        showsProject: true,
        query: query
    )
}

private func projectsRow(displayed: String, cli: String, query: String) -> SearchMatchHighlight.RowPaint {
    SearchMatchHighlight.row(
        displayedTitle: displayed,
        cliTitle: cli,
        projectName: "project",
        cwd: "/tmp/project",
        displayPath: "/tmp/project",
        relativeTime: "14m",
        showsProject: false,
        query: query
    )
}

private func session(title: String, cwd: String) -> GrokSession {
    GrokSession(
        id: "s1",
        cwd: cwd,
        summary: title,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        messageCount: 4,
        modelID: nil,
        agentName: nil,
        reasoningEffort: nil,
        directory: URL(fileURLWithPath: cwd).appendingPathComponent("s1")
    )
}
