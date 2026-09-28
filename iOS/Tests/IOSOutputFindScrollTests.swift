#if canImport(Sigil)
@testable import Sigil
#endif
import Foundation

/// IOS-2: find shows the last of the matches its search found off the main
/// thread, not a match from a second search of the whole output on it.
enum IOSOutputFindScrollTests {
    typealias Fixtures = IOSOutputFixtures

    /// The last match the search finds is the one the main thread's backward
    /// search found, or overlaps it where matches of the query can overlap, so
    /// the view scrolls to the same place. Neither exists without the other.
    static func lastMatchIsWhereTheOldSearchScrolled() throws {
        let formatter = try Fixtures.formatter()
        var texts = [
            "aaaa aaa", "aaa", "straße STRASSE Strasse", "ﬁle FILE ﬁ", "İstanbul istanbul ISTANBUL",
            "e\u{301}te\u{301} ÉTÉ été", "😀😀 👩‍👩‍👧👩 🇸🇪🇸🇪", "line one\nline two\n",
        ]
        for seed in 0..<6 {
            var rng = Fixtures.Seeded(state: UInt64(seed) &+ 57)
            let model = Fixtures.model(count: 80, grounded: seed % 2 == 0, footer: seed % 3 == 0, using: &rng)
            for raw in [false, true] {
                texts.append(OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter).text)
            }
        }
        let fixed = [
            "e", "É", "e\u{301}", "\u{301}", "😀", "👩", "🇸🇪", "日本", "ü", "SS", "ß", "ss", "ﬁ", "fi", "İ", "i",
            "résumé", "λ", "│", " ", "  ", "aa", "then", "THEN", "ok", "missing",
        ]
        var rng = Fixtures.Seeded(state: 17)
        var compared = 0
        for text in texts {
            let characters = Array(text)
            var queries = fixed
            for _ in 0..<30 where !characters.isEmpty {
                let start = Int.random(in: 0..<characters.count, using: &rng)
                let end = min(characters.count, start + Int.random(in: 1...6, using: &rng))
                let piece = String(characters[start..<end])
                queries.append(Bool.random(using: &rng) ? piece.uppercased() : piece)
            }
            for query in queries {
                let old = (text as NSString).range(of: query, options: [.caseInsensitive, .backwards])
                let last = OutputFind.matches(of: query, in: text).last
                let label = "\(query.debugDescription) in \(text.prefix(24).debugDescription)"
                guard let last else {
                    try Expect.equal(old.location, NSNotFound, "\(label): no match, as before")
                    continue
                }
                try Expect.true(old.location != NSNotFound, "\(label): a match, as before")
                try Expect.true(
                    last == old || NSIntersectionRange(last, old).length > 0,
                    "\(label): the last match \(last) is where the old search scrolled, \(old)")
                compared += 1
            }
        }
        try Expect.true(compared > 300, "compared widely (\(compared) queries with matches)")
    }
}
