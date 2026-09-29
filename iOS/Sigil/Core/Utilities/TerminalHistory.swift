import Foundation

/// Scrollback for one session. The Mac only ever sends the last 12 KB of the
/// screen, so older text is kept here as it scrolls out of each snapshot.
/// A port of `applyTail` and `prependSlice` from the web companion. It works in
/// UTF-16 units, as JavaScript does, so both companions cut text at the same places.
struct TerminalHistory: Equatable {
    typealias Units = [UInt16]
    static let cap = 400_000

    private(set) var history: Units = []
    private(set) var tail: Units = []
    var exhausted = false

    var text: String { String(decoding: history + tail, as: UTF16.self) }
    var count: Int { history.count + tail.count }

    mutating func apply(_ snapshot: String) {
        let next = Units(snapshot.utf16)
        let loaded = history + tail
        if loaded.isEmpty {
            tail = next
            return
        }
        if !next.isEmpty, loaded.count >= next.count, Self.equal(loaded, loaded.count - next.count, next, 0, next.count) {
            history = Units(loaded.prefix(loaded.count - next.count))
            tail = next
            return
        }
        let overlap = Self.overlapSuffixPrefix(loaded, next)
        if overlap > 0 {
            history = Units(loaded.prefix(loaded.count - overlap))
            // Streamed output takes this path on every poll; keep the newest text under the cap.
            if history.count > Self.cap { history = Units(history.suffix(Self.cap)) }
            tail = next
            return
        }
        let shared = Self.commonPrefix(tail, 0, next)
        let shorter = min(tail.count, next.count)
        if shorter > 0, shared * 2 >= shorter {
            tail = next
            return
        }
        // A sliding window under a fixed footer has no suffix/prefix overlap.
        // Keep only the old text that scrolled out above the new snapshot's start.
        // Repeated blocks can match early; take the match that agrees longest, then the latest.
        let start = Units(next.prefix(200))
        var at = -1
        var agreed = -1
        if !String(decoding: start, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for i in Self.occurrences(of: start, in: tail) {
                let shared = Self.commonPrefix(tail, i, next)
                if shared >= agreed {
                    agreed = shared
                    at = i
                }
            }
        }
        let scrolled = at > 0 ? Units(tail.prefix(at)) : tail
        let room = Self.cap - history.count
        if room > 0 { history += scrolled.prefix(room) }
        tail = next
    }

    /// Older text the Mac found above what is loaded. Returns whether anything was added.
    @discardableResult
    mutating func prepend(_ slice: String) -> Bool {
        guard !slice.isEmpty, slice.utf8.count <= 12_000 else {
            exhausted = true
            return false
        }
        let incoming = Units(slice.utf16)
        let overlap = Self.overlapSuffixPrefix(incoming, history + tail)
        let addition = incoming.prefix(incoming.count - overlap)
        guard !addition.isEmpty, history.count + addition.count <= Self.cap else {
            exhausted = true
            return false
        }
        history = Units(addition) + history
        return true
    }

    /// The longest suffix of `left` that is also a prefix of `right`.
    static func overlapSuffixPrefix(_ left: Units, _ right: Units) -> Int {
        guard let first = right.first, !left.isEmpty else { return 0 }
        let begin = left.count - min(left.count, right.count)
        for i in begin..<left.count where left[i] == first {
            if equal(left, i, right, 0, left.count - i) { return left.count - i }
        }
        return 0
    }

    static func commonPrefix(_ left: Units, _ offset: Int, _ right: Units) -> Int {
        let limit = min(left.count - offset, right.count)
        var count = 0
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                while count < limit, l[offset + count] == r[count] { count += 1 }
            }
        }
        return count
    }

    private static func equal(_ a: Units, _ ai: Int, _ b: Units, _ bi: Int, _ length: Int) -> Bool {
        guard length > 0 else { return true }
        return a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                memcmp(pa.baseAddress! + ai, pb.baseAddress! + bi, length * MemoryLayout<UInt16>.stride) == 0
            }
        }
    }

    private static func occurrences(of needle: Units, in haystack: Units) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var found: [Int] = []
        for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if equal(haystack, i, needle, 0, needle.count) { found.append(i) }
        }
        return found
    }
}
