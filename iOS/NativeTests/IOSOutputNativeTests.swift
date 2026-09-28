import SwiftUI
import UIKit

/// IOS-1 and IOS-2 on UIKit and TextKit 2 themselves: streamed rows go through
/// the real `OutputView` in a window, and what its text view holds is checked
/// against a text view given all of the output at once. `scripts/native-output-test.sh`
/// builds this and runs it on a simulator made for the run.
@main
struct IOSOutputNativeTestApp: App {
    @StateObject private var output = NativeOutput()

    var body: some Scene {
        WindowGroup {
            OutputView(
                styled: output.styled, palette: IOSOutputFixtures.palette, foreground: IOSOutputNativeTests.foreground,
                background: IOSOutputNativeTests.background, revision: output.revision, highlight: output.highlight,
                onNearTop: {}, atBottom: .constant(true), scrollToEnd: 0
            )
            .task { await IOSOutputNativeTests.runAll(output) }
        }
    }
}

/// What the session screen hands the output view.
@MainActor
final class NativeOutput: ObservableObject {
    @Published var styled = StyledText.empty
    @Published var revision = 0
    @Published var highlight = ""
}

@MainActor
enum IOSOutputNativeTests {
    typealias Fixtures = IOSOutputFixtures

    static let foreground = "e0e0e0"
    static let background = "101010"

    static func runAll(_ output: NativeOutput) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        // A hung run fails rather than waits for ever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) {
            print("FAIL timed out")
            exit(2)
        }
        var failed = 0
        var passed = 0
        func run(_ name: String, _ test: () async throws -> Void) async {
            do {
                try await test()
                passed += 1
                print("PASS \(name)")
            } catch {
                failed += 1
                print("FAIL \(name): \(error)")
            }
        }
        do {
            let shown = try await Shown(output)
            await run("show equals a full rebuild over random diffs") { try await showEqualsFullRebuild(shown) }
            await run("show at the screen cap edits only the ends") { try await showAtCapEditsOnlyTheEnds(shown) }
            await run("show past the screen cap keeps the end in view") { try await showPastCapKeepsTheEnd(shown) }
            await run("show past the screen cap lays out only the end") { try showPastCapLaysOutOnlyTheEnd(shown) }
            await run("find marks leave the text as it was") { try await findLeavesTheText(shown) }
            await run("find scrolls once the search lands") { try await findScrollsOnceTheSearchLands(shown) }
            await run("a dropped composer keeps the cover") { try await aDroppedComposerKeepsTheCover() }
        } catch {
            failed += 1
            print("FAIL setup: \(error)")
        }
        print(failed == 0 ? "OK \(passed)" : "FAILED \(failed)")
        exit(failed == 0 ? 0 : 1)
    }

    /// The output view in the window, driven the way the session screen drives it.
    @MainActor
    final class Shown {
        let output: NativeOutput
        let view: OutputTextView
        let coordinator: OutputView.Coordinator
        /// Given each output whole, as the view is when it cannot edit.
        let reference = OutputTextView(usingTextLayoutManager: true)
        let formatter = ReadableOutput.bundled()
        /// The ranges the view's text storage processed since the last show.
        private(set) var processed: [NSRange] = []
        private var observer: NSObjectProtocol?

        init(_ output: NativeOutput) async throws {
            self.output = output
            var found: OutputTextView?
            for _ in 0..<500 where found == nil {
                found = UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }
                    .compactMap { Self.textView(in: $0) }.first
                if found == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            view = try Expect.notNil(found, "the output view is in the window")
            coordinator = try Expect.notNil(view.delegate as? OutputView.Coordinator, "the view has its coordinator")
            try Expect.true(formatter.isAvailable, "script loaded")
            try Expect.true(view.textLayoutManager != nil, "the view uses TextKit 2")
            observer = NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: view.textStorage, queue: nil
            ) { [weak self] note in
                guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
                MainActor.assumeIsolated { self?.processed.append(storage.editedRange) }
            }
        }

        private static func textView(in view: UIView) -> OutputTextView? {
            view as? OutputTextView ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
        }

        func render(_ model: ScreenModel, raw: Bool) -> StyledText {
            OutputSnapshot(screen: model, history: nil, raw: raw).render(with: formatter)
        }

        /// Hands the view `styled` as a new revision and waits until it shows it.
        func show(_ styled: StyledText) async throws {
            processed = []
            output.styled = styled
            output.revision += 1
            try await until("revision \(output.revision) shows") { self.coordinator.revision == self.output.revision }
        }

        func search(_ query: String) async throws {
            output.highlight = query
            try await until("the query \"\(query)\" reaches the view") { self.coordinator.highlight == query }
        }

        /// Fails with where the view's text first differs from `styled` styled whole,
        /// or where one of its laid-out lines sits apart from that line's place there.
        func check(_ styled: StyledText, _ label: String) throws {
            reference.attributedText = OutputView.attributed(
                styled, palette: Fixtures.palette, foreground: IOSOutputNativeTests.foreground,
                background: IOSOutputNativeTests.background)
            if let difference = IOSOutputNativeTests.difference(view.textStorage, reference.textStorage) {
                throw TestFailure("\(label): the view differs from a full rebuild: \(difference)")
            }
            try checkLayout(label)
        }

        /// Compares the lines the view lays out where it is, then for each screen
        /// from the top down as a reader who jumps back up sees them, with the
        /// same lines laid out whole: each has the same size, and sits as far from
        /// the screen's first line as it does there. TextKit 2 places only a screen's
        /// lines; one off screen may keep an old place until it scrolls in, and a
        /// screen may sit on an estimate of the lines above. The view goes back
        /// to where it was.
        private func checkLayout(_ label: String) throws {
            reference.bounds.size = view.bounds.size
            reference.textContainerInset = view.textContainerInset
            reference.textContainer.lineFragmentPadding = view.textContainer.lineFragmentPadding
            reference.textLayoutManager?.delegate = coordinator
            reference.layoutIfNeeded()
            view.layoutIfNeeded()
            try Expect.equal(
                reference.textContainer.size.width, view.textContainer.size.width, "\(label): both views wrap alike")
            let whole = Dictionary(uniqueKeysWithValues: IOSOutputNativeTests.frames(reference, all: true))
            let was = view.contentOffset
            let atBottom = coordinator.isAtBottom(view)
            defer {
                if atBottom {
                    coordinator.scrollToBottom(view)
                } else {
                    view.setContentOffset(was, animated: false)
                    view.layoutIfNeeded()
                }
            }
            var y = was.y
            var jumped = false
            while true {
                let shown = IOSOutputNativeTests.frames(view, all: false)
                guard let (start, first) = shown.first, let firstWhole = whole[start], shown.count > 1 else {
                    throw TestFailure("\(label): the view laid out \(shown.count) lines at \(y)")
                }
                for (at, frame) in shown {
                    guard let other = whole[at] else { throw TestFailure("\(label): no whole line starts at unit \(at)") }
                    let apart = [
                        frame.minX - other.minX, frame.minY - first.minY - (other.minY - firstWhole.minY),
                        frame.width - other.width, frame.height - other.height,
                    ]
                    guard apart.allSatisfy({ abs($0) < 0.5 }) else {
                        throw TestFailure(
                            "\(label): at \(y) the line at unit \(at) is at \(frame) below \(first), not at \(other) below \(firstWhole)"
                        )
                    }
                }
                let end = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
                guard !jumped || y < end else { return }
                y = jumped ? min(end, y + view.bounds.height / 2) : -view.adjustedContentInset.top
                jumped = true
                view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                view.layoutIfNeeded()
            }
        }

        /// The find marks TextKit draws over the text, in units.
        var marks: [NSRange] {
            guard let manager = view.textLayoutManager, let content = manager.textContentManager else { return [] }
            let origin = content.documentRange.location
            var result: [NSRange] = []
            manager.enumerateRenderingAttributes(from: origin, reverse: false) { _, attributes, range in
                if attributes[.backgroundColor] != nil {
                    let start = content.offset(from: origin, to: range.location)
                    result.append(NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation)))
                }
                return true
            }
            return result
        }

        func until(_ what: String, _ done: () -> Bool) async throws {
            for _ in 0..<1_000 {
                if done() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw TestFailure("timed out waiting until \(what)")
        }
    }

    /// Each layout fragment's first unit and frame, first to last: of all of the
    /// text laid out, or of the fragments the view laid out for what it shows.
    static func frames(_ view: UITextView, all: Bool) -> [(Int, CGRect)] {
        guard let manager = view.textLayoutManager, let content = manager.textContentManager,
            let range = all ? manager.documentRange : manager.textViewportLayoutController.viewportRange
        else { return [] }
        if all { manager.ensureLayout(for: range) }
        let origin = content.documentRange.location
        var result: [(Int, CGRect)] = []
        manager.enumerateTextLayoutFragments(from: range.location, options: all ? [.ensuresLayout] : []) { fragment in
            let start = fragment.rangeInElement.location
            guard all || start.compare(range.endLocation) == .orderedAscending else { return false }
            result.append((content.offset(from: origin, to: start), fragment.layoutFragmentFrame))
            return true
        }
        return result
    }

    /// Where two text storages first differ, in text or in any attribute, or nil.
    /// A panel is compared by what it draws, as two stylings make two of them.
    static func difference(_ lhs: NSAttributedString, _ rhs: NSAttributedString) -> String? {
        guard (lhs.string as NSString).isEqual(to: rhs.string) else {
            let left = Array(lhs.string.utf16)
            let right = Array(rhs.string.utf16)
            let at = (0..<min(left.count, right.count)).first { left[$0] != right[$0] } ?? min(left.count, right.count)
            return "text at unit \(at) (\(left.count) and \(right.count) units)"
        }
        var index = 0
        while index < lhs.length {
            var left = NSRange()
            var right = NSRange()
            let a = lhs.attributes(at: index, effectiveRange: &left)
            let b = rhs.attributes(at: index, effectiveRange: &right)
            let same = a.count == b.count && a.allSatisfy { key, value in
                guard let other = b[key] else { return false }
                if let panel = value as? OutputPanel, let otherPanel = other as? OutputPanel {
                    return panel.color == otherPanel.color && panel.top == otherPanel.top && panel.bottom == otherPanel.bottom
                }
                return (value as AnyObject).isEqual(other)
            }
            if !same { return "attributes at unit \(index): \(a) and \(b)" }
            index = min(NSMaxRange(left), NSMaxRange(right))
        }
        return nil
    }

    /// Random row diffs in both modes, through the view: after each, its text
    /// storage equals one given the whole output.
    static func showEqualsFullRebuild(_ shown: Shown) async throws {
        for seed in 0..<8 {
            for raw in [false, true] {
                var rng = Fixtures.Seeded(state: UInt64(seed) &* 7919)
                let grounded = seed % 3 != 2
                var model = Fixtures.model(
                    count: Int.random(in: 20...90, using: &rng), grounded: grounded, footer: seed % 2 == 0, from: 500,
                    using: &rng)
                try await shown.show(shown.render(model, raw: raw))
                for step in 0..<30 {
                    IOSOutputEditTests.mutate(&model, grounded: step % 13 == 12 ? !grounded : grounded, using: &rng)
                    let next = shown.render(model, raw: raw)
                    try await shown.show(next)
                    try shown.check(next, "seed \(seed) step \(step) raw \(raw)")
                }
            }
        }
    }

    /// Rows streamed into output at `ScreenModel.cap`: the view equals a full
    /// rebuild, and its text storage processes a few lines, not all 4,000.
    static func showAtCapEditsOnlyTheEnds(_ shown: Shown) async throws {
        for raw in [false, true] {
            var rng = Fixtures.Seeded(state: 4_000)
            var model = Fixtures.model(count: ScreenModel.cap, grounded: true, footer: false, from: 10_000, using: &rng)
            var styled = shown.render(model, raw: raw)
            try await shown.show(styled)
            try shown.check(styled, "raw \(raw) at the cap")
            for step in 0..<8 {
                let count = [1, 1, 2, 3][step % 4]
                let rows = (model.end..<(model.end + count)).map { Fixtures.row($0, grounded: true, using: &rng) }
                model.apply(Fixtures.screen(gen: model.gen, first: model.first + count, end: model.end + count, rows: rows, palette: nil))
                styled = shown.render(model, raw: raw)
                try await shown.show(styled)
                let label = "raw \(raw) step \(step)"
                try shown.check(styled, label)
                let processed = shown.processed.reduce(0) { $0 + $1.length }
                try Expect.true(
                    processed <= (2 * count + 4) * Fixtures.width,
                    "\(label): the text storage processed \(processed) of \(styled.text.utf16.count) units")
            }
        }
    }

    /// Find marks over the text: they land on the matches, move with streamed
    /// lines, and once the query is cleared none is left and the text is as it was.
    static func findLeavesTheText(_ shown: Shown) async throws {
        var rng = Fixtures.Seeded(state: 77)
        var model = Fixtures.model(count: 400, grounded: true, footer: true, from: 0, using: &rng)
        var styled = shown.render(model, raw: false)
        try await shown.show(styled)
        try shown.check(styled, "before find")
        try Expect.true(shown.marks.isEmpty, "no marks before find")
        let query = "ok"
        func checkMarks(_ label: String) throws {
            let text = shown.view.textStorage.string as NSString
            for mark in shown.marks {
                let marked = text.substring(with: mark).lowercased()
                try Expect.true(
                    mark.length > 0 && mark.length % query.utf16.count == 0
                        && marked == String(repeating: query, count: mark.length / query.utf16.count),
                    "\(label): a mark at \(mark) covers \"\(marked)\"")
            }
        }
        try await shown.search(query)
        try await shown.until("the marks land") { !shown.marks.isEmpty }
        try shown.check(styled, "with marks")
        try checkMarks("with marks")
        for step in 0..<6 {
            IOSOutputEditTests.mutate(&model, grounded: true, using: &rng)
            styled = shown.render(model, raw: false)
            try await shown.show(styled)
            try shown.check(styled, "step \(step) with marks")
            try checkMarks("step \(step)")
        }
        try await shown.until("the marks land again") { !shown.marks.isEmpty }
        try await shown.search("")
        try shown.check(styled, "find closed")
        try Expect.true(shown.marks.isEmpty, "no mark is left once find closes (\(shown.marks.count) left)")
    }
}
