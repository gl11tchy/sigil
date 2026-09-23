import Darwin
import Foundation

/// Transcript exports still running. Quitting does not stop a child process,
/// and the export task's own cleanup never runs once the app has exited.
final class TranscriptExports: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [UUID: (process: Process, temporaryOutput: URL)] = [:]

    func add(_ id: UUID, process: Process, temporaryOutput: URL) {
        lock.withLock { running[id] = (process, temporaryOutput) }
    }

    func remove(_ id: UUID) {
        _ = lock.withLock { running.removeValue(forKey: id) }
    }

    /// Quit only: stops every export child and deletes its partial file.
    func stopAll() {
        let exports = lock.withLock {
            let all = Array(running.values)
            running.removeAll()
            return all
        }
        for export in exports where export.process.isRunning { export.process.terminate() }
        let deadline = ContinuousClock.now + .milliseconds(500)
        while exports.contains(where: \.process.isRunning), ContinuousClock.now < deadline {
            usleep(20_000)
        }
        for export in exports where export.process.isRunning {
            kill(export.process.processIdentifier, SIGKILL)
        }
        for export in exports { try? FileManager.default.removeItem(at: export.temporaryOutput) }
    }
}
