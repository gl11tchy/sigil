#if canImport(Sigil)
@testable import Sigil
#endif
import Foundation

extension StyledText {
    /// This output with `edit` made, as a text view that made it reads.
    func applying(_ edit: StyledEdit) -> StyledText {
        var units = Array(text.utf16)
        units.replaceSubrange(edit.range, with: Array(edit.replacement.text.utf16))
        let lower = edit.range.lowerBound
        let shift = edit.replacement.text.utf16.count - edit.range.count
        func moved(_ span: StyledSpan, _ by: Int) -> StyledSpan {
            var span = span
            span.location += by
            return span
        }
        func moved(_ panel: StyledPanel, _ by: Int) -> StyledPanel {
            var panel = panel
            panel.location += by
            return panel
        }
        let head = spans.filter { $0.length > 0 && $0.location >= 0 && $0.location + $0.length <= lower }
        let rest = spans.filter { $0.length > 0 && $0.location >= edit.range.upperBound }
        return StyledText(
            text: String(decoding: units, as: UTF16.self),
            spans: head + edit.replacement.spans.map { moved($0, lower) } + rest.map { moved($0, shift) },
            ground: edit.replacement.ground,
            panels: panels.filter { $0.location < lower } + edit.replacement.panels.map { moved($0, lower) }
                + panels.filter { $0.location >= edit.range.upperBound }.map { moved($0, shift) })
    }
}

/// IOS-1: the output view replaces only the lines that changed, and the result
/// equals a full rebuild.
enum IOSOutputEditTests {
    typealias Fixtures = IOSOutputFixtures

    /// Text compared unit by unit: `String ==` would call canonically equal texts the same.
    static func same(_ lhs: StyledText, _ rhs: StyledText) -> Bool {
        Array(lhs.text.utf16) == Array(rhs.text.utf16) && lhs.spans == rhs.spans && lhs.panels == rhs.panels
            && lhs.ground == rhs.ground
    }

    /// One random change the Mac can stream: new rows, redrawn rows, the composer
    /// coming and going, a colour change, older rows, a growing panel, a new generation.
    static func mutate(_ model: inout ScreenModel, grounded: Bool, using rng: inout Fixtures.Seeded) {
        let gen = model.gen
        let first = model.first
        let end = model.end
        switch Int.random(in: 0..<20, using: &rng) {
        case 0..<6:
            let count = Int.random(in: 1...4, using: &rng)
            let rows = (end..<(end + count)).map { Fixtures.row($0, grounded: grounded, using: &rng) }
            model.apply(Fixtures.screen(gen: gen, first: first + count, end: end + count, rows: rows, palette: nil))
        case 6..<9:
            let rows = (0..<Int.random(in: 1...3, using: &rng)).map { _ in
                Fixtures.row(Int.random(in: first..<max(end, first + 1), using: &rng), grounded: grounded, using: &rng)
            }
            model.apply(Fixtures.screen(gen: gen, first: first, end: max(end, first + 1), rows: rows, palette: nil))
        case 9, 10:
            let rows = Fixtures.footerRows(from: end)
            model.apply(Fixtures.screen(gen: gen, first: first, end: end + rows.count, rows: rows, palette: nil))
        case 11, 12:
            // The screen shrank: the composer or the last rows are gone.
            guard end - first > 2 else { return }
            let cut = Int.random(in: 1...min(Fixtures.footer.count, end - first - 1), using: &rng)
            model.apply(Fixtures.screen(gen: gen, first: first, end: end - cut, rows: [], palette: nil))
        case 13, 14:
            // Same text, new colours.
            let index = Int.random(in: first..<max(end, first + 1), using: &rng)
            guard let line = model.rows[index], !line.text.isEmpty else { return }
            let runs = [[0, line.text.count, [1, 2, 9][Int.random(in: 0..<3, using: &rng)], grounded ? Fixtures.ground : -1, 0]]
            let row = RemoteScreenRow(i: index, t: line.text, w: line.wrapped ? true : nil, s: runs)
            model.apply(Fixtures.screen(gen: gen, first: first, end: end, rows: [row], palette: nil))
        case 15, 16:
            guard let oldest = model.oldestIndex, oldest > 0 else { return }
            let from = max(0, oldest - Int.random(in: 1...12, using: &rng))
            let rows = (from..<oldest).map { Fixtures.row($0, grounded: grounded, using: &rng) }
            model.prepend(Fixtures.screen(gen: gen, first: first, end: end, rows: rows, palette: nil))
        case 17, 18:
            // A panel grows by a line, or a soft wrap continues the last row.
            let kind = [1, 3][Int.random(in: 0..<2, using: &rng)]
            let row = Fixtures.row(end, grounded: grounded, kind: kind, using: &rng)
            model.apply(Fixtures.screen(gen: gen, first: first, end: end + 1, rows: [row], palette: nil))
        default:
            let count = Int.random(in: 5...40, using: &rng)
            let rows = (0..<count).map { Fixtures.row($0, grounded: grounded, using: &rng) }
            model.apply(Fixtures.screen(gen: gen + 1, first: 0, end: count, rows: rows))
        }
    }

    /// Over random row diffs in both modes, the edit made on the old output gives
    /// exactly the new one; only a changed ground makes a full rebuild.
    static func editEqualsFullRebuildOverRandomDiffs() throws {
        let formatter = try Fixtures.formatter()
        var edits = 0
        var rebuilds = 0
        var replaced = 0
        var total = 0
        for seed in 0..<40 {
            var rng = Fixtures.Seeded(state: UInt64(seed) &* 7919)
            let grounded = seed % 3 != 2
            var model = Fixtures.model(
                count: Int.random(in: 20...90, using: &rng), grounded: grounded, footer: seed % 2 == 0, from: 500,
                using: &rng)
            var shown = [false, true].map { OutputSnapshot(screen: model, history: nil, raw: $0).render(with: formatter) }
            for step in 0..<30 {
                // Now and then the other ground, so a program switching screens is covered.
                mutate(&model, grounded: step % 13 == 12 ? !grounded : grounded, using: &rng)
                for (mode, raw) in [false, true].enumerated() {
                    let next = OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter)
                    let old = shown[mode]
                    shown[mode] = next
                    guard let edit = old.edit(to: next) else {
                        rebuilds += 1
                        try Expect.true(old.ground != next.ground, "seed \(seed) step \(step) raw \(raw): rebuilt though the ground held")
                        continue
                    }
                    edits += 1
                    replaced += edit.range.count + edit.replacement.text.utf16.count
                    total += old.text.utf16.count + next.text.utf16.count
                    let made = old.applying(edit)
                    if !same(made, next) {
                        throw TestFailure(
                            "seed \(seed) step \(step) raw \(raw): edit \(edit.range) differs from a full rebuild\n"
                                + "made: \(made)\nfull: \(next)")
                    }
                }
            }
        }
        try Expect.true(edits > rebuilds * 10, "most refreshes are edits (\(edits) edits, \(rebuilds) rebuilds)")
        try Expect.true(replaced * 3 < total, "edits replace a small part (\(replaced) of \(total) units)")
    }

    /// Text-only output from a Mac that answers polls: the same holds.
    static func textOnlyEditEqualsFullRebuild() throws {
        let formatter = try Fixtures.formatter()
        var rng = Fixtures.Seeded(state: 99)
        var history = TerminalHistory()
        var lines = (0..<40).map { _ in Fixtures.text(using: &rng) }
        var shown = StyledText.empty
        for step in 0..<60 {
            if step % 5 == 4 {
                lines += Fixtures.footer
            } else if let last = lines.last, Fixtures.footer.contains(last) {
                lines.removeLast(Fixtures.footer.count)
            }
            lines.append(Fixtures.text(using: &rng))
            history.apply(lines.suffix(30).joined(separator: "\n"))
            for raw in [false, true] {
                let next = OutputSnapshot(screen: nil, history: history, raw: raw).render(with: formatter)
                if raw {
                    let edit = try Expect.notNil(shown.edit(to: next), "step \(step): text-only output always edits")
                    try Expect.true(same(shown.applying(edit), next), "step \(step): edit equals the rebuild")
                    shown = next
                } else {
                    let base = OutputSnapshot(screen: nil, history: history, raw: true).render(with: formatter)
                    let edit = try Expect.notNil(base.edit(to: next), "step \(step): raw to readable edits")
                    try Expect.true(same(base.applying(edit), next), "step \(step): raw to readable equals the rebuild")
                }
            }
        }
    }

    /// Only the lines that changed are replaced: a streamed line, a recoloured line,
    /// a panel line whose run grew, older rows above, multi-byte text before.
    static func editTouchesOnlyChangedLines() throws {
        let base = (0..<200).map { index -> RemoteScreenRow in
            let text = index == 3 ? "  👩‍👩‍👧 é 🇸🇪 日本語 wide" : "  line \(index) text"
            return RemoteScreenRow(i: 1000 + index, t: text, w: nil, s: [[2, 4, 2, -1, 0]])
        }
        var model = ScreenModel()
        model.apply(Fixtures.screen(gen: 1, first: 1000, end: 1200, rows: base))
        let old = StyledOutput.raw(model.lines)
        let lastLine = (old.text as NSString).range(of: "\n", options: .backwards).location + 1

        var appended = model
        appended.apply(Fixtures.screen(
            gen: 1, first: 1001, end: 1201, rows: [RemoteScreenRow(i: 1200, t: "  new 😀", w: nil, s: nil)], palette: nil))
        let streamed = try Expect.notNil(old.edit(to: StyledOutput.raw(appended.lines)), "append edits")
        try Expect.equal(streamed.range, lastLine..<old.text.utf16.count, "only the last line is redone")
        try Expect.equal(streamed.replacement.text, "  line 199 text\n  new 😀", "then the new line")

        var recoloured = model
        recoloured.apply(Fixtures.screen(
            gen: 1, first: 1000, end: 1200, rows: [RemoteScreenRow(i: 1100, t: "  line 100 text", w: nil, s: [[2, 4, 9, -1, 1]])],
            palette: nil))
        let colour = try Expect.notNil(old.edit(to: StyledOutput.raw(recoloured.lines)), "recolour edits")
        try Expect.equal(colour.replacement.text, "  line 100 text\n", "one line, same text")
        try Expect.equal(colour.replacement.spans, [StyledSpan(location: 2, length: 4, fg: 9, bg: -1, flags: 1)], "new colour")

        var older = model
        older.prepend(Fixtures.screen(gen: 1, first: 1000, end: 1200, rows: [RemoteScreenRow(i: 999, t: "older", w: nil, s: nil)]))
        let above = try Expect.notNil(old.edit(to: StyledOutput.raw(older.lines)), "older rows edit")
        try Expect.equal(above.range, 0..<0, "nothing old is redone")
        try Expect.equal(above.replacement.text, "older\n", "the older line goes in above")

        // A panel line's run grows: the old last line loses its bottom end, so it is redone too.
        let panel = Fixtures.panelColors[0]
        func panelRow(_ index: Int, _ text: String) -> RemoteScreenRow {
            RemoteScreenRow(
                i: index, t: text + String(repeating: " ", count: 38 - text.count), w: nil, s: [[0, 38, 7, panel, 0]])
        }
        var panels = ScreenModel()
        panels.apply(Fixtures.screen(gen: 1, first: 0, end: 2, rows: [
            RemoteScreenRow(i: 0, t: "  header", w: nil, s: nil), panelRow(1, "  ❯ ask"),
        ]))
        let one = StyledOutput.raw(panels.lines)
        panels.apply(Fixtures.screen(gen: 1, first: 0, end: 3, rows: [panelRow(2, "    more")], palette: nil))
        let two = StyledOutput.raw(panels.lines)
        try Expect.equal(two.panels.map(\.bottom), [false, true], "the run's end moved")
        let grown = try Expect.notNil(one.edit(to: two), "panel growth edits")
        try Expect.equal(grown.range.lowerBound, "  header\n".utf16.count, "the old panel line is redone for its end")
        try Expect.true(same(one.applying(grown), two), "and equals the rebuild")

        let screenSwitch = StyledText(text: old.text, spans: old.spans, ground: 7, panels: [])
        try Expect.true(old.edit(to: screenSwitch) == nil, "a new ground rebuilds")
        let unchanged = try Expect.notNil(old.edit(to: old), "no change")
        try Expect.true(unchanged.isEmpty, "no change is an empty edit")
    }
}
