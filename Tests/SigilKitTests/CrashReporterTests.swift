import Foundation
import Testing

@testable import SigilKit

/// The reporter keeps one set of buffers for the whole process, so these tests
/// take turns with them rather than running side by side.
@Suite(.serialized)
struct CrashReporterTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigil-crash-reporter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func prepareCreatesTheFolderAndReservesOneReportPerRun() throws {
        let root = try makeDirectory()
        let directory = root.appendingPathComponent("Logs/Sigil")
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: root)
        }
        let now = Date(timeIntervalSince1970: 1_758_245_383)

        let url = try #require(CrashReporter.prepare(directory: directory, now: now))

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(url.lastPathComponent == CrashLog.fileName(for: now))
        // Reserving a name does not write anything: an app that never crashes
        // leaves no reports behind.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func prepareLeavesRoomForThisRunsReport() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        for index in 1...(CrashLog.keepCount + 4) {
            let name = String(format: "crash-2026-01-%02d-010101.log", index)
            try Data("old".utf8).write(to: directory.appendingPathComponent(name))
        }

        CrashReporter.prepare(directory: directory, now: Date())
        CrashReporter.writeSignalReport(SIGSEGV)

        #expect(CrashLog.reportURLs(in: directory).count == CrashLog.keepCount)
    }

    @Test func stateRoundTripsThroughTheBuffer() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        CrashReporter.prepare(directory: directory, now: Date())

        CrashReporter.updateState("tabs open: 2\nterminal tail — sigil:\nlast line")
        #expect(CrashReporter.stateText == "tabs open: 2\nterminal tail — sigil:\nlast line")

        CrashReporter.updateState("shorter")
        #expect(CrashReporter.stateText == "shorter")
    }

    @Test func stateIsIgnoredBeforeThereIsAnywhereToKeepIt() {
        CrashReporter.releaseBuffers()
        CrashReporter.updateState("dropped")
        #expect(CrashReporter.stateText.isEmpty)
    }

    @Test func oversizedStateKeepsTheTailAndStaysValidText() {
        // Three bytes per character against a capacity that is not a multiple
        // of three: the cut lands inside a character, which is the case the
        // trim exists for.
        let filler = String(repeating: "あ", count: CrashReporter.stateCapacity)
        let bytes = Array(filler.utf8)
        #expect(bytes.count > CrashReporter.stateCapacity)
        #expect(bytes[bytes.count - CrashReporter.stateCapacity] & 0b1100_0000 == 0b1000_0000)

        let trimmed = CrashReporter.trimmedToCapacity(bytes)

        #expect(trimmed.count <= CrashReporter.stateCapacity)
        #expect(trimmed[0] & 0b1100_0000 != 0b1000_0000)
        let text = String(decoding: trimmed, as: UTF8.self)
        #expect(text.hasSuffix("あ"))
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test func shortStateIsLeftExactlyAsItIs() {
        let bytes = Array("tabs open: 1".utf8)
        #expect(CrashReporter.trimmedToCapacity(bytes) == bytes)
    }

    @Test func signalReportNamesTheSignalAndCarriesTheState() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        let now = Date(timeIntervalSince1970: 1_758_245_383)
        let url = try #require(CrashReporter.prepare(directory: directory, now: now))
        CrashReporter.updateState("tabs open: 1\nterminal tail — sigil:\nbuilding…")

        CrashReporter.writeSignalReport(SIGSEGV)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(CrashLog.banner))
        #expect(text.contains("signal: SIGSEGV"))
        #expect(text.contains("terminal tail — sigil:"))
        #expect(text.contains("building…"))
        #expect(text.contains(CrashLog.backtraceHeading))
        #expect(text.contains(CrashLog.footer))
        #expect(text.contains("seconds since the epoch: 1"))
    }

    @Test func signalReportSaysSoWhenNothingWasRecorded() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try #require(CrashReporter.prepare(directory: directory, now: Date()))

        CrashReporter.writeSignalReport(SIGABRT)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("signal: SIGABRT"))
        #expect(text.contains(CrashLog.missingState))
    }

    @Test func aSecondSignalAppendsRatherThanReplacing() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try #require(CrashReporter.prepare(directory: directory, now: Date()))

        CrashReporter.writeSignalReport(SIGBUS)
        CrashReporter.writeSignalReport(SIGILL)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("signal: SIGBUS"))
        #expect(text.contains("signal: SIGILL"))
    }

    @Test func anUnknownSignalStillProducesAReport() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try #require(CrashReporter.prepare(directory: directory, now: Date()))

        CrashReporter.writeSignalReport(SIGUSR1)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("signal: unknown"))
    }

    @Test func exceptionReportCarriesTheReasonAndTheState() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        let url = try #require(CrashReporter.prepare(directory: directory, now: Date()))
        CrashReporter.updateState("tabs open: 3")

        CrashReporter.writeExceptionReport(
            NSException(name: .invalidArgumentException, reason: "unrecognised selector", userInfo: nil))

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("uncaught exception NSInvalidArgumentException"))
        #expect(text.contains("unrecognised selector"))
        #expect(text.contains("tabs open: 3"))
    }

    @Test func nothingIsWrittenBeforeAReportIsReserved() {
        CrashReporter.releaseBuffers()
        // Both paths return without a report to write to, rather than trapping.
        CrashReporter.writeSignalReport(SIGSEGV)
        CrashReporter.writeExceptionReport(
            NSException(name: .genericException, reason: "boom", userInfo: nil))
    }

    @Test func bothCrashPathsUseTheSameHeadings() {
        #expect(CrashReporter.signalBanner.description.contains(CrashLog.banner))
        #expect(CrashReporter.signalStateHeading.description.contains(CrashLog.stateHeading))
        #expect(CrashReporter.signalBacktraceHeading.description.contains(CrashLog.backtraceHeading))
        #expect(CrashReporter.signalFooter.description.contains(CrashLog.footer))
        #expect(CrashReporter.signalMissingState.description == CrashLog.missingState)
    }
}
