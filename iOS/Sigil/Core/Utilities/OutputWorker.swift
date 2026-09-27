import Foundation

/// What the output is built from, copied off the store so another thread can build it.
struct OutputSnapshot {
    /// Rows from a Mac that streams them; when set, `history` is not used.
    var screen: ScreenModel?
    /// Text from a Mac that only answers polls.
    var history: TerminalHistory?
    var raw: Bool

    /// Every row as the Mac drew it in raw mode, the formatter's lines otherwise.
    func render(with formatter: ReadableOutput) -> StyledText {
        if let screen {
            let prepared = StyledOutput.prepare(screen.lines)
            if raw { return StyledOutput.raw(prepared) }
            return StyledOutput.readable(formatter.format(ScreenModel.text(of: prepared.lines)), screen: prepared)
        }
        let text = history?.text ?? ""
        return StyledText(text: raw ? text : formatter.format(text), spans: [])
    }
}

/// Builds the output off the main thread, one snapshot at a time, in order. The
/// worker makes and keeps its own formatter, so that JavaScript context is only
/// ever used on the worker's queue. A snapshot that a newer one replaced before
/// its turn is skipped.
final class OutputWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sigil.output", qos: .userInitiated)
    private let lock = NSLock()
    /// The newest generation submitted. Guarded by `lock`.
    private var latest = Int.min
    private let makeFormatter: @Sendable () -> ReadableOutput
    /// Made and used on `queue` only.
    private var formatter: ReadableOutput?

    init(formatter: @escaping @Sendable () -> ReadableOutput) {
        makeFormatter = formatter
    }

    /// Calls `done` on the worker's queue with the output, or with nil when a newer
    /// generation came in before this one's turn. Generations must go up.
    func submit(_ snapshot: OutputSnapshot, generation: Int, done: @escaping @Sendable (StyledText?) -> Void) {
        lock.withLock { latest = max(latest, generation) }
        queue.async {
            guard self.lock.withLock({ self.latest }) == generation else { return done(nil) }
            let formatter = self.formatter ?? self.makeFormatter()
            self.formatter = formatter
            done(snapshot.render(with: formatter))
        }
    }

    func render(_ snapshot: OutputSnapshot, generation: Int) async -> StyledText? {
        await withCheckedContinuation { continuation in
            submit(snapshot, generation: generation) { continuation.resume(returning: $0) }
        }
    }
}
