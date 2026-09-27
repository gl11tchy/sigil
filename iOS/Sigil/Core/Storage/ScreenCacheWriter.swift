import Foundation

#if os(iOS)
    import UIKit
#endif

/// Encodes and writes cached screens on one serial queue, so a long session never
/// holds up the screen. Changes run in the order they were made, and a newer change
/// to a file replaces one still waiting there: an older snapshot can never land
/// after a newer one, and a burst of saves costs one write.
final class ScreenCacheWriter: @unchecked Sendable {
    private enum Change {
        case save(CachedScreen)
        case delete
    }

    /// Asked on the queue, since it may create the folder.
    private let directory: @Sendable () -> URL?
    /// Not private, so tests can hold it.
    let queue = DispatchQueue(label: "sigil.screen-cache", qos: .utility)
    private let lock = NSLock()
    /// The newest change per file that the queue has not taken yet.
    private var pending: [String: Change] = [:]
    /// Jobs on the queue that have not finished.
    private var queued = 0
    private var writes = 0

    init(directory: @escaping @Sendable () -> URL?) {
        self.directory = directory
    }

    /// Files written so far.
    var writeCount: Int { lock.withLock { writes } }

    @MainActor
    func save(_ cached: CachedScreen, for credential: PairingCredential) {
        submit(.save(cached), to: ScreenCache.fileName(for: credential))
    }

    /// Also drops a save still waiting for the file, so a forgotten Mac's screen never comes back.
    @MainActor
    func delete(for credential: PairingCredential) {
        submit(.delete, to: ScreenCache.fileName(for: credential))
    }

    /// Reads behind every change already queued, so it sees the last save. The cache
    /// comes back only if `isCurrent` still holds once it is read.
    @MainActor
    func restore(for credential: PairingCredential, if isCurrent: () -> Bool) async -> CachedScreen? {
        let name = ScreenCache.fileName(for: credential)
        let cached: CachedScreen? = await withCheckedContinuation { continuation in
            queue.async(qos: .userInitiated, flags: .enforceQoS) {
                let url = self.directory()?.appendingPathComponent(name)
                continuation.resume(returning: url.flatMap(ScreenCache.read))
            }
        }
        return isCurrent() ? cached : nil
    }

    @MainActor
    private func submit(_ change: Change, to name: String) {
        let waiting = lock.withLock {
            let waiting = pending.updateValue(change, forKey: name) != nil
            if !waiting { queued += 1 }
            return waiting
        }
        // The job already queued for this file has not started; it takes the newer change.
        guard !waiting else { return }
        holdApp()
        queue.async { self.run(name) }
    }

    private func run(_ name: String) {
        let change = lock.withLock { pending.removeValue(forKey: name) }
        if let change, let url = directory()?.appendingPathComponent(name) {
            switch change {
            case .save(let cached):
                if ScreenCache.write(cached, to: url) { lock.withLock { writes += 1 } }
            case .delete:
                try? FileManager.default.removeItem(at: url)
            }
        }
        let idle = lock.withLock {
            queued -= 1
            return queued == 0
        }
        if idle { releaseAppWhenIdle() }
    }

    /// Queued work keeps the app running: iOS suspends it soon after it leaves the
    /// screen, and the save made on the way out must reach the disk. Only the system
    /// call is iOS; the bookkeeping runs in the tests too.
    @MainActor private(set) var holdingApp = false
    #if os(iOS)
        @MainActor private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    #endif

    @MainActor private func holdApp() {
        guard !holdingApp else { return }
        #if os(iOS)
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save screen") { [weak self] in
                self?.releaseApp()
            }
            guard backgroundTask != .invalid else { return }
        #endif
        holdingApp = true
    }

    @MainActor private func releaseApp() {
        guard holdingApp else { return }
        holdingApp = false
        #if os(iOS)
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        #endif
    }

    private func releaseAppWhenIdle() {
        Task { @MainActor in
            // A change made since the queue went idle keeps the hold until it is written.
            if self.lock.withLock({ self.queued == 0 }) { self.releaseApp() }
        }
    }
}
