import Foundation

/// One row the phone holds: the Mac's text and style runs, by absolute index.
struct ScreenLine: Codable, Equatable {
    var index: Int
    var text: String
    /// Continues the row before it without a line break.
    var wrapped: Bool
    /// `[start, length, fg, bg, flags]` over Character offsets of `text`.
    var runs: [[Int]]

    init(index: Int, text: String, wrapped: Bool = false, runs: [[Int]] = []) {
        self.index = index
        self.text = text
        self.wrapped = wrapped
        self.runs = runs
    }

    init(_ row: RemoteScreenRow) {
        self.init(index: row.i, text: row.t, wrapped: row.w == true, runs: row.s ?? [])
    }
}

/// The rows of one session as the Mac streams them: its current window plus
/// the rows that scrolled out of it, kept as history under a cap.
struct ScreenModel: Codable, Equatable {
    private(set) var gen = -1
    private(set) var rows: [Int: ScreenLine] = [:]
    /// The Mac's window starts here; everything below is history.
    private(set) var first = 0
    private(set) var end = 0
    private(set) var palette: [String] = []
    private(set) var foreground = ""
    private(set) var background = ""
    /// No older rows exist on the Mac.
    var exhausted = false

    /// About 400 KB of text at 100 characters a row.
    static let cap = 4_000
    /// Rows held past the cap before the oldest go, down to the cap. Cutting the
    /// top of the view's text costs several times what adding to its end does,
    /// so that happens once in this many rows rather than with every row.
    static let slack = 256

    var isEmpty: Bool { rows.isEmpty }
    var oldestIndex: Int? { rows.keys.min() }

    /// A full window or a diff. A new generation starts the rows over.
    mutating func apply(_ screen: RemoteScreen) {
        if screen.gen != gen {
            gen = screen.gen
            rows = [:]
            exhausted = false
        }
        if let palette = screen.palette { self.palette = palette }
        if let fg = screen.fg { foreground = fg }
        if let bg = screen.bg { background = bg }
        for row in screen.rows { rows[row.i] = ScreenLine(row) }
        first = screen.first
        end = screen.end
        // The Mac's screen shrank: rows past its end are gone.
        rows = rows.filter { $0.key < screen.end }
        trim()
    }

    /// Older rows from a `rows` reply. Returns false, and remembers it, when nothing older exists.
    @discardableResult
    mutating func prepend(_ screen: RemoteScreen) -> Bool {
        guard screen.gen == gen else { return false }
        let oldest = oldestIndex ?? end
        let older = screen.rows.filter { $0.i < oldest }
        guard !older.isEmpty, rows.count + older.count <= Self.cap else {
            exhausted = true
            return false
        }
        for row in older { rows[row.i] = ScreenLine(row) }
        return true
    }

    private mutating func trim() {
        guard rows.count > Self.cap + Self.slack else { return }
        let keep = rows.keys.sorted().suffix(Self.cap)
        guard let floor = keep.first else { return }
        rows = rows.filter { $0.key >= floor }
        exhausted = false
    }

    var lines: [ScreenLine] {
        rows.keys.sorted().compactMap { rows[$0] }
    }

    /// The rows as one text, the way the Mac renders them for the web companion:
    /// a wrapped row joins the one before it without a line break.
    static func text(of lines: [ScreenLine]) -> String {
        var result = ""
        for (offset, line) in lines.enumerated() {
            if offset > 0, !line.wrapped { result.append("\n") }
            result += line.text
        }
        return result
    }

    var text: String { Self.text(of: lines) }
}
