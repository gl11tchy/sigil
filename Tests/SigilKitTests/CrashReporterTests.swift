import Darwin
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
        #expect(url.lastPathComponent == CrashLog.fileName(for: now, pid: getpid()))
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
            let name = String(format: "crash-2026-01-%02d-010101-100.log", index)
            try Data("old".utf8).write(to: directory.appendingPathComponent(name))
        }

        CrashReporter.prepare(directory: directory, now: Date())
        CrashReporter.writeSignalReport(SIGSEGV)

        #expect(CrashLog.reportURLs(in: directory).count == CrashLog.keepCount)
    }

    @Test func stateRoundTripsThroughTheBuffers() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        CrashReporter.prepare(directory: directory, now: Date())

        CrashReporter.updateState("tabs open: 2\nterminal tail — sigil:\nlast line")
        #expect(CrashReporter.stateText == "tabs open: 2\nterminal tail — sigil:\nlast line")

        // The slots alternate, so a shorter snapshot must not leave the tail of
        // the longer one behind it.
        CrashReporter.updateState("shorter")
        #expect(CrashReporter.stateText == "shorter")
        CrashReporter.updateState("shorter still")
        #expect(CrashReporter.stateText == "shorter still")
    }

    @Test func updatesStopOnceACrashPathHasStarted() throws {
        let directory = try makeDirectory()
        defer {
            CrashReporter.releaseBuffers()
            try? FileManager.default.removeItem(at: directory)
        }
        CrashReporter.prepare(directory: directory, now: Date())
        CrashReporter.updateState("before the crash")

        CrashReporter.writeSignalReport(SIGSEGV)
        CrashReporter.updateState("after the crash")

        #expect(CrashReporter.stateText == "before the crash")
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

        let kept = CrashReporter.tail(bytes, limit: CrashReporter.stateCapacity)

        #expect(kept.count <= CrashReporter.stateCapacity)
        #expect(kept[0] & 0b1100_0000 != 0b1000_0000)
        let text = String(decoding: kept, as: UTF8.self)
        #expect(text.hasSuffix("あ"))
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test func shortStateIsLeftExactlyAsItIs() {
        let bytes = Array("tabs open: 1".utf8)
        #expect(CrashReporter.tail(bytes, limit: CrashReporter.stateCapacity) == bytes)
    }

    @Test func aTextTailIsBoundedInBytesNotCharacters() {
        let wide = String(repeating: "あ", count: 100)
        let kept = CrashReporter.tail(of: wide, bytes: 30)
        #expect(kept.utf8.count <= 30)
        #expect(!kept.contains("\u{FFFD}"))
        #expect(wide.hasSuffix(kept))
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
        #expect(text.contains(CrashLog.footer))
        #expect(text.contains("seconds since the epoch: 1"))
        // The signal path does not walk the stack itself; it points at the
        // report macOS writes for the same crash.
        #expect(text.contains("DiagnosticReports"))
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

    @Test func everySectionOfTheSnapshotHasItsOwnBudget() {
        // The budgets add up, so a finished snapshot never needs the
        // whole-snapshot trim, which would drop the tab list first.
        let total =
            CrashReporter.tabListCapacity + CrashReporter.terminalTailCapacity
            + CrashReporter.stateHeadingCapacity
        #expect(total == CrashReporter.stateCapacity)
        #expect(CrashReporter.tabListCapacity > 0)
    }

    @Test func aTextHeadIsBoundedInBytesWithoutSplittingACharacter() {
        let wide = String(repeating: "あ", count: 100)
        let kept = CrashReporter.head(of: wide, bytes: 31)
        #expect(kept.utf8.count <= 31)
        #expect(!kept.contains("\u{FFFD}"))
        #expect(wide.hasPrefix(kept))
        #expect(kept.count == 10)
    }

    @Test func aShortTextIsItsOwnHead() {
        #expect(CrashReporter.head(of: "tabs open: 1", bytes: 4096) == "tabs open: 1")
        #expect(CrashReporter.head(of: "anything", bytes: 0).isEmpty)
    }

    @Test func theSnapshotDescriptorRoundTrips() {
        for slot in 0...1 {
            for count in [0, 1, CrashReporter.stateCapacity] {
                let decoded = CrashReporter.decode(CrashReporter.encode(slot: slot, count: count))
                #expect(decoded.slot == slot)
                #expect(decoded.count == count)
            }
        }
    }

    @Test func bothCrashPathsUseTheSameHeadings() {
        #expect(CrashReporter.signalBanner.description.contains(CrashLog.banner))
        #expect(CrashReporter.signalStateHeading.description.contains(CrashLog.stateHeading))
        #expect(CrashReporter.signalSystemReport.description.contains(CrashLog.backtraceHeading))
        #expect(CrashReporter.signalFooter.description.contains(CrashLog.footer))
        #expect(CrashReporter.signalMissingState.description == CrashLog.missingState)
    }
}
