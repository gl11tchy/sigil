import Foundation

/// Where Sigil writes what it knew when it died, how those reports are named,
/// and how many of them are kept.
///
/// Everything here runs in an ordinary context and may use Foundation freely.
/// The parts that have to run inside a signal handler live in ``CrashReporter``.
public enum CrashLog {

    /// Reports kept on disk. Preparing a new one deletes the oldest beyond this.
    public static let keepCount = 10

    /// Fixed affixes so ``reportURLs(in:)`` recognises its own files and leaves
    /// anything else in the folder alone.
    static let filePrefix = "crash-"
    static let fileSuffix = ".log"

    static let banner = "===== Sigil crash report ====="
    static let stateHeading = "--- state ---"
    static let backtraceHeading = "--- backtrace ---"
    static let footer = "===== end of report ====="
    static let missingState = "(no state recorded)"
    static let missingBacktrace = "(no call stack)"

    /// `~/Library/Logs/Sigil`, the folder macOS already reserves for an app's
    /// own logs, so Console shows the reports alongside the system's.
    public static var directory: URL {
        directory(
            home: FileManager.default.homeDirectoryForCurrentUser,
            override: ProcessInfo.processInfo.environment["SIGIL_CRASH_LOG_DIR"]
        )
    }

    /// `SIGIL_CRASH_LOG_DIR` wins when it is set, which keeps tests and the
    /// launch smoke check out of a real user's logs.
    static func directory(home: URL, override: String?) -> URL {
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return home.appendingPathComponent("Library/Logs/Sigil", isDirectory: true)
    }

    /// One report per run, named for when the run started rather than when it
    /// ended. A process crashes at most once, and a launch-time name can be
    /// worked out while a date formatter is still safe to call — inside a
    /// signal handler it is not.
    ///
    /// The process id is in the name because the timestamp alone is not unique:
    /// two copies launched in the same second, or a crash-on-launch relaunched
    /// immediately, would otherwise append into one file and read as one run.
    public static func fileName(for date: Date, pid: Int32) -> String {
        "\(filePrefix)\(timestampFormatter.string(from: date))-\(pid)\(fileSuffix)"
    }

    public static func reportURL(for date: Date, pid: Int32, in directory: URL) -> URL {
        directory.appendingPathComponent(fileName(for: date, pid: pid))
    }

    /// Existing reports, newest first. The timestamp in the name sorts
    /// chronologically, so the names alone give the order; two runs from the
    /// same second sort against each other by process id, which is arbitrary
    /// but never mixes up two different seconds.
    public static func reportURLs(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let reports = names.filter(isReportName).sorted(by: >)
        return reports.map { directory.appendingPathComponent($0) }.filter(isRegularFile)
    }

    /// Exactly the shape ``fileName(for:pid:)`` produces, and nothing else.
    /// The affixes alone are not enough: something like `crash-backup.log`
    /// carries both, and pruning would delete a file this never wrote.
    static func isReportName(_ name: String) -> Bool {
        guard name.hasPrefix(filePrefix), name.hasSuffix(fileSuffix) else { return false }
        let middle = name.dropFirst(filePrefix.count).dropLast(fileSuffix.count)
        let parts = middle.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        for (part, width) in zip(parts, [4, 2, 2, 6]) where !isDigits(part, count: width) {
            return false
        }
        return isDigits(parts[4])
    }

    private static func isDigits(_ text: Substring, count: Int? = nil) -> Bool {
        if let count, text.count != count { return false }
        return !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A directory that happens to be named like a report is not one, and is
    /// never what ``prune(in:keeping:)`` should be removing.
    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    public static func mostRecentReport(in directory: URL) -> URL? {
        reportURLs(in: directory).first
    }

    /// Deletes the oldest reports beyond `limit` and returns what it removed.
    @discardableResult
    public static func prune(in directory: URL, keeping limit: Int = keepCount) -> [URL] {
        guard limit >= 0 else { return [] }
        let removed = Array(reportURLs(in: directory).dropFirst(limit))
        for url in removed {
            try? FileManager.default.removeItem(at: url)
        }
        return removed
    }

    /// The text of a report written from an ordinary context — an uncaught
    /// exception, not a signal. ``CrashReporter`` lays out the signal version
    /// byte by byte, using the same headings so both read the same way.
    public static func report(reason: String, state: String, callStack: [String], date: Date) -> String {
        var text = "\n\(banner)\n"
        text += "reason: \(reason)\n"
        text += "date: \(readableFormatter.string(from: date))\n"
        text += "\(stateHeading)\n"
        text += state.isEmpty ? "\(missingState)\n" : "\(state)\n"
        text += "\(backtraceHeading)\n"
        text += callStack.isEmpty ? "\(missingBacktrace)\n" : callStack.joined(separator: "\n") + "\n"
        text += "\(footer)\n"
        return text
    }

    /// Appends to the run's report, creating it and its folder when the crash
    /// is the first thing to write there.
    public static func append(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let readableFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()
}
