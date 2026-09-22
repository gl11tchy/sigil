import IOKit.pwr_mgt

/// Holds one idle-sleep request while the phone status is exactly "Phone connected".
/// PreventUserIdleSystemSleep leaves the display free to dim, and a closed lid can still sleep.
@MainActor
final class RemoteIdleSleep {
    private let hold: (String) -> UInt32?
    private let releaseClaim: (UInt32) -> Void
    private var claim: UInt32?

    init(
        hold: @escaping (String) -> UInt32? = SystemIdleSleep.hold,
        release: @escaping (UInt32) -> Void = SystemIdleSleep.release
    ) {
        self.hold = hold
        self.releaseClaim = release
    }

    func apply(status: String) {
        if status == "Phone connected" {
            guard claim == nil else { return }
            guard let identifier = hold(SystemIdleSleep.assertionType), identifier != 0 else { return }
            claim = identifier
            return
        }
        guard let identifier = claim else { return }
        claim = nil
        releaseClaim(identifier)
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
            "Sigil phone remote" as CFString,
            &identifier
        )
        guard result == kIOReturnSuccess, identifier != 0 else { return nil }
        return identifier
    }

    static func release(_ identifier: UInt32) {
        IOPMAssertionRelease(identifier)
    }
}
