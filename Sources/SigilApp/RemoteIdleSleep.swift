import Foundation
import IOKit.pwr_mgt

/// One process-owned idle-sleep assertion. A deadline limits power use; it never
/// changes a session's lifecycle state or proves that its task finished.
@MainActor
final class RemoteIdleSleep {
    struct WorkingTab: Equatable, Sendable {
        let id: UUID
        let generation: UUID
        let revision: UInt64
    }

    private struct Progress {
        let work: WorkingTab
        let observedAt: TimeInterval
    }

    static let inactivityLimit: TimeInterval = 2 * 60 * 60
    static let retryDelay: TimeInterval = 30
    private let hold: (String) -> UInt32?
    private let releaseClaim: (UInt32) -> Bool
    private let clock: () -> TimeInterval
    private var claim: UInt32?
    private var progress: [UUID: Progress] = [:]
    private var retryAt: TimeInterval?
    private var releaseRetryAt: TimeInterval?
    private var reviewAt: TimeInterval?

    init(
        hold: @escaping (String) -> UInt32? = SystemIdleSleep.hold,
        release: @escaping (UInt32) -> Bool = SystemIdleSleep.release,
        clock: (() -> TimeInterval)? = nil
    ) {
        self.hold = hold
        self.releaseClaim = release
        if let clock {
            self.clock = clock
        } else {
            // Continuous time includes explicit sleep; waking does not grant an
            // old quiet turn another power-policy window.
            let origin = ContinuousClock.now
            self.clock = {
                let elapsed = origin.duration(to: ContinuousClock.now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            }
        }
    }

    /// Retains the existing status-only caller contract. Production supplies
    /// validated per-tab evidence through the richer input below.
    func apply(status: String) {
        apply(phoneConnected: status == "Phone connected", alertsArmed: false, workingTabs: [])
    }

    func apply(
        phoneConnected: Bool, alertsArmed: Bool, workingTabs: [WorkingTab], liveTabIDs: Set<UUID>? = nil
    ) {
        let now = clock()
        let ids = Set(workingTabs.map(\.id))
        // Retain an open tab's last window while evidence is temporarily lost.
        // Re-reading the same old turn must not grant another two-hour window.
        let live = liveTabIDs ?? ids
        progress = progress.filter { live.contains($0.key) }
        for tab in workingTabs where progress[tab.id]?.work != tab {
            progress[tab.id] = Progress(work: tab, observedAt: now)
        }
        // Repeated observations, quiet polls and relay reconnects do not renew
        // this policy window. Only a new validated progress revision does.
        let deadline = alertsArmed
            ? workingTabs.compactMap { progress[$0.id]?.observedAt }.map { $0 + Self.inactivityLimit }
                .filter { $0 > now }.max() : nil
        reviewAt = phoneConnected ? nil : deadline
        guard phoneConnected || deadline != nil else {
            retryAt = nil
            releaseOwnedClaim(now: now)
            return
        }
        releaseRetryAt = nil
        guard claim == nil else { return }
        if let retryAt, now < retryAt {
            reviewAt = reviewAt.map { min($0, retryAt) } ?? retryAt
            return
        }
        guard let identifier = hold(SystemIdleSleep.assertionType), identifier != 0 else {
            let retry = now + Self.retryDelay
            retryAt = retry
            reviewAt = reviewAt.map { min($0, retry) } ?? retry
            return
        }
        claim = identifier
        retryAt = nil
    }

    var nextReviewDelay: TimeInterval? {
        reviewAt.map { max(0, $0 - clock()) }
    }

    func stop() {
        progress.removeAll()
        retryAt = nil
        reviewAt = nil
        releaseRetryAt = nil
        releaseOwnedClaim(now: clock())
    }

    private func releaseOwnedClaim(now: TimeInterval) {
        guard let identifier = claim else { return }
        if let releaseRetryAt, now < releaseRetryAt {
            reviewAt = releaseRetryAt
            return
        }
        guard releaseClaim(identifier) else {
            // Keep ownership after failure so a later transition cannot create
            // a second assertion. Live watches retry without releasing others.
            releaseRetryAt = now + Self.retryDelay
            reviewAt = releaseRetryAt
            return
        }
        claim = nil
        releaseRetryAt = nil
    }
}

private enum SystemIdleSleep {
    static let assertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as String

    static func hold(_ type: String) -> UInt32? {
        guard type == assertionType else { return nil }
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sigil phone connection or working-session alerts" as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess, identifier != 0 else { return nil }
        return identifier
    }

    static func release(_ identifier: UInt32) -> Bool {
        IOPMAssertionRelease(identifier) == kIOReturnSuccess
    }
}
