import Foundation

/// The whole lines that differ between two outputs, so a view can replace only
/// those and keep the layout of the rest.
struct StyledEdit: Equatable {
    /// The old lines to replace, in UTF-16 units of the old text.
    var range: Range<Int>
    /// The new lines in their place, with spans and panels from their own start.
    var replacement: StyledText

    var isEmpty: Bool { range.isEmpty && replacement.text.isEmpty }
}

extension StyledText {
    /// The edits that make this output read as `new`, last first: each range is in
    /// units of this output and ends before the one made ahead of it starts, so
    /// making them in order moves none. Output at its cap loses lines at the top as
    /// it gains them at the end; the top is then cut in an edit of its own, so the
    /// lines in between stay. Nil when all of `new` has to be styled.
    func edits(to new: StyledText) -> [StyledEdit]? {
        guard ground == new.ground else { return nil }
        let old = Array(text.utf16)
        let next = Array(new.text.utf16)
        if var (cut, kept) = Self.head(old, next) {
            // The first `kept` units of `new` take the place of the first `cut` of this
            // output; the rest is diffed as though that were done already.
            let oldSpans = spans.filter { Self.isValid($0, in: old.count) }
            let newSpans = new.spans.filter { Self.isValid($0, in: next.count) }
            // A line under the cut can look new with it, as the first line of a panel
            // does; such lines go in the head edit too.
            var oldSpan = oldSpans.firstIndex { $0.location >= cut } ?? oldSpans.count
            var newSpan = newSpans.firstIndex { $0.location >= kept } ?? newSpans.count
            var oldPanel = panels.firstIndex { $0.location >= cut } ?? panels.count
            var newPanel = new.panels.firstIndex { $0.location >= kept } ?? new.panels.count
            while let newline = next[kept...].firstIndex(of: 0x0A) {
                let length = newline + 1 - kept
                guard cut + length <= old.count, old[cut..<(cut + length)].elementsEqual(next[kept...newline]) else { break }
                let shift = kept - cut
                let spanEnds = (
                    oldSpans[oldSpan...].firstIndex { $0.location >= cut + length } ?? oldSpans.count,
                    newSpans[newSpan...].firstIndex { $0.location >= kept + length } ?? newSpans.count
                )
                let panelEnds = (
                    panels[oldPanel...].firstIndex { $0.location >= cut + length } ?? panels.count,
                    new.panels[newPanel...].firstIndex { $0.location >= kept + length } ?? new.panels.count
                )
                if oldSpans[oldSpan..<spanEnds.0].map({ Self.moved($0, by: shift) }) == Array(newSpans[newSpan..<spanEnds.1]),
                    panels[oldPanel..<panelEnds.0].map({ Self.moved($0, by: shift) }) == Array(new.panels[newPanel..<panelEnds.1])
                {
                    break
                }
                cut += length
                kept += length
                (oldSpan, newSpan) = spanEnds
                (oldPanel, newPanel) = panelEnds
            }
            if let top = Self.split(oldSpans, panels, start: 0, end: cut),
                let lead = Self.split(newSpans, new.panels, start: 0, end: kept)
            {
                let shift = kept - cut
                let rest = Self.edit(
                    Array(next[..<kept]) + old[cut...], lead.bodySpans + top.tailSpans.map { Self.moved($0, by: shift) },
                    lead.bodyPanels + top.tailPanels.map { Self.moved($0, by: shift) },
                    to: next, new.spans, new.panels, ground: new.ground)
                if var rest, rest.range.lowerBound >= kept {
                    let head = StyledEdit(
                        range: 0..<cut,
                        replacement: StyledText(
                            text: String(decoding: next[..<kept], as: UTF16.self), spans: lead.bodySpans,
                            ground: new.ground, panels: lead.bodyPanels))
                    rest.range = (rest.range.lowerBound - shift)..<(rest.range.upperBound - shift)
                    return rest.isEmpty ? [head] : [rest, head]
                }
            }
        }
        return Self.edit(old, spans, panels, to: next, new.spans, new.panels, ground: new.ground).map { [$0] }
    }

    /// The smallest run of whole lines to replace so this output reads as `new`.
    /// Every span and panel outside it is the same in both, so styling the new
    /// lines alone gives what styling all of `new` would. Nil when no such run
    /// exists, for example when the ground changed; then style all of `new`.
    func edit(to new: StyledText) -> StyledEdit? {
        guard ground == new.ground else { return nil }
        return Self.edit(
            Array(text.utf16), spans, panels, to: Array(new.text.utf16), new.spans, new.panels, ground: new.ground)
    }

    private static func edit(
        _ old: [UInt16], _ spans: [StyledSpan], _ panels: [StyledPanel], to next: [UInt16], _ nextSpans: [StyledSpan],
        _ nextPanels: [StyledPanel], ground: Int
    ) -> StyledEdit? {
        if old == next, spans == nextSpans, panels == nextPanels {
            return StyledEdit(range: old.count..<old.count, replacement: StyledText(text: "", spans: [], ground: ground))
        }
        let shorter = min(old.count, next.count)
        var same = 0
        while same < shorter, old[same] == next[same] { same += 1 }
        var start = Self.lineStart(old, atOrBefore: same)

        // A line whose text stayed but whose colours or panel ends changed goes in the edit too.
        // Spans and panels come in line order, so the first that differ mark the first line to redo.
        let oldSpans = spans.filter { Self.isValid($0, in: old.count) }
        let newSpans = nextSpans.filter { Self.isValid($0, in: next.count) }
        var cut = start
        var index = 0
        while index < min(oldSpans.count, newSpans.count), oldSpans[index] == newSpans[index],
            oldSpans[index].location + oldSpans[index].length <= start
        {
            index += 1
        }
        if index < oldSpans.count { cut = min(cut, oldSpans[index].location) }
        if index < newSpans.count { cut = min(cut, newSpans[index].location) }
        index = 0
        while index < min(panels.count, nextPanels.count), panels[index] == nextPanels[index],
            panels[index].location < start
        {
            index += 1
        }
        if index < panels.count { cut = min(cut, panels[index].location) }
        if index < nextPanels.count { cut = min(cut, nextPanels[index].location) }
        start = Self.lineStart(old, atOrBefore: max(cut, 0))

        // The same from the end. The kept tail may take back text the head gave up.
        var tail = 0
        while tail < shorter - start, old[old.count - 1 - tail] == next[next.count - 1 - tail] { tail += 1 }
        index = 0
        while index < min(oldSpans.count, newSpans.count) {
            let before = oldSpans[oldSpans.count - 1 - index]
            let after = newSpans[newSpans.count - 1 - index]
            let offset = before.location - (old.count - tail)
            guard offset >= 0, offset == after.location - (next.count - tail), before.length == after.length,
                before.fg == after.fg, before.bg == after.bg, before.flags == after.flags
            else { break }
            index += 1
        }
        if index < oldSpans.count {
            let span = oldSpans[oldSpans.count - 1 - index]
            tail = min(tail, old.count - span.location - span.length)
        }
        if index < newSpans.count {
            let span = newSpans[newSpans.count - 1 - index]
            tail = min(tail, next.count - span.location - span.length)
        }
        index = 0
        while index < min(panels.count, nextPanels.count) {
            let before = panels[panels.count - 1 - index]
            let after = nextPanels[nextPanels.count - 1 - index]
            let offset = before.location - (old.count - tail)
            var moved = before
            moved.location = after.location
            guard offset >= 0, offset == after.location - (next.count - tail), moved == after else { break }
            index += 1
        }
        if index < panels.count { tail = min(tail, old.count - panels[panels.count - 1 - index].location - 1) }
        if index < nextPanels.count { tail = min(tail, next.count - nextPanels[nextPanels.count - 1 - index].location - 1) }
        tail = max(tail, 0)
        // The kept tail starts a line in both texts.
        while tail > 0, !Self.isLineStart(old, old.count - tail) || !Self.isLineStart(next, next.count - tail) {
            tail -= 1
        }

        let oldEnd = old.count - tail
        let newEnd = next.count - tail
        guard start <= oldEnd, start <= newEnd,
            let before = Self.split(oldSpans, panels, start: start, end: oldEnd),
            let after = Self.split(newSpans, nextPanels, start: start, end: newEnd),
            before.headSpans == after.headSpans, before.headPanels == after.headPanels,
            before.tailSpans.map({ Self.moved($0, by: newEnd - oldEnd) }) == after.tailSpans,
            before.tailPanels.map({ Self.moved($0, by: newEnd - oldEnd) }) == after.tailPanels
        else { return nil }
        let replacement = StyledText(
            text: String(decoding: next[start..<newEnd], as: UTF16.self),
            spans: after.bodySpans.map { Self.moved($0, by: -start) }, ground: ground,
            panels: after.bodyPanels.map { Self.moved($0, by: -start) })
        return StyledEdit(range: start..<oldEnd, replacement: replacement)
    }

    /// Where `next` lines up with `old` once lines at the top of `old` are cut: the
    /// old units to replace, whole lines, and the units of `next` in their place,
    /// its first line or none. Nil when lining up from the top keeps as much, as it
    /// does below the cap.
    private static func head(_ old: [UInt16], _ next: [UInt16]) -> (cut: Int, kept: Int)? {
        guard let newline = next.firstIndex(of: 0x0A) else { return nil }
        let kept = newline + 1
        let shorter = min(old.count, next.count)
        var same = 0
        while same < shorter, old[same] == next[same] { same += 1 }
        var tail = 0
        while tail < shorter, old[old.count - 1 - tail] == next[next.count - 1 - tail] { tail += 1 }
        // The units that stay lined up from the top; a cut has to keep more.
        var best = same + min(tail, shorter - same)
        var found: Int?
        // Units compared, so output of one repeated line cannot make this quadratic.
        var budget = old.count + next.count
        var index = 0
        while index < old.count, budget > 0 {
            guard old[index] == 0x0A else {
                index += 1
                continue
            }
            let cut = index + 1
            index = cut
            // A later cut keeps no more than what follows it.
            let limit = min(old.count - cut, next.count - kept)
            guard limit > best else { break }
            var run = 0
            while run < limit, old[cut + run] == next[kept + run] { run += 1 }
            budget -= run + 1
            let keeps = run + min(tail, limit - run)
            if keeps > best {
                best = keeps
                found = cut
            }
        }
        guard let cut = found else { return nil }
        // The first line of `next` as it was, a whole line: cut above it and keep it.
        if cut >= kept, isLineStart(old, cut - kept), old[(cut - kept)..<cut].elementsEqual(next[..<kept]) {
            return (cut - kept, 0)
        }
        return (cut, kept)
    }

    private struct Parts {
        var headSpans: [StyledSpan] = []
        var bodySpans: [StyledSpan] = []
        var tailSpans: [StyledSpan] = []
        var headPanels: [StyledPanel] = []
        var bodyPanels: [StyledPanel] = []
        var tailPanels: [StyledPanel] = []
    }

    /// Spans and panels before, inside and after `start..<end`; nil when a span
    /// crosses either end or the panels are out of order.
    private static func split(_ spans: [StyledSpan], _ panels: [StyledPanel], start: Int, end: Int) -> Parts? {
        var parts = Parts()
        for span in spans {
            let stop = span.location + span.length
            if stop <= start {
                parts.headSpans.append(span)
            } else if span.location >= end {
                parts.tailSpans.append(span)
            } else if span.location >= start, stop <= end {
                parts.bodySpans.append(span)
            } else {
                return nil
            }
        }
        for (index, panel) in panels.enumerated() {
            if index > 0, panels[index - 1].location > panel.location { return nil }
            if panel.location < start {
                parts.headPanels.append(panel)
            } else if panel.location >= end {
                parts.tailPanels.append(panel)
            } else {
                parts.bodyPanels.append(panel)
            }
        }
        return parts
    }

    /// The spans the view draws: the others it skips, wherever they sit.
    private static func isValid(_ span: StyledSpan, in length: Int) -> Bool {
        span.location >= 0 && span.length > 0 && span.location + span.length <= length
    }

    private static func isLineStart(_ units: [UInt16], _ index: Int) -> Bool {
        index == 0 || units[index - 1] == 0x0A
    }

    private static func lineStart(_ units: [UInt16], atOrBefore index: Int) -> Int {
        var index = min(index, units.count)
        while !isLineStart(units, index) { index -= 1 }
        return index
    }

    private static func moved(_ span: StyledSpan, by shift: Int) -> StyledSpan {
        var span = span
        span.location += shift
        return span
    }

    private static func moved(_ panel: StyledPanel, by shift: Int) -> StyledPanel {
        var panel = panel
        panel.location += shift
        return panel
    }
}
