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

struct StyledText: Equatable {
    var text: String
    var spans: [StyledSpan]

    static let empty = StyledText(text: "", spans: [])
}

/// Builds the output the session screen draws, with the terminal's colours.
enum StyledOutput {
    /// Raw mode: every row as the Mac drew it, without the blank rows under the cursor.
    static func raw(_ lines: [ScreenLine]) -> StyledText {
        var lines = lines
        while let last = lines.last, last.text.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        var text = ""
        var spans: [StyledSpan] = []
        var offset = 0
        for (index, line) in lines.enumerated() {
            if index > 0, !line.wrapped {
                text.append("\n")
                offset += 1
            }
            spans += Self.spans(for: line.runs, in: line.text, at: offset)
            text += line.text
            offset += line.text.utf16.count
        }
        return StyledText(text: text, spans: spans)
    }

    /// Readable mode: the formatter's lines, coloured where a line still reads
    /// as a stretch of one source row. A line the formatter rewrote stays plain.
    static func readable(_ formatted: String, lines: [ScreenLine]) -> StyledText {
        guard !lines.isEmpty, !formatted.isEmpty else { return StyledText(text: formatted, spans: []) }
        var byText: [String: [Int]] = [:]
        for (index, line) in lines.enumerated() where !line.runs.isEmpty {
            byText[Self.trimmedEnd(line.text), default: []].append(index)
        }
        var spans: [StyledSpan] = []
        var offset = 0
        var cursor = 0
        for piece in formatted.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(piece)
            defer { offset += line.utf16.count + 1 }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let index = byText[line]?.first(where: { $0 >= cursor }) {
                spans += Self.spans(for: lines[index].runs, in: lines[index].text, at: offset)
                cursor = index + 1
                continue
            }
            // The formatter trimmed or unwrapped this line: find it inside a row nearby.
            let limit = min(lines.count, cursor + 200)
            for index in cursor..<limit {
                let source = lines[index]
                guard !source.runs.isEmpty, let range = source.text.range(of: line) else { continue }
                let skipped = source.text[..<range.lowerBound].count
                spans += Self.spans(for: source.runs, in: source.text, at: offset, from: skipped, length: line.count)
                cursor = index + 1
                break
            }
        }
        return StyledText(text: formatted, spans: spans)
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
