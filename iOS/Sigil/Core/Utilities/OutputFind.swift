import Foundation

/// Find in output. The view marks matches over the styled text, never in it, so
/// a new query restyles nothing and closing find leaves the text as it was.
enum OutputFind {
    /// Every match of `query` in `text`, first to last and not overlapping, case
    /// ignored, in UTF-16 units.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var result: [NSRange] = []
        var range = NSRange(location: 0, length: source.length)
        while true {
            let found = source.range(of: query, options: [.caseInsensitive], range: range)
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            let next = found.location + found.length
            range = NSRange(location: next, length: source.length - next)
        }
        return result
    }

    /// The parts of `matches`, which are in order, that fall in `range`.
    static func matches(_ matches: [NSRange], in range: NSRange) -> [NSRange] {
        var low = 0
        var high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(matches[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        var result: [NSRange] = []
        for match in matches[low...] {
            guard match.location < NSMaxRange(range) else { break }
            result.append(NSIntersectionRange(match, range))
        }
        return result
    }

    /// The parts of `matches` in `range` that fall outside the text already
    /// `marked`: what marking the lines near the screen still has to add.
    static func matches(_ matches: [NSRange], in range: NSRange, besides marked: IndexSet) -> [NSRange] {
        IndexSet(integersIn: range.location..<NSMaxRange(range)).subtracting(marked).rangeView.flatMap { part in
            Self.matches(matches, in: NSRange(location: part.lowerBound, length: part.count))
        }
    }

    /// `matches` once `edit` is made: those it replaced go and those after it move.
    /// They hold until a search of the new text replaces them.
    static func matches(_ matches: [NSRange], after edit: StyledEdit) -> [NSRange] {
        let shift = edit.replacement.text.utf16.count - edit.range.count
        return matches.compactMap { match in
            if NSMaxRange(match) <= edit.range.lowerBound { return match }
            guard match.location >= edit.range.upperBound else { return nil }
            return NSRange(location: match.location + shift, length: match.length)
        }
    }
}

/// Runs find on a queue of its own, so typing a query never searches on the main
/// thread. A search that a newer one replaced before it began is skipped.
final class OutputFinder: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var latest = 0

    init(queue: DispatchQueue = DispatchQueue(label: "dev.sigil.find", qos: .userInitiated)) {
        self.queue = queue
    }

    /// Calls `done` on the queue with the matches, or nil when skipped.
    func submit(_ query: String, in text: String, done: @escaping @Sendable ([NSRange]?) -> Void) {
        let token = lock.withLock {
            latest += 1
            return latest
        }
        queue.async {
            guard self.lock.withLock({ self.latest }) == token else { return done(nil) }
            done(OutputFind.matches(of: query, in: text))
        }
    }

    func matches(of query: String, in text: String) async -> [NSRange]? {
        await withCheckedContinuation { continuation in
            submit(query, in: text) { continuation.resume(returning: $0) }
        }
    }
}
