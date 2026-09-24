import Foundation

/// A window of terminal rows for the phone, addressed by buffer-absolute index
/// so a change can be sent as the rows that changed instead of the whole screen.
public struct RemoteScreen: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        /// Buffer-absolute index; rows below the window are history on the phone.
        public var i: Int
        public var t: String
        /// True when this row continues the previous one without a line break.
        public var w: Bool?
        /// Style runs `[start, length, fg, bg, flags]` over Character offsets.
        /// Only runs that differ from the default style are sent.
        public var s: [[Int]]?

        public init(i: Int, t: String, w: Bool? = nil, s: [[Int]]? = nil) {
            self.i = i
            self.t = t
            self.w = w
            self.s = s
        }
    }

    /// The tab these rows belong to, so a late reply cannot land in another tab's rows.
    public var tab: String?
    /// Bumped when the index space restarts: a buffer reset, a screen switch, or another tab.
    public var gen: Int
    public var alt: Bool?
    /// The first row of the Mac's window. Rows the phone holds below it are history.
    public var first: Int
    /// One past the last row; the phone drops rows at or beyond it.
    public var end: Int
    public var rows: [Row]
    /// The tab's terminal theme, sent with a full window so ANSI colours match the Mac.
    public var palette: [String]?
    public var fg: String?
    public var bg: String?

    public init(
        tab: String? = nil, gen: Int, alt: Bool? = nil, first: Int, end: Int, rows: [Row], palette: [String]? = nil,
        fg: String? = nil, bg: String? = nil
    ) {
        self.tab = tab
        self.gen = gen
        self.alt = alt
        self.first = first
        self.end = end
        self.rows = rows
        self.palette = palette
        self.fg = fg
        self.bg = bg
    }

    /// A colour as one Int: -1 for the default, 0…255 for the ANSI table,
    /// `trueColorBase + 0xRRGGBB` for 24-bit colour.
    public static let trueColorBase = 1 << 24
    public static let defaultColor = -1

    public static func trueColor(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        trueColorBase + (Int(red) << 16) + (Int(green) << 8) + Int(blue)
    }

    public static func hex(_ value: UInt32) -> String {
        String(format: "%06x", value & 0xFFFFFF)
    }
}

/// The full window the terminal shows right now, before diffing.
public struct RemoteScreenWindow: Sendable, Equatable {
    public var gen: Int
    public var alt: Bool
    public var first: Int
    public var end: Int
    public var rows: [RemoteScreen.Row]
    public var palette: [String]
    public var fg: String
    public var bg: String

    public init(
        gen: Int, alt: Bool, first: Int, end: Int, rows: [RemoteScreen.Row], palette: [String], fg: String,
        bg: String
    ) {
        self.gen = gen
        self.alt = alt
        self.first = first
        self.end = end
        self.rows = rows
        self.palette = palette
        self.fg = fg
        self.bg = bg
    }

    public static let empty = RemoteScreenWindow(
        gen: 0, alt: false, first: 0, end: 0, rows: [], palette: [], fg: "", bg: "")
}

/// Remembers what one phone connection has seen, so each update carries only
/// the rows that changed. A new tab or generation starts over with a full window.
public struct RemoteScreenStream: Sendable, Equatable {
    private var tabID: String?
    private var gen = -1
    private var sent: [Int: Int] = [:]
    private var end = 0
    private var first = 0

    public init() {}

    /// Rows the phone does not have yet, or nil when nothing changed.
    /// `force` sends the whole window, for a phone that just started watching.
    public mutating func update(_ window: RemoteScreenWindow, tabID: String?, force: Bool = false) -> RemoteScreen? {
        let fresh = force || tabID != self.tabID || window.gen != gen
        if fresh {
            self.tabID = tabID
            gen = window.gen
            sent = [:]
            end = -1
            first = -1
        }
        var changed: [RemoteScreen.Row] = []
        var next: [Int: Int] = [:]
        for row in window.rows {
            let digest = Self.digest(row)
            next[row.i] = digest
            if sent[row.i] != digest { changed.append(row) }
        }
        let boundsMoved = window.end != end || window.first != first
        // Rows that left the window scrolled into history; the phone keeps them as sent.
        sent = next
        end = window.end
        first = window.first
        guard fresh || !changed.isEmpty || boundsMoved else { return nil }
        return RemoteScreen(
            tab: tabID, gen: window.gen, alt: window.alt ? true : nil, first: window.first, end: window.end,
            rows: changed, palette: fresh ? window.palette : nil, fg: fresh ? window.fg : nil,
            bg: fresh ? window.bg : nil)
    }

    public mutating func reset() {
        self = RemoteScreenStream()
    }

    private static func digest(_ row: RemoteScreen.Row) -> Int {
        var hasher = Hasher()
        hasher.combine(row.t)
        hasher.combine(row.w ?? false)
        hasher.combine(row.s ?? [])
        return hasher.finalize()
    }
}

/// Builds style runs for one row from per-cell attributes.
public struct RemoteStyleRuns: Sendable {
    public struct Cell: Sendable, Equatable {
        public var fg: Int
        public var bg: Int
        public var flags: Int

        public init(fg: Int, bg: Int, flags: Int) {
            self.fg = fg
            self.bg = bg
            self.flags = flags
        }

        public static let plain = Cell(fg: RemoteScreen.defaultColor, bg: RemoteScreen.defaultColor, flags: 0)
    }

    private var runs: [[Int]] = []
    private var open: (start: Int, length: Int, cell: Cell)?

    public init() {}

    /// Appends one Character with its style. `width` is how many Characters it spans (always 1 here).
    public mutating func append(_ cell: Cell, at offset: Int) {
        if let current = open, current.cell == cell, current.start + current.length == offset {
            open = (current.start, current.length + 1, cell)
            return
        }
        close()
        if cell != .plain { open = (offset, 1, cell) }
    }

    public mutating func finish() -> [[Int]]? {
        close()
        return runs.isEmpty ? nil : runs
    }

    private mutating func close() {
        guard let current = open else { return }
        runs.append([current.start, current.length, current.cell.fg, current.cell.bg, current.cell.flags])
        open = nil
    }
}
