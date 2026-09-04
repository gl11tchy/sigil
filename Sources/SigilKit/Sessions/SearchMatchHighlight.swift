import Foundation

/// Fold-aware substring ranges for sidebar search highlighting.
///
/// `SessionScanner.matches` decides whether a conversation is listed by folding
/// title, project name, and path with case- and diacritic-insensitive options,
/// then asking whether the folded haystack contains the folded query.
/// Highlighting has to paint the *original* characters that produced that hit,
/// including clusters that expand under folding (`ß` → `ss`). `range(of:options:)`
/// is not equivalent: it looks for a substring that *compares equal* to the
/// query, so `"s"` would miss `"ß"` even though `matches` would keep the row.
public enum SearchMatchHighlight: Sendable {
    public static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// One run of a title or subtitle after search highlighting is applied.
    public struct Run: Equatable, Sendable {
        public var text: String
        public var isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// Same fold `SessionScanner.matches` uses: case and diacritic insensitive, no locale.
    public static func fold(_ string: String) -> String {
        string.folding(options: foldOptions, locale: nil)
    }

    /// True when `fold(haystack)` contains `fold(trimmed query)`.
    /// An empty or whitespace-only query is not a hit — callers treat that as "show all".
    public static func contains(_ haystack: String, query: String) -> Bool {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if needle.isEmpty { return false }
        return fold(haystack).contains(needle)
    }

    /// Original-string ranges whose folded form is a non-overlapping occurrence of the
    /// folded query. Empty or whitespace-only query yields no ranges.
    public static func ranges(in haystack: String, query: String) -> [Range<String.Index>] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }

        let mapped = foldMap(haystack)
        var result: [Range<String.Index>] = []
        var searchFrom = mapped.folded.startIndex
        while let hit = mapped.folded.range(of: needle, range: searchFrom..<mapped.folded.endIndex) {
            searchFrom = hit.upperBound
            let startOffset = mapped.folded.distance(from: mapped.folded.startIndex, to: hit.lowerBound)
            let endOffset = mapped.folded.distance(from: mapped.folded.startIndex, to: hit.upperBound)
            guard startOffset < endOffset, endOffset <= mapped.origins.count else { continue }
            let original = mapped.origins[startOffset].lowerBound..<mapped.origins[endOffset - 1].upperBound
            if let last = result.last, last.upperBound >= original.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, original.upperBound)
            } else {
                result.append(original)
            }
        }
        return result
    }

    /// `ranges(in:query:)` relocated onto `container`, which must start with `haystack`.
    /// Used for a subtitle that shows a project name (or path) then a timestamp.
    public static func ranges(
        in haystack: String,
        query: String,
        asPrefixOf container: String
    ) -> [Range<String.Index>] {
        guard container.hasPrefix(haystack) else { return [] }
        return ranges(in: haystack, query: query).map { range in
            let start = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let end = haystack.distance(from: haystack.startIndex, to: range.upperBound)
            let lower = container.index(container.startIndex, offsetBy: start)
            let upper = container.index(container.startIndex, offsetBy: end)
            return lower..<upper
        }
    }

    /// Title or subtitle broken into unmatched / matched runs, in order.
    public static func runs(in haystack: String, query: String) -> [Run] {
        let matchRanges = ranges(in: haystack, query: query)
        guard !haystack.isEmpty else { return [] }
        guard !matchRanges.isEmpty else { return [Run(text: haystack, isMatch: false)] }
        var result: [Run] = []
        var current = haystack.startIndex
        for range in matchRanges {
            if current < range.lowerBound {
                result.append(Run(text: String(haystack[current..<range.lowerBound]), isMatch: false))
            }
            result.append(Run(text: String(haystack[range]), isMatch: true))
            current = range.upperBound
        }
        if current < haystack.endIndex {
            result.append(Run(text: String(haystack[current...]), isMatch: false))
        }
        return result
    }

    /// Per-grapheme fold plus the original cluster that produced each folded character.
    /// One original cluster that expands (`ß` → `ss`) occupies several origin slots.
    static func foldMap(_ string: String) -> (folded: String, origins: [Range<String.Index>]) {
        var folded = ""
        var origins: [Range<String.Index>] = []
        origins.reserveCapacity(string.count)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            let foldedCluster = fold(String(string[index..<next]))
            if !foldedCluster.isEmpty {
                for _ in foldedCluster {
                    origins.append(index..<next)
                }
                folded += foldedCluster
            }
            index = next
        }
        return (folded, origins)
    }
}
