import Foundation

/// IOS-1 at `ScreenModel.cap`: the oldest rows go a slack's worth at a time, so
/// most new rows only add to the end of the output, and the view cuts its top
/// once in that many rows rather than with each.
enum IOSOutputCapSlackTests {
    typealias Fixtures = IOSOutputFixtures

    /// Rows streamed one at a time into a model at the cap: the oldest go only
    /// when the rows pass the cap and its slack, and then down to the cap. Every
    /// row the cap alone kept is still held, in order and without a gap.
    static func rowsLeaveASlackAtATime() throws {
        let window = 30
        let rows = (0..<ScreenModel.cap).map { RemoteScreenRow(i: $0, t: "r\($0)", w: nil, s: nil) }
        var model = ScreenModel()
        model.apply(Fixtures.screen(gen: 1, first: ScreenModel.cap - window, end: ScreenModel.cap, rows: rows))
        var cuts: [Int] = []
        for end in (ScreenModel.cap + 1)...(ScreenModel.cap + 3 * ScreenModel.slack + 10) {
            let before = try Expect.notNil(model.oldestIndex, "rows before \(end)")
            let row = RemoteScreenRow(i: end - 1, t: "r\(end - 1)", w: nil, s: nil)
            model.apply(Fixtures.screen(gen: 1, first: end - window, end: end, rows: [row], palette: nil))
            let oldest = try Expect.notNil(model.oldestIndex, "rows at \(end)")
            try Expect.true(oldest <= end - ScreenModel.cap, "at \(end): row \(end - ScreenModel.cap) is still held")
            try Expect.equal(model.rows.count, end - oldest, "at \(end): the rows run without a gap")
            try Expect.true(model.rows.count <= ScreenModel.cap + ScreenModel.slack, "at \(end): at most the slack past the cap")
            if oldest != before {
                try Expect.equal(model.rows.count, ScreenModel.cap, "at \(end): the oldest go down to the cap")
                cuts.append(end)
            }
        }
        let every = ScreenModel.slack + 1
        try Expect.equal(
            Array(cuts.prefix(4)), (1...3).map { ScreenModel.cap + $0 * every },
            "the oldest went once in \(every) rows, \(cuts.count) times")
    }
}
