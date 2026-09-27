import Foundation

extension StyledText {
    /// This output with `edits` made in their order, as a text view that made them reads.
    func applying(_ edits: [StyledEdit]) -> StyledText {
        edits.reduce(self) { $0.applying($1) }
    }
}

/// IOS-1 at the retention cap: each new row pushes the oldest out, so the output
/// changes at its top and its end at once. Only those lines are replaced, and the
/// result equals a full rebuild.
enum IOSOutputCapTests {
    typealias Fixtures = IOSOutputFixtures

    /// The edits are ordered last first and never overlap, so each range still
    /// holds when its turn comes.
    private static func checkOrder(_ edits: [StyledEdit], _ label: String) throws {
        for (later, earlier) in zip(edits, edits.dropFirst()) {
            try Expect.true(earlier.range.upperBound <= later.range.lowerBound, "\(label): edits run last first")
        }
    }

    /// Streams rows into a model already at `ScreenModel.cap`, in both modes: the
    /// edits give exactly the new output and replace a few lines, not the history.
    static func screenAtCapEditsOnlyTheEnds() throws {
        let formatter = try Fixtures.formatter()
        var rng = Fixtures.Seeded(state: 4_000)
        var model = Fixtures.model(count: ScreenModel.cap, grounded: true, footer: false, from: 10_000, using: &rng)
        try Expect.equal(model.rows.count, ScreenModel.cap, "the model is at its cap")
        var shown = [false, true].map { OutputSnapshot(screen: model, history: nil, raw: $0).render(with: formatter) }
        var cut = 0
        for step in 0..<10 {
            let first = model.first
            let end = model.end
            let count = [1, 1, 1, 2, 3][step % 5]
            if step % 4 == 3 {
                // The last row is redrawn as a new one arrives.
                let rows = [Fixtures.row(end - 1, grounded: true, kind: 4, using: &rng),
                    Fixtures.row(end, grounded: true, kind: 4, using: &rng)]
                model.apply(Fixtures.screen(gen: model.gen, first: first + 1, end: end + 1, rows: rows, palette: nil))
            } else {
                let rows = (end..<(end + count)).map { Fixtures.row($0, grounded: true, using: &rng) }
                model.apply(Fixtures.screen(gen: model.gen, first: first + count, end: end + count, rows: rows, palette: nil))
            }
            try Expect.equal(model.rows.count, ScreenModel.cap, "step \(step): still at the cap")
            for (mode, raw) in [false, true].enumerated() {
                let label = "step \(step) raw \(raw)"
                let next = OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter)
                let old = shown[mode]
                shown[mode] = next
                let edits = try Expect.notNil(old.edits(to: next), "\(label): the ground held")
                try checkOrder(edits, label)
                try Expect.true(IOSOutputEditTests.same(old.applying(edits), next), "\(label): the edits equal a full rebuild")
                let replaced = edits.reduce(0) { $0 + $1.range.count + $1.replacement.text.utf16.count }
                // A row is at most 40 units; the rows that left, the rows that came, and a line either side.
                try Expect.true(
                    replaced <= (2 * count + 4) * 2 * Fixtures.width,
                    "\(label): \(replaced) of \(next.text.utf16.count) units replaced")
                if edits.contains(where: { $0.range.lowerBound == 0 && !$0.range.isEmpty }) { cut += 1 }
            }
        }
        try Expect.true(cut >= 10, "the top was cut in its own edit (\(cut) times)")
    }

    /// Text from a Mac that answers polls, at `TerminalHistory.cap`: history is cut
    /// mid-line from the front as lines stream in. The same holds in both modes.
    static func historyAtCapEditsOnlyTheEnds() throws {
        let formatter = try Fixtures.formatter()
        var rng = Fixtures.Seeded(state: 400_000)
        var lines = (0..<30).map { _ in Fixtures.text(using: &rng) }
        var history = TerminalHistory()
        history.apply(lines.joined(separator: "\n"))
        // Fill the history with older text up to its cap, a slice at a time.
        while true {
            var slice = ""
            while slice.utf8.count < 11_000 { slice += Fixtures.text(using: &rng) + "\n" }
            let room = TerminalHistory.cap - history.history.count
            guard room > 0 else { break }
            if slice.utf16.count > room {
                slice = String(decoding: Array(slice.utf16).suffix(room), as: UTF16.self)
            }
            try Expect.true(history.prepend(slice), "older text went in")
        }
        try Expect.equal(history.history.count, TerminalHistory.cap, "the history is at its cap")
        var shown = [false, true].map { OutputSnapshot(screen: nil, history: history, raw: $0).render(with: formatter) }
        var cut = 0
        for step in 0..<10 {
            lines.append(Fixtures.text(using: &rng))
            history.apply(lines.suffix(30).joined(separator: "\n"))
            for (mode, raw) in [false, true].enumerated() {
                let label = "step \(step) raw \(raw)"
                let next = OutputSnapshot(screen: nil, history: history, raw: raw).render(with: formatter)
                let old = shown[mode]
                shown[mode] = next
                let edits = try Expect.notNil(old.edits(to: next), "\(label): text-only output always edits")
                try checkOrder(edits, label)
                try Expect.true(IOSOutputEditTests.same(old.applying(edits), next), "\(label): the edits equal a full rebuild")
                let replaced = edits.reduce(0) { $0 + $1.range.count + $1.replacement.text.utf16.count }
                try Expect.true(
                    replaced <= 12 * Fixtures.width, "\(label): \(replaced) of \(next.text.utf16.count) units replaced")
                if edits.contains(where: { $0.range.lowerBound == 0 && !$0.range.isEmpty }) { cut += 1 }
            }
        }
        try Expect.true(cut >= 10, "the top was cut in its own edit (\(cut) times)")
    }

    /// Below the cap, and wherever the output lines up from its top, the edits are
    /// the one edit found before: the head is only cut when that keeps more.
    static func editsMatchTheSingleEditBelowTheCap() throws {
        let formatter = try Fixtures.formatter()
        var single = 0
        for seed in 0..<24 {
            var rng = Fixtures.Seeded(state: UInt64(seed) &* 6_151 &+ 11)
            let grounded = seed % 3 != 2
            var model = Fixtures.model(
                count: Int.random(in: 20...90, using: &rng), grounded: grounded, footer: seed % 2 == 0, from: 700,
                using: &rng)
            var shown = [false, true].map { OutputSnapshot(screen: model, history: nil, raw: $0).render(with: formatter) }
            for step in 0..<30 {
                IOSOutputEditTests.mutate(&model, grounded: step % 11 == 10 ? !grounded : grounded, using: &rng)
                for (mode, raw) in [false, true].enumerated() {
                    let label = "seed \(seed) step \(step) raw \(raw)"
                    let next = OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter)
                    let old = shown[mode]
                    shown[mode] = next
                    let one = old.edit(to: next)
                    guard let edits = old.edits(to: next) else {
                        try Expect.true(one == nil, "\(label): no edits only where no edit")
                        continue
                    }
                    try checkOrder(edits, label)
                    try Expect.true(IOSOutputEditTests.same(old.applying(edits), next), "\(label): the edits equal a full rebuild")
                    let edit = try Expect.notNil(one, "\(label): an edit exists")
                    let size = { (edit: StyledEdit) in edit.range.count + edit.replacement.text.utf16.count }
                    try Expect.true(
                        edits.reduce(0) { $0 + size($1) } <= size(edit), "\(label): the edits replace no more than one edit")
                    if edits == [edit] { single += 1 }
                }
            }
        }
        try Expect.true(single > 1_000, "most refreshes are the one edit (\(single))")
    }
}
