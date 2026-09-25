import Foundation

/// One styled stretch of the output, in UTF-16 units so a text view can apply it.
struct StyledSpan: Equatable {
    var location: Int
    var length: Int
    var fg: Int
    var bg: Int
    var flags: Int

    static let bold = 1
    static let underline = 2
    static let inverse = 8
    static let dim = 32
    static let italic = 64
    static let crossedOut = 128
}

/// One output line the program painted across its width: a prompt, a code block.
struct StyledPanel: Equatable {
    /// The line in UTF-16 units, without its line break.
    var location: Int
    var length: Int
    var color: Int
    /// The ends of a run of panel lines; the view rounds and pads these.
    var top: Bool
    var bottom: Bool
}

struct StyledText: Equatable {
    var text: String
    var spans: [StyledSpan]
    /// The background the program painted under most cells, or -1. The view fills
    /// with it, so a full-screen program reads as one surface, not cell stripes.
    var ground = -1
    var panels: [StyledPanel] = []

    static let empty = StyledText(text: "", spans: [])
}

/// Rows ready for either mode: glyphs drawn in their own background blanked,
/// trailing blanks cut, and the ground and panel colours found once.
struct PreparedScreen: Equatable {
    var lines: [ScreenLine]
    var ground: Int
    /// A panel colour for each line, or -1.
    var panels: [Int]
}

/// Builds the output the session screen draws, with the terminal's colours.
enum StyledOutput {
    /// Spaces this long inside a readable line (a right-aligned status) become two.
    static let longGap = 8
    /// A wrapped line never hangs deeper than this, so it keeps room to read.
    static let maxHang = 16
    /// Characters that open a list item; a wrapped item lines up after them.
    static let markers: Set<Character> = [
        "•", "◦", "▪", "‣", "⁃", "-", "*", "+", "◆", "◇", "♦", "❯", "›", ">", "⏺", "●", "⎿", "└", "├",
        "→", "✓", "✔", "✗", "✘", "✅", "❌",
    ]

    static func prepare(_ lines: [ScreenLine]) -> PreparedScreen {
        let ground = Self.ground(of: lines)
        // Rows come trimmed, so the widest row stands in for the terminal's width.
        let width = max(lines.map(\.text.count).max() ?? 0, 40)
        var cleaned: [ScreenLine] = []
        var panels: [Int] = []
        cleaned.reserveCapacity(lines.count)
        panels.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            panels.append(Self.panel(of: line, ground: ground, width: width))
            let continued = index + 1 < lines.count && lines[index + 1].wrapped
            cleaned.append(Self.clean(line, trim: !continued))
        }
        return PreparedScreen(lines: cleaned, ground: ground, panels: panels)
    }

    /// The background painted on nearly every row and under a third of all cells, or -1.
    /// A full-width block on some rows (a user message) is a panel, not the ground.
    static func ground(of lines: [ScreenLine]) -> Int {
        var cells: [Int: Int] = [:]
        var rows: [Int: Int] = [:]
        var total = 0
        var filled = 0
        for line in lines {
            let count = line.text.count
            guard count > 0 else { continue }
            total += count
            filled += 1
            var seen: [Int] = []
            for run in line.runs where run.count == 5 && run[3] >= 0 && run[4] & StyledSpan.inverse == 0 {
                cells[run[3], default: 0] += run[1]
                if !seen.contains(run[3]) { seen.append(run[3]) }
            }
            for color in seen { rows[color, default: 0] += 1 }
        }
        guard
            let top = rows.max(by: { ($0.value, cells[$0.key] ?? 0) < ($1.value, cells[$1.key] ?? 0) }),
            top.value * 10 >= filled * 9, (cells[top.key] ?? 0) * 3 >= total
        else { return -1 }
        return top.key
    }

    /// The colour a row paints across at least half the terminal, other than the ground, or -1.
    static func panel(of line: ScreenLine, ground: Int, width: Int) -> Int {
        var cells: [Int: Int] = [:]
        for run in line.runs
        where run.count == 5 && run[3] >= 0 && run[3] != ground && run[4] & StyledSpan.inverse == 0 {
            cells[run[3], default: 0] += run[1]
        }
        guard let top = cells.max(by: { $0.value < $1.value }), top.value * 2 >= width else { return -1 }
        return top.key
    }

    /// Blanks glyphs drawn in their own background (a scrollbar thumb). Unless the
    /// next row continues this one, cuts trailing blanks and the runs under them.
    static func clean(_ line: ScreenLine, trim: Bool) -> ScreenLine {
        var line = line
        let hidden = line.runs.filter {
            $0.count == 5 && $0[2] >= 0 && $0[2] == $0[3] && $0[4] & StyledSpan.inverse == 0
        }
        if !hidden.isEmpty {
            var characters = Array(line.text)
            for run in hidden {
                let start = max(run[0], 0)
                let end = min(run[0] + run[1], characters.count)
                guard start < end else { continue }
                for index in start..<end { characters[index] = " " }
            }
            line.text = String(characters)
        }
        guard trim else { return line }
        let trimmed = Self.trimmedEnd(line.text)
        let count = trimmed.count
        guard count < line.text.count else { return line }
        line.text = trimmed
        line.runs = line.runs.compactMap { run in
            guard run.count == 5, run[0] < count else { return nil }
            var run = run
            run[1] = min(run[1], count - run[0])
            return run
        }
        return line
    }

    /// Raw mode: every row as the Mac drew it, without the blank rows under the cursor.
    static func raw(_ lines: [ScreenLine]) -> StyledText { raw(prepare(lines)) }

    static func raw(_ screen: PreparedScreen) -> StyledText {
        var rows: [Row] = []
        for (index, line) in screen.lines.enumerated() {
            let spans = Self.spans(for: line.runs, in: line.text, at: 0)
            let row = Row(text: line.text, spans: spans, panel: screen.panels[index]).plain(ground: screen.ground)
            if index > 0, line.wrapped, var last = rows.popLast() {
                last.append(row)
                rows.append(last)
            } else {
                rows.append(row)
            }
        }
        while let last = rows.last, last.isBlank { rows.removeLast() }
        return assemble(rows, ground: screen.ground)
    }

    /// Readable mode: the formatter's lines, coloured where a line still reads
    /// as a stretch of one source row. A line the formatter rewrote stays plain.
    static func readable(_ formatted: String, lines: [ScreenLine]) -> StyledText {
        readable(formatted, screen: prepare(lines))
    }

    /// `formatted` is the formatter's output for `ScreenModel.text(of: screen.lines)`.
    static func readable(_ formatted: String, screen: PreparedScreen) -> StyledText {
        let lines = screen.lines
        guard !lines.isEmpty, !formatted.isEmpty else { return StyledText(text: formatted, spans: []) }
        var byText: [String: [Int]] = [:]
        for (index, line) in lines.enumerated() where !line.runs.isEmpty {
            byText[Self.trimmedEnd(line.text), default: []].append(index)
        }
        var rows: [Row] = []
        var cursor = 0
        for piece in formatted.split(separator: "\n", omittingEmptySubsequences: false) {
            var row = Row(text: String(piece), spans: [], panel: -1)
            defer { rows.append(row.plain(ground: screen.ground)) }
            let line = row.text
            guard !row.isBlank else { continue }
            if let index = byText[line]?.first(where: { $0 >= cursor }) {
                row.spans = Self.spans(for: lines[index].runs, in: lines[index].text, at: 0)
                row.panel = screen.panels[index]
                cursor = index + 1
                continue
            }
            // The formatter trimmed or unwrapped this line: find it inside a row nearby.
            let limit = min(lines.count, cursor + 200)
            for index in cursor..<limit {
                let source = lines[index]
                guard !source.runs.isEmpty, let range = source.text.range(of: line) else { continue }
                let skipped = source.text[..<range.lowerBound].count
                row.spans = Self.spans(for: source.runs, in: source.text, at: 0, from: skipped, length: line.count)
                row.panel = screen.panels[index]
                cursor = index + 1
                break
            }
        }
        Self.bridgePanels(&rows)
        Self.dedent(&rows)
        for index in rows.indices where rows[index].panel < 0 { rows[index].collapseGaps() }
        return assemble(rows, ground: screen.ground)
    }

    /// A blank line between two lines of one panel belongs to it, as in a code block.
    static func bridgePanels(_ rows: inout [Row]) {
        var index = 1
        while index < rows.count {
            guard rows[index].isBlank, rows[index - 1].panel >= 0 else {
                index += 1
                continue
            }
            var next = index
            while next < rows.count, rows[next].isBlank { next += 1 }
            if next < rows.count, rows[next].panel == rows[index - 1].panel {
                for blank in index..<next { rows[blank].panel = rows[index - 1].panel }
            }
            index = next
        }
    }

    /// Removes the indent most lines share. A few shallower lines (a header)
    /// start at the margin; deeper lines keep their depth. The fifth from the
    /// bottom, so one header on a short screen does not set the margin.
    static func dedent(_ rows: inout [Row]) {
        let indents = rows.filter { !$0.isBlank }.map(\.indent).sorted()
        guard !indents.isEmpty else { return }
        let shared = indents[indents.count / 5]
        guard shared > 0 else { return }
        for index in rows.indices {
            let count = min(rows[index].indent, shared)
            if count > 0 { rows[index].remove(0..<count) }
        }
    }

    /// Where a wrapped line's continuation lines up: after its indent and list
    /// marker. In UTF-16 units of the line, at most `maxHang`.
    static func hangingPrefix(_ line: String) -> Int {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        var marker = 0
        var markerUnits = 0
        if let first = rest.first, Self.markers.contains(first) {
            marker = 1
            markerUnits = String(first).utf16.count
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }.count
            let mark = rest.dropFirst(digits).first
            if (1...3).contains(digits), mark == "." || mark == ")" {
                marker = digits + 1
                markerUnits = digits + 1
            }
        }
        let spaces = marker > 0 ? rest.dropFirst(marker).prefix { $0 == " " }.count : 0
        return min(spaces > 0 ? indent + markerUnits + spaces : indent, Self.maxHang)
    }

    static func assemble(_ rows: [Row], ground: Int) -> StyledText {
        var text = ""
        var spans: [StyledSpan] = []
        var panels: [StyledPanel] = []
        var offset = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                text.append("\n")
                offset += 1
            }
            spans += row.spans.map { span in
                var span = span
                span.location += offset
                return span
            }
            let length = row.text.utf16.count
            if row.panel >= 0 {
                panels.append(
                    StyledPanel(
                        location: offset, length: length, color: row.panel,
                        top: index == 0 || rows[index - 1].panel < 0,
                        bottom: index == rows.count - 1 || rows[index + 1].panel < 0))
            }
            text += row.text
            offset += length
        }
        return StyledText(text: text, spans: spans, ground: ground, panels: panels)
    }

    /// One output line being built, with spans from its own start.
    struct Row: Equatable {
        var text: String
        var spans: [StyledSpan]
        var panel: Int

        var isBlank: Bool { text.allSatisfy { $0 == " " } }
        var indent: Int { text.prefix { $0 == " " }.count }

        /// Drops the backgrounds the view paints itself: the ground and this line's panel.
        func plain(ground: Int) -> Row {
            var row = self
            row.spans = spans.map { span in
                var span = span
                let painted = span.bg == ground || (panel >= 0 && span.bg == panel)
                if span.bg >= 0, painted, span.flags & StyledSpan.inverse == 0 { span.bg = -1 }
                return span
            }
            return row
        }

        mutating func append(_ other: Row) {
            let shift = text.utf16.count
            spans += other.spans.map { span in
                var span = span
                span.location += shift
                return span
            }
            text += other.text
        }

        /// Deletes the spaces at UTF-16 units `range` and moves the spans with the text.
        mutating func remove(_ range: Range<Int>) {
            let start = String.Index(utf16Offset: range.lowerBound, in: text)
            let end = String.Index(utf16Offset: range.upperBound, in: text)
            text.removeSubrange(start..<end)
            func moved(_ offset: Int) -> Int {
                if offset <= range.lowerBound { return offset }
                return offset >= range.upperBound ? offset - range.count : range.lowerBound
            }
            spans = spans.compactMap { span in
                let from = moved(span.location)
                let to = moved(span.location + span.length)
                guard to > from else { return nil }
                var span = span
                span.location = from
                span.length = to - from
                return span
            }
        }

        mutating func collapseGaps() {
            let units = Array(text.utf16)
            let space = UInt16(UInt8(ascii: " "))
            var gaps: [Range<Int>] = []
            var index = indent
            while index < units.count {
                guard units[index] == space else {
                    index += 1
                    continue
                }
                let start = index
                while index < units.count, units[index] == space { index += 1 }
                if index < units.count, index - start >= StyledOutput.longGap { gaps.append((start + 2)..<index) }
            }
            for gap in gaps.reversed() { remove(gap) }
        }
    }

    /// Runs over Character offsets become spans over UTF-16 units of the text at `base`.
    /// `from` and `length` pick the stretch of the row the output line shows.
    static func spans(for runs: [[Int]], in text: String, at base: Int, from: Int = 0, length: Int? = nil)
        -> [StyledSpan]
    {
        guard !runs.isEmpty else { return [] }
        // UTF-16 offset of every Character boundary, including the end.
        var boundaries: [Int] = [0]
        boundaries.reserveCapacity(text.count + 1)
        var units = 0
        for character in text {
            units += String(character).utf16.count
            boundaries.append(units)
        }
        let shown = from..<(from + (length ?? max(text.count - from, 0)))
        var spans: [StyledSpan] = []
        for run in runs where run.count == 5 {
            let start = max(run[0], shown.lowerBound)
            let end = min(run[0] + run[1], shown.upperBound)
            guard start < end, end <= text.count else { continue }
            let location = base + boundaries[start] - boundaries[shown.lowerBound]
            let length = boundaries[end] - boundaries[start]
            spans.append(StyledSpan(location: location, length: length, fg: run[2], bg: run[3], flags: run[4]))
        }
        return spans
    }

    // MARK: Colours

    /// The colour as `0xRRGGBB`, or nil for the default.
    static func rgb(_ color: Int, palette: [String]) -> UInt32? {
        if color < 0 { return nil }
        if color >= RemoteScreen.trueColorBase { return UInt32(color - RemoteScreen.trueColorBase) & 0xFFFFFF }
        return ansi256(color, palette: palette)
    }

    /// The xterm 256-colour table: the theme's 16, a 6×6×6 cube, then 24 greys.
    static func ansi256(_ code: Int, palette: [String]) -> UInt32? {
        switch code {
        case 0..<16:
            guard palette.count > code, let value = UInt32(palette[code], radix: 16) else { return nil }
            return value
        case 16..<232:
            let index = code - 16
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            let red = steps[index / 36]
            let green = steps[(index / 6) % 6]
            let blue = steps[index % 6]
            return (red << 16) | (green << 8) | blue
        case 232..<256:
            let grey = UInt32(8 + (code - 232) * 10)
            return (grey << 16) | (grey << 8) | grey
        default:
            return nil
        }
    }

    private static func trimmedEnd(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace {
            end = text.index(before: end)
        }
        return String(text[..<end])
    }
}
