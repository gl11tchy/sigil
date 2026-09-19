import Darwin
import Foundation
import SigilAtomics

/// Writes a readable report to ``CrashLog/directory`` when Sigil dies.
///
/// Two paths end up in the same file:
///
/// * An uncaught `NSException` is delivered on an ordinary thread, so that path
///   uses Foundation and records the exception, its reason, and its call stack.
/// * A fatal signal is delivered inside a signal handler, where almost nothing
///   is safe to call: no allocation, no locks, no Swift runtime machinery that
///   might take one. That path touches only `open`, `write`, `close`, `time`,
///   and `getpid`, and every byte it writes was laid out before the crash.
///
/// The signal path deliberately does not walk the stack. `backtrace` is only
/// safe while the unwinder and the dynamic loader are not themselves the thing
/// that broke, and a handler that deadlocks in there never gets to re-raise, so
/// the process hangs instead of dying and macOS never writes its own report.
/// That report already carries a symbolised backtrace for the same crash; what
/// it cannot carry is what the person was doing, so that is what this one is
/// for.
///
/// The state snapshot the app keeps current through ``updateState(_:)`` is what
/// makes a report worth reading. It lives in two buffers: the app fills the one
/// the handler is not pointed at, then publishes which buffer and how many
/// bytes through `SigilAtomics`, whose release store means a handler that sees
/// the new descriptor also sees the bytes behind it. A handler that fires
/// mid-update therefore reads the previous snapshot whole rather than a splice
/// of two.
public enum CrashReporter {

    /// Bytes reserved for each state snapshot: room for a screen of terminal
    /// output and the tab list, small enough to hold from launch to crash.
    public static let stateCapacity = 16 * 1024
    /// Bytes the terminal tail may take of that. The rest is kept for the tab
    /// list, which is trimmed away first if the tail is allowed to fill the
    /// buffer on its own.
    public static let terminalTailCapacity = 8 * 1024
    /// Bytes held back for the headings that join the two sections.
    public static let stateHeadingCapacity = 256
    /// Bytes the tab list may take. Every section has its own budget and they
    /// add up to ``stateCapacity``, so the whole-snapshot trim — which would
    /// drop the tab list first — never has to engage.
    public static var tabListCapacity: Int {
        stateCapacity - terminalTailCapacity - stateHeadingCapacity
    }
    /// Room for the largest decimal the signal path writes.
    static let numberCapacity = 24

    /// Signals that mean the process is already past saving.
    static let fatalSignals: [Int32] = [SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS]

    static let signalBanner: StaticString = "\n===== Sigil crash report =====\nsignal: "
    static let signalTimeHeading: StaticString = "\nseconds since the epoch: "
    static let signalStateHeading: StaticString = "\n--- state ---\n"
    static let signalMissingState: StaticString = "(no state recorded)"
    static let signalSystemReport: StaticString =
        "--- backtrace ---\nnot walked here; see the report macOS wrote to ~/Library/Logs/DiagnosticReports\n"
    static let signalFooter: StaticString = "===== end of report =====\n"
    static let signalNewline: StaticString = "\n"

    private nonisolated(unsafe) static var stateSlotA: UnsafeMutablePointer<UInt8>?
    private nonisolated(unsafe) static var stateSlotB: UnsafeMutablePointer<UInt8>?
    private nonisolated(unsafe) static var pathBuffer: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var numberBuffer: UnsafeMutablePointer<UInt8>?
    private nonisolated(unsafe) static var reportURL: URL?
    private nonisolated(unsafe) static var didInstallHandlers = false

    /// Reserves this run's report and takes over the fatal signals.
    ///
    /// Call this before anything else the app builds, from `AppDelegate.init`
    /// rather than `applicationDidFinishLaunching`: by the time the latter runs,
    /// the app's own stored properties have already been constructed, and a
    /// crash in one of those is exactly the kind worth having a report for.
    public static func install(now: Date = Date()) {
        guard reportURL == nil else { return }
        guard prepare(directory: CrashLog.directory, now: now) != nil else { return }
        // Touch the atomics once here so nothing in the handler is the first
        // call into anything.
        _ = sigil_load_state()
        installHandlers()
    }

    /// Replaces the snapshot a crash report will carry. Call from the main
    /// thread: the buffers have one writer by design.
    public static func updateState(_ text: String) {
        guard !sigil_is_crashing() else { return }
        let nextSlot = decode(sigil_load_state()).slot == 0 ? 1 : 0
        guard let target = slot(nextSlot) else { return }
        let bytes = tail(Array(text.utf8), limit: stateCapacity)
        bytes.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            target.update(from: base, count: source.count)
        }
        sigil_publish_state(encode(slot: nextSlot, count: bytes.count))
    }

    /// The published snapshot as text, for the paths that can afford Foundation.
    public static var stateText: String {
        let published = decode(sigil_load_state())
        guard published.count > 0, let buffer = slot(published.slot) else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: buffer, count: published.count), as: UTF8.self)
    }

    /// One slot and one byte count in one word. Plain arithmetic, so decoding
    /// is as safe inside a signal handler as loading the word was.
    static func encode(slot: Int, count: Int) -> UInt64 {
        UInt64(slot * (stateCapacity + 1) + count)
    }

    static func decode(_ value: UInt64) -> (slot: Int, count: Int) {
        let value = Int(truncatingIfNeeded: value)
        return (value / (stateCapacity + 1), value % (stateCapacity + 1))
    }

    /// Keeps the first `bytes` of `text` without splitting a character.
    public static func head(of text: String, bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        let utf8 = Array(text.utf8)
        guard utf8.count > limit else { return text }
        var end = limit
        while end > 0, utf8[end] & 0b1100_0000 == 0b1000_0000 {
            end -= 1
        }
        return String(decoding: utf8[0..<end], as: UTF8.self)
    }

    /// Keeps the last `bytes` of `text` without opening mid-character.
    public static func tail(of text: String, bytes limit: Int) -> String {
        let trimmed = tail(Array(text.utf8), limit: limit)
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Keeps the tail, and drops any continuation bytes left at the front so a
    /// snapshot never opens in the middle of a character.
    static func tail(_ bytes: [UInt8], limit: Int) -> [UInt8] {
        guard limit > 0 else { return [] }
        guard bytes.count > limit else { return bytes }
        var kept = Array(bytes.suffix(limit))
        var start = 0
        while start < kept.count, kept[start] & 0b1100_0000 == 0b1000_0000 {
            start += 1
        }
        if start > 0 {
            kept = Array(kept.dropFirst(start))
        }
        return kept
    }

    private static func slot(_ index: Int) -> UnsafeMutablePointer<UInt8>? {
        index == 0 ? stateSlotA : stateSlotB
    }

    /// Allocates every buffer the crash paths use and picks this run's report
    /// name, so neither path has to allocate or format a date once it is too
    /// late to do either. Returns the report's location.
    @discardableResult
    static func prepare(directory: URL, now: Date) -> URL? {
        releaseBuffers()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // Leave room for this run's report, so a crash never puts the folder
        // over the keep count.
        CrashLog.prune(in: directory, keeping: max(CrashLog.keepCount - 1, 0))

        let url = CrashLog.reportURL(for: now, pid: getpid(), in: directory)
        let path = Array(url.path.utf8CString)
        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: path.count)
        pathPointer.initialize(from: path, count: path.count)
        pathBuffer = pathPointer

        stateSlotA = makeStateSlot()
        stateSlotB = makeStateSlot()
        sigil_reset_state()

        let number = UnsafeMutablePointer<UInt8>.allocate(capacity: numberCapacity)
        number.initialize(repeating: 0, count: numberCapacity)
        numberBuffer = number

        reportURL = url
        return url
    }

    private static func makeStateSlot() -> UnsafeMutablePointer<UInt8> {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: stateCapacity)
        buffer.initialize(repeating: 0, count: stateCapacity)
        return buffer
    }

    /// Undoes ``prepare(directory:now:)``. The app never calls this — its
    /// buffers are meant to outlive everything else, and freeing them while a
    /// handler is installed would leave that handler holding dangling pointers
    /// — but a test that prepares into a temporary folder has to give them back.
    static func releaseBuffers() {
        stateSlotA?.deallocate()
        stateSlotA = nil
        stateSlotB?.deallocate()
        stateSlotB = nil
        sigil_reset_state()
        pathBuffer?.deallocate()
        pathBuffer = nil
        numberBuffer?.deallocate()
        numberBuffer = nil
        reportURL = nil
    }

    private static func installHandlers() {
        guard !didInstallHandlers else { return }
        didInstallHandlers = true
        NSSetUncaughtExceptionHandler(reportUncaughtException)
        installAlternateStack()
        var action = sigaction()
        action.__sigaction_u.__sa_handler = reportFatalSignal
        sigemptyset(&action.sa_mask)
        // SA_ONSTACK so a stack-exhaustion SIGSEGV is handled off the exhausted
        // stack; SA_RESETHAND so the re-raise below reaches the default handler.
        action.sa_flags = SA_ONSTACK | SA_RESETHAND
        for number in fatalSignals {
            sigaction(number, &action, nil)
        }
    }

    /// A stack for the handler to run on when the thread's own is exhausted.
    /// This covers the main thread, which is the one a runaway recursion in the
    /// UI will overflow; a signal on another thread still lands on that
    /// thread's stack, since an alternate stack is per-thread.
    private static func installAlternateStack() {
        let size = max(Int(SIGSTKSZ), 64 * 1024)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var stack = stack_t(ss_sp: memory, ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)
    }

    static func writeExceptionReport(_ exception: NSException) {
        sigil_set_crashing()
        guard let url = reportURL else { return }
        let name = exception.name.rawValue
        let reason = exception.reason ?? "no reason given"
        let text = CrashLog.report(
            reason: "uncaught exception \(name): \(reason)",
            state: stateText,
            callStack: exception.callStackSymbols,
            date: Date()
        )
        try? CrashLog.append(text, to: url)
    }

    /// The signal-handler path. Every call below is async-signal-safe, and the
    /// bytes all come from buffers ``prepare(directory:now:)`` already filled.
    static func writeSignalReport(_ number: Int32) {
        sigil_set_crashing()
        guard let path = pathBuffer else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        emit(descriptor, signalBanner)
        emit(descriptor, name(of: number))
        emit(descriptor, signalTimeHeading)
        emit(descriptor, decimal: Int(time(nil)))
        emit(descriptor, signalStateHeading)
        writeState(descriptor)
        emit(descriptor, signalSystemReport)
        emit(descriptor, signalFooter)
        close(descriptor)
    }

    private static func writeState(_ descriptor: Int32) {
        let published = decode(sigil_load_state())
        let count = published.count
        guard count > 0, let buffer = slot(published.slot) else {
            emit(descriptor, signalMissingState)
            emit(descriptor, signalNewline)
            return
        }
        _ = Darwin.write(descriptor, buffer, count)
        emit(descriptor, signalNewline)
    }

    private static func emit(_ descriptor: Int32, _ text: StaticString) {
        text.withUTF8Buffer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, base, buffer.count)
        }
    }

    /// Writes an integer without `snprintf`, which may take a lock.
    private static func emit(_ descriptor: Int32, decimal value: Int) {
        guard let buffer = numberBuffer else { return }
        var remaining = value < 0 ? 0 - value : value
        var index = numberCapacity
        repeat {
            index -= 1
            buffer[index] = UInt8(48 + remaining % 10)
            remaining /= 10
        } while remaining > 0 && index > 0
        if value < 0 && index > 0 {
            index -= 1
            buffer[index] = 45
        }
        _ = Darwin.write(descriptor, buffer + index, numberCapacity - index)
    }

    /// `strsignal` allocates, so the names are spelled out here instead.
    private static func name(of number: Int32) -> StaticString {
        switch number {
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGABRT: return "SIGABRT"
        case SIGFPE: return "SIGFPE"
        case SIGBUS: return "SIGBUS"
        case SIGSEGV: return "SIGSEGV"
        case SIGSYS: return "SIGSYS"
        default: return "unknown"
        }
    }
}

/// Delivered on an ordinary thread, so this path may use Foundation.
private func reportUncaughtException(_ exception: NSException) {
    CrashReporter.writeExceptionReport(exception)
}

/// Delivered inside a signal handler. Write the report, then re-raise: the
/// handler was installed with `SA_RESETHAND`, so the default one is already
/// back and the process dies the way it would have, leaving macOS to write its
/// own report next to ours.
private func reportFatalSignal(_ number: Int32) {
    CrashReporter.writeSignalReport(number)
    raise(number)
}
