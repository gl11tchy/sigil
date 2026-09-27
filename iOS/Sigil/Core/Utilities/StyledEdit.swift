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
    /// The smallest run of whole lines to replace so this output reads as `new`.
    /// Every span and panel outside it is the same in both, so styling the new
    /// lines alone gives what styling all of `new` would. Nil when no such run
    /// exists, for example when the ground changed; then style all of `new`.
    func edit(to new: StyledText) -> StyledEdit? {
        guard ground == new.ground else { return nil }
        let old = Array(text.utf16)
        let next = Array(new.text.utf16)
        if old == next, spans == new.spans, panels == new.panels {
            return StyledEdit(range: old.count..<old.count, replacement: StyledText(text: "", spans: [], ground: ground))
        }
        let shorter = min(old.count, next.count)
        var same = 0
        while same < shorter, old[same] == next[same] { same += 1 }
        var start = Self.lineStart(old, atOrBefore: same)

        // A line whose text stayed but whose colours or panel ends changed goes in the edit too.
        // Spans and panels come in line order, so the first that differ mark the first line to redo.
        let oldSpans = spans.filter { Self.isValid($0, in: old.count) }
        let newSpans = new.spans.filter { Self.isValid($0, in: next.count) }
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
        while index < min(panels.count, new.panels.count), panels[index] == new.panels[index],
            panels[index].location < start
        {
            index += 1
        }
        if index < panels.count { cut = min(cut, panels[index].location) }
        if index < new.panels.count { cut = min(cut, new.panels[index].location) }
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
        while index < min(panels.count, new.panels.count) {
            let before = panels[panels.count - 1 - index]
            let after = new.panels[new.panels.count - 1 - index]
            let offset = before.location - (old.count - tail)
            var moved = before
            moved.location = after.location
            guard offset >= 0, offset == after.location - (next.count - tail), moved == after else { break }
            index += 1
        }
        if index < panels.count { tail = min(tail, old.count - panels[panels.count - 1 - index].location - 1) }
        if index < new.panels.count { tail = min(tail, next.count - new.panels[new.panels.count - 1 - index].location - 1) }
        tail = max(tail, 0)
        // The kept tail starts a line in both texts.
        while tail > 0, !Self.isLineStart(old, old.count - tail) || !Self.isLineStart(next, next.count - tail) {
            tail -= 1
        }

        let oldEnd = old.count - tail
        let newEnd = next.count - tail
        guard start <= oldEnd, start <= newEnd,
            let before = Self.split(oldSpans, panels, start: start, end: oldEnd),
            let after = Self.split(newSpans, new.panels, start: start, end: newEnd),
            before.headSpans == after.headSpans, before.headPanels == after.headPanels,
            before.tailSpans.map({ Self.moved($0, by: newEnd - oldEnd) }) == after.tailSpans,
            before.tailPanels.map({ Self.moved($0, by: newEnd - oldEnd) }) == after.tailPanels
        else { return nil }
        let replacement = StyledText(
            text: String(decoding: next[start..<newEnd], as: UTF16.self),
            spans: after.bodySpans.map { Self.moved($0, by: -start) }, ground: new.ground,
            panels: after.bodyPanels.map { Self.moved($0, by: -start) })
        return StyledEdit(range: start..<oldEnd, replacement: replacement)
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
