import Foundation

/// Locates plain-text matches in an array of terminal buffer lines.
///
/// Matches stay inside a single row so a selection is one contiguous cell
/// range. Folding is case- and diacritic-insensitive; there is no regex.
struct ScrollbackSearch: Equatable, Sendable {
    struct Match: Equatable, Sendable {
        /// Zero-based buffer row.
        let line: Int
        /// Half-open column range in that row, matching `Position.col`.
        let columns: Range<Int>
    }

    private static let fold: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private(set) var query: String = ""
    private(set) var matches: [Match] = []
    /// Zero-based index into `matches`, or `nil` when there are none.
    private(set) var current: Int?

    var matchCount: Int { matches.count }

    var currentMatch: Match? {
        guard let current, matches.indices.contains(current) else { return nil }
        return matches[current]
    }

    mutating func setQuery(_ query: String, in lines: [String]) {
        if query.isEmpty {
            clear()
            return
        }
        self.query = query
        matches = Self.locate(query, in: lines)
        current = matches.isEmpty ? nil : 0
    }

    /// Rematches the current query against `lines`, keeping the current hit
    /// when that exact range is still present.
    mutating func updateLines(_ lines: [String]) {
        guard !query.isEmpty else {
            clear()
            return
        }
        let previous = currentMatch
        matches = Self.locate(query, in: lines)
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

    private static func locate(_ query: String, in lines: [String]) -> [Match] {
        var found: [Match] = []
        for (lineIndex, line) in lines.enumerated() {
            var searchRange = line.startIndex..<line.endIndex
            while let hit = line.range(of: query, options: fold, range: searchRange) {
                let start = line.distance(from: line.startIndex, to: hit.lowerBound)
                let end = line.distance(from: line.startIndex, to: hit.upperBound)
                found.append(Match(line: lineIndex, columns: start..<end))
                searchRange = hit.upperBound..<line.endIndex
            }
        }
        return found
    }
}
