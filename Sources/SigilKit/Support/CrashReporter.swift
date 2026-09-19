import Darwin
import Foundation

/// Writes a readable report to ``CrashLog/directory`` when Sigil dies.
///
/// Two paths end up in the same file:
///
/// * An uncaught `NSException` is delivered on an ordinary thread, so that path
///   uses Foundation and records the exception, its reason, and its call stack.
/// * A fatal signal is delivered inside a signal handler, where almost nothing
///   is safe to call: no allocation, no locks, no Swift runtime machinery that
///   might take one. That path touches only `open`, `write`, `close`, `time`,
///   `backtrace`, and `backtrace_symbols_fd`, and every buffer it writes from
///   was allocated at launch.
///
/// Both carry the state snapshot the app keeps current through
/// ``updateState(_:)``, which is what makes a report worth reading: a backtrace
/// alone rarely says what the user was doing.
public enum CrashReporter {

    /// Bytes reserved for the state snapshot: room for a screen of terminal
    /// output and the tab list, small enough to hold from launch to crash.
    static let stateCapacity = 16 * 1024
    /// Backtrace depth. Deeper than this and the top frames still say enough.
    static let frameCapacity = 128
    /// Room for the largest decimal the signal path writes.
    static let numberCapacity = 24

    /// Signals that mean the process is already past saving.
    static let fatalSignals: [Int32] = [SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS]

    static let signalBanner: StaticString = "\n===== Sigil crash report =====\nsignal: "
    static let signalTimeHeading: StaticString = "\nseconds since the epoch: "
    static let signalStateHeading: StaticString = "\n--- state ---\n"
    static let signalMissingState: StaticString = "(no state recorded)"
    static let signalBacktraceHeading: StaticString = "\n--- backtrace ---\n"
    static let signalFooter: StaticString = "===== end of report =====\n"
    static let signalNewline: StaticString = "\n"

    private nonisolated(unsafe) static var stateBuffer: UnsafeMutablePointer<UInt8>?
    private nonisolated(unsafe) static var stateCount = 0
    private nonisolated(unsafe) static var pathBuffer: UnsafeMutablePointer<CChar>?
    private nonisolated(unsafe) static var numberBuffer: UnsafeMutablePointer<UInt8>?
    private nonisolated(unsafe) static var frameBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    private nonisolated(unsafe) static var reportURL: URL?
    private nonisolated(unsafe) static var didInstallHandlers = false

    /// Reserves this run's report and takes over the fatal signals. Call once,
    /// as early in launch as there is a main thread to call it from.
    public static func install(now: Date = Date()) {
        guard reportURL == nil else { return }
        guard prepare(directory: CrashLog.directory, now: now) != nil else { return }
        installHandlers()
    }

    /// Replaces the snapshot a crash report will carry.
    ///
    /// Call this from the main thread only. One writer is the whole reason the
    /// signal handler can read the buffer without taking a lock it is not
    /// allowed to take.
    public static func updateState(_ text: String) {
        guard let buffer = stateBuffer else { return }
        let bytes = trimmedToCapacity(Array(text.utf8))
        // Zero the count first. A crash partway through the copy then writes no
        // state rather than half of one snapshot spliced onto half of another.
        stateCount = 0
        bytes.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            buffer.update(from: base, count: source.count)
        }
        stateCount = bytes.count
    }

    /// The snapshot as text, for the paths that can afford Foundation.
    public static var stateText: String {
        guard let buffer = stateBuffer else { return "" }
        let count = min(max(stateCount, 0), stateCapacity)
        guard count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: count), as: UTF8.self)
    }

    /// Keeps the tail, and drops any continuation bytes left at the front so the
    /// snapshot never opens mid-character.
    static func trimmedToCapacity(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count > stateCapacity else { return bytes }
        var tail = Array(bytes.suffix(stateCapacity))
        var start = 0
        while start < tail.count, tail[start] & 0b1100_0000 == 0b1000_0000 {
            start += 1
        }
        if start > 0 {
            tail = Array(tail.dropFirst(start))
        }
        return tail
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

        let path = Array(directory.appendingPathComponent(CrashLog.fileName(for: now)).path.utf8CString)
        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: path.count)
        pathPointer.initialize(from: path, count: path.count)
        pathBuffer = pathPointer

        let state = UnsafeMutablePointer<UInt8>.allocate(capacity: stateCapacity)
        state.initialize(repeating: 0, count: stateCapacity)
        stateBuffer = state
        stateCount = 0

        let number = UnsafeMutablePointer<UInt8>.allocate(capacity: numberCapacity)
        number.initialize(repeating: 0, count: numberCapacity)
        numberBuffer = number

        let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: frameCapacity)
        frames.initialize(repeating: nil, count: frameCapacity)
        frameBuffer = frames

        let url = CrashLog.reportURL(for: now, in: directory)
        reportURL = url
        return url
    }

    /// Undoes ``prepare(directory:now:)``. The app never calls this — its
    /// buffers are meant to outlive everything else — but a test that prepares
    /// into a temporary folder has to give them back.
    static func releaseBuffers() {
        stateBuffer?.deallocate()
        stateBuffer = nil
        stateCount = 0
        pathBuffer?.deallocate()
        pathBuffer = nil
        numberBuffer?.deallocate()
        numberBuffer = nil
        frameBuffer?.deallocate()
        frameBuffer = nil
        reportURL = nil
    }

    private static func installHandlers() {
        guard !didInstallHandlers else { return }
        didInstallHandlers = true
        NSSetUncaughtExceptionHandler(reportUncaughtException)
        for number in fatalSignals {
            _ = Darwin.signal(number, reportFatalSignal)
        }
    }

    static func writeExceptionReport(_ exception: NSException) {
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
        guard let path = pathBuffer else { return }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        emit(descriptor, signalBanner)
        emit(descriptor, name(of: number))
        emit(descriptor, signalTimeHeading)
        emit(descriptor, decimal: Int(time(nil)))
        emit(descriptor, signalStateHeading)
        writeState(descriptor)
        emit(descriptor, signalBacktraceHeading)
        if let frames = frameBuffer {
            let depth = backtrace(frames, Int32(frameCapacity))
            backtrace_symbols_fd(frames, depth, descriptor)
        }
        emit(descriptor, signalFooter)
        close(descriptor)
    }

    private static func writeState(_ descriptor: Int32) {
        guard let buffer = stateBuffer else { return }
        let count = min(max(stateCount, 0), stateCapacity)
        if count > 0 {
            _ = Darwin.write(descriptor, buffer, count)
            emit(descriptor, signalNewline)
        } else {
            emit(descriptor, signalMissingState)
            emit(descriptor, signalNewline)
        }
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

/// Delivered inside a signal handler. Write the report, then put the default
/// handler back and re-raise, so the process still dies the way it would have
/// and macOS still writes its own report next to ours.
private func reportFatalSignal(_ number: Int32) {
    CrashReporter.writeSignalReport(number)
    _ = Darwin.signal(number, SIG_DFL)
    raise(number)
}
