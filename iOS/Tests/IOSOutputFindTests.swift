#if canImport(Sigil)
@testable import Sigil
#endif
import Foundation

/// IOS-2: find marks its matches over the output, off the main thread, and
/// never restyles the output to do it.
enum IOSOutputFindTests {
    typealias Fixtures = IOSOutputFixtures

    /// The loop the text view ran over the whole output on every query before
    /// find moved off it, with the ranges it painted kept instead.
    private static func oldMatches(_ highlight: String, in text: String) -> [NSRange] {
        var painted: [NSRange] = []
        if !highlight.isEmpty {
            let source = text as NSString
            var range = NSRange(location: 0, length: source.length)
            while true {
                let found = source.range(of: highlight, options: [.caseInsensitive], range: range)
                guard found.location != NSNotFound, found.length > 0 else { break }
                painted.append(found)
                let next = found.location + found.length
                range = NSRange(location: next, length: source.length - next)
            }
        }
        return painted
    }

    /// Texts to search: formatted and raw screens full of multi-byte text, and
    /// the cases where case folding changes a match's length.
    private static func texts() throws -> [String] {
        let formatter = try Fixtures.formatter()
        var result = [
            "", "aaaa aaa", "straße STRASSE Strasse", "ﬁle FILE ﬁ", "İstanbul istanbul ISTANBUL",
            "e\u{301}te\u{301} ÉTÉ été", "😀😀 👩‍👩‍👧👩 🇸🇪🇸🇪", "line one\nline two\n",
        ]
        for seed in 0..<6 {
            var rng = Fixtures.Seeded(state: UInt64(seed) &+ 31)
            let model = Fixtures.model(count: 80, grounded: seed % 2 == 0, footer: seed % 3 == 0, using: &rng)
            for raw in [false, true] {
                result.append(OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter).text)
            }
        }
        return result
    }

    /// The same matches as the old loop, for fixed queries and random pieces of
    /// each text in random case, including partial graphemes.
    static func matchesEqualTheOldHighlight() throws {
        let fixed = [
            "", "e", "E", "É", "é", "e\u{301}", "E\u{301}", "\u{301}", "😀", "👩", "👩‍👩‍👧", "🇸", "🇸🇪", "日本", "ü", "Ü",
            "ünï", "SS", "ß", "ss", "ﬁ", "fi", "İ", "i", "résumé", "RÉSUMÉ", "λ", "Λ", "│", " ", "  ", "aa", "then", "THEN",
            "\n", "two\nline", "missing",
        ]
        var rng = Fixtures.Seeded(state: 5)
        var compared = 0
        var found = 0
        for text in try texts() {
            let characters = Array(text)
            var queries = fixed
            for _ in 0..<40 where !characters.isEmpty {
                let start = Int.random(in: 0..<characters.count, using: &rng)
                let end = min(characters.count, start + Int.random(in: 1...8, using: &rng))
                var piece = String(characters[start..<end])
                switch Int.random(in: 0..<4, using: &rng) {
                case 0: piece = piece.uppercased()
                case 1: piece = piece.lowercased()
                case 2: piece = String(String.UnicodeScalarView(piece.unicodeScalars.dropFirst()))
                default: break
                }
                queries.append(piece)
            }
            for query in queries {
                let expected = oldMatches(query, in: text)
                try Expect.equal(OutputFind.matches(of: query, in: text), expected, "matches for \(query.debugDescription)")
                compared += 1
                found += expected.count
            }
        }
        try Expect.true(compared > 500 && found > 1000, "searched widely (\(compared) queries, \(found) matches)")
    }

    /// Marking the lines near the screen as the reader scrolls marks exactly the
    /// units the matches cover there, each once, and nothing when find is clear.
    static func nearbyMarksCoverTheMatches() throws {
        var rng = Fixtures.Seeded(state: 17)
        for text in try texts() where !text.isEmpty {
            let length = (text as NSString).length
            for query in ["e", "É", "ss", "aa", "😀", "\n", "t", "e\nl"] {
                let matches = OutputFind.matches(of: query, in: text)
                var near = IndexSet()
                var marked = IndexSet()
                for _ in 0..<Int.random(in: 1...30, using: &rng) {
                    let start = Int.random(in: 0..<length, using: &rng)
                    let range = NSRange(location: start, length: Int.random(in: 1...(length - start), using: &rng))
                    let span = IndexSet(integersIn: range.location..<NSMaxRange(range))
                    for mark in OutputFind.matches(matches, in: range, besides: near) {
                        let units = IndexSet(integersIn: mark.location..<NSMaxRange(mark))
                        try Expect.true(mark.length > 0 && span.contains(integersIn: units), "\(mark) lies in \(range)")
                        try Expect.true(marked.intersection(units).isEmpty, "\(mark) is marked once")
                        marked.formUnion(units)
                    }
                    near.formUnion(span)
                    try Expect.equal(marked, covered(matches).intersection(near), "\(query.debugDescription): the matches near")
                    try Expect.equal(OutputFind.matches([], in: range, besides: IndexSet()), [], "clear marks nothing")
                }
                let all = NSRange(location: 0, length: length)
                for mark in OutputFind.matches(matches, in: all, besides: near) {
                    marked.formUnion(IndexSet(integersIn: mark.location..<NSMaxRange(mark)))
                }
                try Expect.equal(marked, covered(matches), "\(query.debugDescription): every match once scrolled through")
            }
        }
    }

    private static func covered(_ ranges: [NSRange]) -> IndexSet {
        var result = IndexSet()
        for range in ranges { result.insert(integersIn: range.location..<NSMaxRange(range)) }
        return result
    }

    /// As output streams under an open find, every mark kept through an edit still
    /// sits on the query in the new text, and the next search finds the full set.
    static func marksFollowEdits() throws {
        let formatter = try Fixtures.formatter()
        var kept = 0
        for seed in 0..<14 {
            var rng = Fixtures.Seeded(state: UInt64(seed) &* 104_729 &+ 3)
            var model = Fixtures.model(count: 60, grounded: seed % 3 != 2, footer: seed % 2 == 0, from: 300, using: &rng)
            let raw = seed % 4 == 1
            var shown = OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter)
            let query = ["e", "ok", "É", "😀", "then", "│", "日本"][seed % 7]
            var marks = OutputFind.matches(of: query, in: shown.text)
            for step in 0..<25 {
                IOSOutputEditTests.mutate(&model, grounded: seed % 3 != 2, using: &rng)
                let next = OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter)
                let edit = try Expect.notNil(shown.edit(to: next), "seed \(seed) step \(step): the ground held")
                let source = next.text as NSString
                for mark in OutputFind.matches(marks, after: edit) {
                    try Expect.true(NSMaxRange(mark) <= source.length, "seed \(seed) step \(step): \(mark) is in the text")
                    let again = source.range(of: query, options: [.caseInsensitive, .anchored], range: mark)
                    try Expect.equal(again, mark, "seed \(seed) step \(step): a kept mark sits on the query")
                    kept += 1
                }
                marks = OutputFind.matches(of: query, in: next.text)
                try Expect.equal(marks, oldMatches(query, in: next.text), "seed \(seed) step \(step): the search")
                shown = next
            }
        }
        try Expect.true(kept > 1000, "marks were kept through edits (\(kept))")
    }

    /// The search's answers, which arrive on its queue.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(index: Int, matches: [NSRange]?, onMain: Bool)] = []
        private let arrived = DispatchSemaphore(value: 0)

        func add(_ index: Int, _ matches: [NSRange]?) {
            lock.withLock { items.append((index, matches, Thread.isMainThread)) }
            arrived.signal()
        }

        func wait(for count: Int) throws -> [(index: Int, matches: [NSRange]?, onMain: Bool)] {
            for _ in 0..<count {
                if arrived.wait(timeout: .now() + 20) == .timedOut { throw TestFailure("the search did not answer") }
            }
            return lock.withLock { items }
        }
    }

    /// Queries typed while a search runs are skipped but the last; every answer
    /// comes back in order, off the main thread.
    static func finderSkipsReplacedQueries() throws {
        let text = try texts()[9]
        let queue = DispatchQueue(label: "dev.sigil.find.test")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let finder = OutputFinder(queue: queue)
        let answers = Answers()
        let queries = ["t", "th", "the", "e"]
        for (index, query) in queries.enumerated() {
            finder.submit(query, in: text) { answers.add(index, $0) }
        }
        gate.signal()
        let results = try answers.wait(for: queries.count)
        try Expect.equal(results.map(\.index), [0, 1, 2, 3], "answers come back in order")
        try Expect.equal(results.map { $0.matches != nil }, [false, false, false, true], "replaced queries are skipped")
        try Expect.equal(results[3].matches, oldMatches("e", in: text), "the last query is searched")
        try Expect.true(!(results[3].matches ?? []).isEmpty, "and found")
        try Expect.true(results.allSatisfy { !$0.onMain }, "searched off the main thread")

        finder.submit("É", in: text) { answers.add(4, $0) }
        let alone = try answers.wait(for: 1)
        try Expect.equal(alone[4].matches, oldMatches("É", in: text), "a query alone is searched")
    }
}
