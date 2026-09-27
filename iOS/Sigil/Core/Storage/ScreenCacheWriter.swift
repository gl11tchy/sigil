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

    /// Asked on the queue, since it may create the folder; `hasCache` asks it once at launch.
    private let directory: @Sendable () -> URL?
    /// Not private, so tests can hold it.
    let queue = DispatchQueue(label: "sigil.screen-cache", qos: .utility)
    private let lock = NSLock()
    /// The newest change per file that the queue has not taken yet.
    private var pending: [String: Change] = [:]
    /// Jobs on the queue that have not finished.
    private var queued = 0
    private var writes = 0
    /// Each Mac's last terminal ground, beside its file, so launch can read it at once.
    private let grounds: UserDefaults

    init(directory: @escaping @Sendable () -> URL?, grounds: UserDefaults = .standard) {
        self.directory = directory
        self.grounds = grounds
    }

    /// Files written so far.
    var writeCount: Int { lock.withLock { writes } }

    @MainActor
    func save(_ cached: CachedScreen, for credential: PairingCredential) {
        let name = ScreenCache.fileName(for: credential)
        remember(ground: cached.selectedTabID.flatMap { cached.screens[$0]?.background } ?? "", for: name)
        submit(.save(cached), to: name)
    }

    /// Also drops a save still waiting for the file, so a forgotten Mac's screen never comes back.
    @MainActor
    func delete(for credential: PairingCredential) {
        let name = ScreenCache.fileName(for: credential)
        remember(ground: "", for: name)
        submit(.delete, to: name)
    }

    /// The terminal ground of the screen last saved for the Mac, as `RRGGBB`; empty
    /// when none. One defaults read, so launch has it before the file is read.
    func ground(for credential: PairingCredential) -> String {
        grounds.string(forKey: Self.groundKey(ScreenCache.fileName(for: credential))) ?? ""
    }

    /// Written only when it changes: a save costs one defaults read.
    @MainActor
    private func remember(ground: String, for name: String) {
        let key = Self.groundKey(name)
        guard (grounds.string(forKey: key) ?? "") != ground else { return }
        if ground.isEmpty { grounds.removeObject(forKey: key) } else { grounds.set(ground, forKey: key) }
    }

    private static func groundKey(_ name: String) -> String { "ScreenGround." + name }

    /// Starts reading at once, behind every change already queued, so it sees the
    /// last save. `done` gets the cache, or nil, on the queue.
    func read(for credential: PairingCredential, done: @escaping @Sendable (CachedScreen?) -> Void) {
        let name = ScreenCache.fileName(for: credential)
        queue.async(qos: .userInitiated, flags: .enforceQoS) {
            done(self.directory().flatMap { ScreenCache.read($0.appendingPathComponent(name)) })
        }
    }

    /// Reads as `read` does. The cache comes back only if `isCurrent` still holds once it is read.
    @MainActor
    func restore(for credential: PairingCredential, if isCurrent: () -> Bool) async -> CachedScreen? {
        let cached = await withCheckedContinuation { continuation in
            read(for: credential) { continuation.resume(returning: $0) }
        }
        return isCurrent() ? cached : nil
    }

    /// True when a cache for the Mac is on disk or waiting to be written there. Cheap
    /// enough to ask at launch: a look at the waiting changes and one file check.
    func hasCache(for credential: PairingCredential) -> Bool {
        let name = ScreenCache.fileName(for: credential)
        switch lock.withLock({ pending[name] }) {
        case .save?: return true
        case .delete?: return false
        case nil:
            guard let url = directory()?.appendingPathComponent(name) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
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
