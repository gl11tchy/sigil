import UIKit

extension IOSOutputNativeTests {
    /// A query shows its last match once the search off the main thread lands,
    /// where the main thread's own search used to scroll: while the search is
    /// held, the view neither scrolls nor marks, so nothing searched on the main
    /// thread. It then lands where that search scrolled to.
    static func findScrollsOnceTheSearchLands(_ shown: Shown) async throws {
        var rng = Fixtures.Seeded(state: 91)
        var model = Fixtures.model(count: 400, grounded: true, footer: false, from: 20_000, using: &rng)
        let token = "zqxj"
        let row = RemoteScreenRow(i: model.first + 3, t: "\(token) near the top", w: nil, s: nil)
        model.apply(Fixtures.screen(gen: model.gen, first: model.first, end: model.end, rows: [row], palette: nil))
        let styled = shown.render(model, raw: true)
        try await shown.show(styled)
        shown.coordinator.scrollToBottom(shown.view)
        let bottom = shown.view.contentOffset.y
        try Expect.true(bottom > shown.view.bounds.height, "the output runs past a screen")

        let held = DispatchQueue(label: "dev.sigil.native-tests.find")
        held.suspend()
        var resumed = false
        defer {
            // A suspended queue must not be released.
            if !resumed { held.resume() }
            shown.coordinator.finder = OutputFinder()
        }
        shown.coordinator.finder = OutputFinder(queue: held)
        try await shown.search(token)
        try await Task.sleep(for: .milliseconds(100))
        try Expect.equal(shown.view.contentOffset.y, bottom, "the view waits for the search before it scrolls")
        try Expect.true(shown.marks.isEmpty, "no mark lands before the search")

        held.resume()
        resumed = true
        try await shown.until("the match is marked") { !shown.marks.isEmpty }
        try await shown.until("the view scrolls to the match") { shown.view.contentOffset.y < bottom }
        let old = (styled.text as NSString).range(of: token, options: [.caseInsensitive, .backwards])
        try Expect.equal(shown.marks, [old], "the one match is marked")
        let landed = shown.view.contentOffset
        shown.view.scrollRangeToVisible(old)
        try Expect.equal(shown.view.contentOffset, landed, "the view shows what the main thread's search showed")

        try await shown.search("")
        shown.coordinator.scrollToBottom(shown.view)
    }
}
