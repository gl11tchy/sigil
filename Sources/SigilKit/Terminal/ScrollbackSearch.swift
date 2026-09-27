import Foundation
import os

/// Locates plain-text matches in terminal rows while preserving cell positions.
struct ScrollbackSearch: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let text: String
        /// One terminal-column boundary for every Character boundary in `text`.
        let cellColumns: [Int]
        /// True when this row is a soft continuation of the previous row.
        let isWrapped: Bool

        init(text: String, cellColumns: [Int]? = nil, isWrapped: Bool = false) {
            self.text = text
            self.cellColumns = cellColumns ?? Array(0...text.count)
            self.isWrapped = isWrapped
        }
    }

    struct Match: Equatable, Sendable {
        /// Zero-based start buffer row.
        let line: Int
        /// Start-row cell range for compatibility with same-row callers.
        let columns: Range<Int>
        /// Exclusive end position, which can be on a later soft-wrapped row.
        let endLine: Int
        let endColumn: Int
    }

    /// Rows joined into logical lines once, so several searches of the same
    /// buffer do not rebuild them. `version` names the buffer contents; hits
    /// are reused only when a later search has the same version and query.
    struct Text: Sendable {
        let version: Int?
        fileprivate let lines: [LogicalLine]

        init(_ rows: [Row], version: Int? = nil) {
            self.version = version
            lines = ScrollbackSearch.logicalLines(rows)
        }
    }

    fileprivate struct CellPosition: Equatable, Sendable {
        let row: Int
        let column: Int
    }

    fileprivate struct LogicalLine: Sendable {
        var text = ""
        /// Boundary at each Character offset, including the exclusive end.
        var positions: [CellPosition] = []
    }

    private static let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private(set) var query: String = ""
    private(set) var matches: [Match] = []
    private(set) var current: Int?
    /// Version of the text that produced `matches`, or nil when it had none.
    private var matchedVersion: Int?

    var matchCount: Int { matches.count }

    var currentMatch: Match? {
        guard let current, matches.indices.contains(current) else { return nil }
        return matches[current]
    }

    mutating func setQuery(_ query: String, in lines: [String]) {
        setQuery(query, in: lines.map { Row(text: $0) })
    }

    /// Starts at the last hit on or above `line`, else the first hit below it.
    mutating func setQuery(_ query: String, in rows: [Row], startingAtOrAbove line: Int? = nil) {
        setQuery(query, in: Text(rows), startingAtOrAbove: line)
    }

    /// Starts at the last hit on or above `line`, else the first hit below it.
    mutating func setQuery(_ query: String, in text: Text, startingAtOrAbove line: Int? = nil) {
        if query.isEmpty {
            clear()
            return
        }
        matches = reusableMatches(for: query, in: text) ?? Self.locate(query, in: text.lines)
        self.query = query
        matchedVersion = text.version
        if matches.isEmpty {
            current = nil
        } else if let line {
            current = matches.lastIndex { $0.line <= line } ?? 0
        } else {
            current = 0
        }
    }

    mutating func updateLines(_ lines: [String]) {
        updateRows(lines.map { Row(text: $0) })
    }

    mutating func updateRows(_ rows: [Row]) {
        update(Text(rows))
    }

    /// Searches `text` again for the current query and keeps the current hit
    /// when it is still there.
    mutating func update(_ text: Text) {
        guard !query.isEmpty else {
            clear()
            return
        }
        let previous = currentMatch
        matches = reusableMatches(for: query, in: text) ?? Self.locate(query, in: text.lines)
        matchedVersion = text.version
        if let previous, let index = matches.firstIndex(of: previous) {
            current = index
        } else if matches.isEmpty {
            current = nil
        } else if let current, matches.indices.contains(current) {
            return
        } else {
            self.current = 0
        }
    }

    mutating func clear() {
        query = ""
        matches = []
        current = nil
        matchedVersion = nil
    }

    @discardableResult
    mutating func findNext() -> Match? {
        guard !matches.isEmpty else {
            current = nil
            return nil
        }
        current = ((current ?? -1) + 1) % matches.count
        return currentMatch
    }

    @discardableResult
    mutating func findPrevious() -> Match? {
        guard !matches.isEmpty else {
            current = nil
            return nil
        }
        current = ((current ?? 0) - 1 + matches.count) % matches.count
        return currentMatch
    }

    /// The last hits, when they came from this exact query and buffer version.
    private func reusableMatches(for query: String, in text: Text) -> [Match]? {
        // Scalars, not `==`: canonically equivalent queries are different input.
        guard let version = text.version, version == matchedVersion,
            query.unicodeScalars.elementsEqual(self.query.unicodeScalars)
        else { return nil }
        return matches
    }

    /// Logical lines per search chunk. Chunks run on separate threads and
    /// their hits are joined in line order, so the list is the one a single
    /// pass over every line gives.
    static let linesPerChunk = 512

    private static func locate(_ query: String, in lines: [LogicalLine]) -> [Match] {
        let chunkCount = (lines.count + linesPerChunk - 1) / linesPerChunk
        guard chunkCount > 1 else { return locate(query, in: lines[...]) }
        let chunks = OSAllocatedUnfairLock(initialState: [[Match]](repeating: [], count: chunkCount))
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let start = chunk * linesPerChunk
            let found = locate(query, in: lines[start..<min(start + linesPerChunk, lines.count)])
            chunks.withLock { $0[chunk] = found }
        }
        return chunks.withLock { $0 }.flatMap { $0 }
    }

    private static func locate(_ query: String, in lines: ArraySlice<LogicalLine>) -> [Match] {
        lines.flatMap { logical in
            var found: [Match] = []
            var searchRange = logical.text.startIndex..<logical.text.endIndex
            // Offsets carry forward from the previous hit, so a long line stays linear.
            var offset = 0
            while let hit = logical.text.range(of: query, options: fold, range: searchRange) {
                let startOffset = offset + logical.text.distance(from: searchRange.lowerBound, to: hit.lowerBound)
                let endOffset = startOffset + logical.text.distance(from: hit.lowerBound, to: hit.upperBound)
                guard logical.positions.indices.contains(startOffset),
                    logical.positions.indices.contains(endOffset)
                else { break }
                let start = logical.positions[startOffset]
                let end = logical.positions[endOffset]
                let sameRowEnd = end.row == start.row ? end.column : start.column + 1
                found.append(
                    Match(
                        line: start.row,
                        columns: start.column..<max(start.column, sameRowEnd),
                        endLine: end.row,
                        endColumn: end.column
                    )
                )
                searchRange = hit.upperBound..<logical.text.endIndex
                offset = endOffset
            }
            return found
        }
    }

    private static func logicalLines(_ rows: [Row]) -> [LogicalLine] {
        var result: [LogicalLine] = []
        for (rowIndex, row) in rows.enumerated() {
            let columns =
                row.cellColumns.count == row.text.count + 1
                ? row.cellColumns : Array(0...row.text.count)
            if result.isEmpty || !row.isWrapped {
                result.append(LogicalLine())
            }
            let index = result.count - 1
            if result[index].positions.isEmpty {
                result[index].positions.append(CellPosition(row: rowIndex, column: columns[0]))
            } else {
                // Replace the prior row's exclusive end with the continuation's start.
                result[index].positions[result[index].positions.count - 1] =
                    CellPosition(row: rowIndex, column: columns[0])
            }
            result[index].text += row.text
            for boundary in columns.dropFirst() {
                result[index].positions.append(CellPosition(row: rowIndex, column: boundary))
            }
        }
        return result
    }
}
