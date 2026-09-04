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

    /// Line truncation for a painted title, subtitle, or header.
    /// `.tail` only when `keepingMatchVisible` collapsed a path (leading `…`).
    public enum Truncation: Equatable, Sendable {
        case tail
        case middle
    }

    /// `.tail` when the visible string starts with the collapse ellipsis, else `.middle`.
    public static func truncation(forVisible text: String) -> Truncation {
        text.hasPrefix("…") ? .tail : .middle
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
        runs(in: haystack, matching: ranges(in: haystack, query: query))
    }

    /// `runs(in:query:)` relocated onto `container`, which must start with `haystack`.
    public static func runs(
        in haystack: String,
        query: String,
        asPrefixOf container: String
    ) -> [Run] {
        runs(in: container, matching: ranges(in: haystack, query: query, asPrefixOf: container))
    }

    /// Split `haystack` on already-computed ranges. The ranges must belong to `haystack`.
    public static func runs(
        in haystack: String,
        matching matchRanges: [Range<String.Index>]
    ) -> [Run] {
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

    /// What a conversation row should paint: title runs plus one subtitle string
    /// whose runs were built from that same instance.
    public struct RowPaint: Equatable, Sendable {
        public var titleRuns: [Run]
        public var subtitle: String
        public var subtitleRuns: [Run]

        public var paints: Bool {
            titleRuns.contains(where: \.isMatch) || subtitleRuns.contains(where: \.isMatch)
        }

        public var subtitleTruncation: Truncation {
            SearchMatchHighlight.truncation(forVisible: subtitle)
        }
    }

    /// What a Projects section header should paint.
    public struct HeaderPaint: Equatable, Sendable {
        public var text: String
        public var runs: [Run]

        public var paints: Bool { runs.contains(where: \.isMatch) }

        public var visibleTruncation: Truncation { SearchMatchHighlight.truncation(forVisible: text) }
    }

    /// Visible title/subtitle paint for one sidebar row.
    ///
    /// Displayed title is always the title line. When that has no hit, the
    /// subtitle reuses the project name, a matching path, or the CLI summary
    /// so a listed row still has an accent run. In Projects sort the folder
    /// cue lives on the section header, so a project/cwd-only hit leaves the
    /// row subtitle as the timestamp unless `headerCoversQuery` is false.
    public static func row(
        displayedTitle: String,
        cliTitle: String,
        projectName: String,
        cwd: String,
        displayPath: String,
        relativeTime: String,
        showsProject: Bool,
        headerCoversQuery: Bool = true,
        query: String
    ) -> RowPaint {
        let titleRuns = runs(in: displayedTitle, query: query)
        let pathHit = matchingPath(in: [projectName, displayPath, cwd], query: query)
        let prefix: String?
        if showsProject, let pathHit {
            prefix = keepingMatchVisible(pathHit, query: query)
        } else if !contains(displayedTitle, query: query), contains(cliTitle, query: query) {
            prefix = cliTitle
        } else if !showsProject, !headerCoversQuery, let pathHit {
            prefix = keepingMatchVisible(pathHit, query: query)
        } else if showsProject {
            prefix = projectName
        } else {
            prefix = nil
        }
        let subtitle = subtitleText(prefix: prefix, relativeTime: relativeTime)
        let ranges: [Range<String.Index>] =
            if let prefix, !prefix.isEmpty {
                self.ranges(in: prefix, query: query, asPrefixOf: subtitle)
            } else {
                []
            }
        return RowPaint(
            titleRuns: titleRuns,
            subtitle: subtitle,
            subtitleRuns: runs(in: subtitle, matching: ranges)
        )
    }

    /// Projects header. A cwd-only hit swaps the short name for the matching path
    /// so the accent run has a substring to sit on. `paths` should include every
    /// member spelling (displayPath and cwd) so a symlink alias still paints.
    public static func projectHeader(
        name: String,
        paths: [String],
        count: Int,
        query: String
    ) -> HeaderPaint {
        let raw = matchingPath(in: [name] + paths, query: query) ?? name
        let prefix = keepingMatchVisible(raw, query: query)
        let text = "\(prefix) (\(count))"
        let ranges = ranges(in: prefix, query: query, asPrefixOf: text)
        return HeaderPaint(text: text, runs: runs(in: text, matching: ranges))
    }

    public static func projectHeader(
        name: String,
        displayPath: String,
        cwd: String,
        count: Int,
        query: String
    ) -> HeaderPaint {
        projectHeader(name: name, paths: [displayPath, cwd], count: count, query: query)
    }

    /// VoiceOver text for a Projects header. While searching, speak the painted
    /// string so a path-swapped match is heard, not only the short folder name.
    public static func headerAccessibilityLabel(
        paint: HeaderPaint,
        shortName: String,
        count: Int,
        isPinned: Bool,
        query: String
    ) -> String {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let base = searching ? paint.text : "\(shortName), \(count) conversations"
        return base + (isPinned ? ", pinned" : "")
    }

    /// VoiceOver text for a conversation row. While searching, speak the painted
    /// subtitle so a path-only or CLI-only hit is heard, not only the folder name.
    public static func rowAccessibilityLabel(
        title: String,
        projectName: String,
        longRelative: String,
        paint: RowPaint,
        isPinned: Bool,
        isArchived: Bool,
        query: String
    ) -> String {
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var label =
            searching
            ? "\(title), \(paint.subtitle)"
            : "\(title), \(projectName), \(longRelative)"
        if isPinned { label += ", pinned" }
        if isArchived { label += ", archived" }
        return label
    }

    /// Drop a leading path so the first match sits at the start of the visible
    /// string. Tail truncation can then keep the accent run on-screen.
    /// Only rewrites strings that contain `/` (cwd / displayPath). Slash-free
    /// project names and CLI summaries stay intact, even for a mid-string hit.
    public static func keepingMatchVisible(_ string: String, query: String) -> String {
        guard string.contains("/") else { return string }
        guard let first = ranges(in: string, query: query).first else { return string }
        let lead = string.distance(from: string.startIndex, to: first.lowerBound)
        if lead <= 2 { return string }
        let leading = string[string.startIndex..<first.lowerBound]
        let restStart = leading.lastIndex(of: "/") ?? first.lowerBound
        if restStart == string.startIndex { return string }
        return "…" + String(string[restStart...])
    }

    /// First candidate that contains `query`. Empty strings are skipped.
    static func matchingPath(in candidates: [String], query: String) -> String? {
        candidates.first { !$0.isEmpty && contains($0, query: query) }
    }

    private static func subtitleText(prefix: String?, relativeTime: String) -> String {
        guard let prefix, !prefix.isEmpty else { return relativeTime }
        return "\(prefix) · \(relativeTime)"
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
