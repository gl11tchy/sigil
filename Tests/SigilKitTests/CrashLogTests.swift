import Foundation
import Testing

@testable import SigilKit

struct CrashLogTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-crash-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in directory: URL) throws {
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    @Test func defaultsToTheFolderMacOSReservesForAppLogs() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directory = CrashLog.directory(home: home, override: nil)
        #expect(directory.path == "/Users/someone/Library/Logs/Sigil")
    }

    @Test func overrideWinsOverTheDefault() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directory = CrashLog.directory(home: home, override: "/tmp/sigil-logs")
        #expect(directory.path == "/tmp/sigil-logs")
    }

    @Test func emptyOverrideIsIgnored() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let directory = CrashLog.directory(home: home, override: "")
        #expect(directory.path == "/Users/someone/Library/Logs/Sigil")
    }

    @Test func namesReportsWithASortableTimestampAndThePid() {
        let name = CrashLog.fileName(for: Date(timeIntervalSince1970: 1_758_245_383), pid: 4321)
        #expect(name.hasPrefix("crash-"))
        #expect(name.hasSuffix("-4321.log"))
        #expect(CrashLog.isReportName(name))
        // Two reports from the same run sort in the order they were written.
        let later = CrashLog.fileName(for: Date(timeIntervalSince1970: 1_758_245_384), pid: 4321)
        #expect(name < later)
    }

    @Test func twoRunsInTheSameSecondGetSeparateReports() {
        let moment = Date(timeIntervalSince1970: 1_758_245_383)
        #expect(CrashLog.fileName(for: moment, pid: 11) != CrashLog.fileName(for: moment, pid: 12))
    }

    @Test(arguments: [
        "crash-2026-09-19-014530-1.log",
        "crash-2026-09-19-014530-99999.log",
    ])
    func acceptsNamesItWrites(name: String) {
        #expect(CrashLog.isReportName(name))
    }

    @Test(arguments: [
        "crash-backup.log",
        "crash-.log",
        "crash-2026-09-19-014530.log",
        "crash-2026-09-19-014530-.log",
        "crash-2026-09-19-014530-abc.log",
        "crash-2026-09-19-01453-123.log",
        "crash-26-09-19-014530-123.log",
        "crash-2026-09-19-014530-123.log.bak",
        "notes.log",
        "crash-2026-09-19-014530-123-456.log",
    ])
    func rejectsAnythingElse(name: String) {
        #expect(!CrashLog.isReportName(name))
    }

    @Test func listsReportsNewestFirstAndIgnoresEverythingElse() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch("crash-2026-01-02-030405-101.log", in: directory)
        try touch("crash-2026-09-19-014530-102.log", in: directory)
        try touch("crash-2025-12-31-235959-103.log", in: directory)
        try touch("notes.txt", in: directory)
        try touch("crash-backup.log", in: directory)

        let names = CrashLog.reportURLs(in: directory).map(\.lastPathComponent)
        #expect(
            names == [
                "crash-2026-09-19-014530-102.log",
                "crash-2026-01-02-030405-101.log",
                "crash-2025-12-31-235959-103.log",
            ])
        #expect(CrashLog.mostRecentReport(in: directory)?.lastPathComponent == names.first)
    }

    @Test func aDirectoryNamedLikeAReportIsNotOne() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let impostor = directory.appendingPathComponent("crash-2026-09-19-014530-104.log")
        try FileManager.default.createDirectory(at: impostor, withIntermediateDirectories: true)

        #expect(CrashLog.reportURLs(in: directory).isEmpty)
        CrashLog.prune(in: directory, keeping: 0)
        #expect(FileManager.default.fileExists(atPath: impostor.path))
    }

    @Test func missingDirectoryHasNoReports() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-crash-absent-\(UUID().uuidString)")
        #expect(CrashLog.reportURLs(in: directory).isEmpty)
        #expect(CrashLog.mostRecentReport(in: directory) == nil)
    }

    @Test func pruneRemovesTheOldestAndLeavesOtherFilesAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for day in 1...5 {
            try touch(String(format: "crash-2026-01-%02d-010101-100.log", day), in: directory)
        }
        try touch("notes.txt", in: directory)
        try touch("crash-backup.log", in: directory)

        let removed = CrashLog.prune(in: directory, keeping: 2)
        #expect(removed.count == 3)
        let names = CrashLog.reportURLs(in: directory).map(\.lastPathComponent)
        #expect(names == ["crash-2026-01-05-010101-100.log", "crash-2026-01-04-010101-100.log"])
        let survivors = ["notes.txt", "crash-backup.log"]
        for name in survivors {
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    @Test func pruningToZeroRemovesEveryReport() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch("crash-2026-01-01-010101-100.log", in: directory)
        CrashLog.prune(in: directory, keeping: 0)
        #expect(CrashLog.reportURLs(in: directory).isEmpty)
    }

    @Test func reportCarriesTheReasonStateAndCallStack() {
        let text = CrashLog.report(
            reason: "uncaught exception NSInvalidArgumentException: unrecognised selector",
            state: "tabs open: 2\nterminal tail — sigil:\nlast line",
            callStack: ["0 Sigil 0x1 frame one", "1 Sigil 0x2 frame two"],
            date: Date(timeIntervalSince1970: 1_758_245_383)
        )
        #expect(text.contains(CrashLog.banner))
        #expect(text.contains("unrecognised selector"))
        #expect(text.contains(CrashLog.stateHeading))
        #expect(text.contains("terminal tail — sigil:"))
        #expect(text.contains(CrashLog.backtraceHeading))
        #expect(text.contains("frame two"))
        #expect(text.hasSuffix("\(CrashLog.footer)\n"))
    }

    @Test func reportSaysSoWhenThereIsNothingToReport() {
        let text = CrashLog.report(
            reason: "signal SIGSEGV", state: "", callStack: [], date: Date())
        #expect(text.contains(CrashLog.missingState))
        #expect(text.contains(CrashLog.missingBacktrace))
    }

    @Test func appendCreatesTheReportThenAddsToIt() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested").appendingPathComponent("crash.log")

        try CrashLog.append("first\n", to: url)
        try CrashLog.append("second\n", to: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "first\nsecond\n")
    }
}
