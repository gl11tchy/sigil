import SwiftUI
import UIKit

extension IOSOutputNativeTests {
    /// Rows streamed one at a time into output past `ScreenModel.cap`: only the
    /// row that passes the slack cuts the top, and after that cut the view still
    /// shows the end, laid out as a full rebuild lays it out.
    static func showPastCapKeepsTheEnd(_ shown: Shown) async throws {
        var rng = Fixtures.Seeded(state: 4_256)
        var model = Fixtures.model(
            count: ScreenModel.cap + ScreenModel.slack - 4, grounded: true, footer: false, from: 10_000, using: &rng)
        var styled = shown.render(model, raw: false)
        try await shown.show(styled)
        try shown.check(styled, "start")
        var cuts = 0
        for step in 0..<8 {
            let oldest = model.oldestIndex
            let row = Fixtures.row(model.end, grounded: true, using: &rng)
            model.apply(Fixtures.screen(gen: model.gen, first: model.first + 1, end: model.end + 1, rows: [row], palette: nil))
            styled = shown.render(model, raw: false)
            try await shown.show(styled)
            let label = "step \(step), \(model.rows.count) rows"
            if model.oldestIndex != oldest {
                cuts += 1
                let viewport = shown.view.textLayoutManager?.textViewportLayoutController.viewportRange
                try Expect.true(viewport != nil, "\(label): the view lays out what it shows after the cut")
                try Expect.true(shown.coordinator.isAtBottom(shown.view), "\(label): the view stays at the end")
            }
            try shown.check(styled, label)
        }
        try Expect.equal(cuts, 1, "the top was cut once in 8 rows")
    }

    /// The same rows through the view's coordinator into a text view with all
    /// of its lines laid out: a row that adds to the end, and the row that cuts
    /// the top, leave the layout of the lines between the two ends.
    static func showPastCapLaysOutOnlyTheEnd(_ shown: Shown) throws {
        func output(_ styled: StyledText) -> OutputView {
            OutputView(
                styled: styled, palette: Fixtures.palette, foreground: foreground, background: background, revision: 0,
                highlight: "", onNearTop: {}, atBottom: .constant(true), scrollToEnd: 0)
        }
        var rng = Fixtures.Seeded(state: 4_256)
        var model = Fixtures.model(
            count: ScreenModel.cap + ScreenModel.slack - 4, grounded: true, footer: false, from: 10_000, using: &rng)
        let view = OutputTextView(usingTextLayoutManager: true)
        view.bounds.size = shown.view.bounds.size
        view.textContainerInset = shown.view.textContainerInset
        view.textContainer.lineFragmentPadding = shown.view.textContainer.lineFragmentPadding
        let coordinator = OutputView.Coordinator(output(.empty))
        let manager = try Expect.notNil(view.textLayoutManager, "TextKit 2")
        manager.delegate = coordinator
        coordinator.show(output(shown.render(model, raw: false)), in: view)
        var cuts = 0
        for step in 0..<8 {
            manager.ensureLayout(for: manager.documentRange)
            let oldest = model.oldestIndex
            let row = Fixtures.row(model.end, grounded: true, using: &rng)
            model.apply(Fixtures.screen(gen: model.gen, first: model.first + 1, end: model.end + 1, rows: [row], palette: nil))
            coordinator.show(output(shown.render(model, raw: false)), in: view)
            if model.oldestIndex != oldest { cuts += 1 }
            var unlaid = 0
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) {
                if $0.state != .layoutAvailable { unlaid += 1 }
                return true
            }
            try Expect.true(
                unlaid <= 4, "step \(step), \(model.rows.count) rows: \(unlaid) lines lay out again, not only the end")
        }
        try Expect.equal(cuts, 1, "the top was cut once in 8 rows")
    }
}
