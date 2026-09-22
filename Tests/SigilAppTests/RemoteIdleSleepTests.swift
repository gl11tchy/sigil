import Testing

@testable import SigilApp

struct RemoteIdleSleepTests {
    @Test @MainActor func freshSleepDoesNotHoldBecauseTheAppIsOpen() {
        let record = IdleSleepRecord()
        _ = RemoteIdleSleep(hold: record.hold, release: record.release)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test @MainActor func offDoesNotCreateAnAssertion() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Off")
        #expect(record.attempts == 0)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test(arguments: [
        "Waiting for phone",
        "Connecting…",
        "Phone disconnected",
        "Scan to connect",
        "Reconnecting…",
        "phone connected",
        "Phone connected ",
        "",
    ])
    @MainActor
    func statusOtherThanPhoneConnectedDoesNotHold(status: String) {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: status)
        #expect(record.attempts == 0)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test @MainActor func phoneConnectedHoldsPreventUserIdleSystemSleepOnce() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Phone connected")
        #expect(record.created == ["PreventUserIdleSystemSleep"])
        #expect(record.released.isEmpty)
    }

    @Test(arguments: [
        "Off",
        "Waiting for phone",
        "Connecting…",
        "Phone disconnected",
        "Scan to connect",
        "Reconnecting…",
        "phone connected",
        "Phone connected ",
        "",
    ])
    @MainActor
    func leavingPhoneConnectedReleasesTheAssertion(status: String) {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: status)
        sleep.apply(status: status)
        #expect(record.created == ["PreventUserIdleSystemSleep"])
        #expect(record.released == record.createdIDs)
    }

    @Test @MainActor func connectingAgainAfterReleaseHoldsANewAssertion() {
        let record = IdleSleepRecord()
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Off")
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Phone disconnected")
        #expect(record.created == ["PreventUserIdleSystemSleep", "PreventUserIdleSystemSleep"])
        #expect(record.released == record.createdIDs)
    }

    @Test @MainActor func failedHoldIsNotReleased() {
        let record = IdleSleepRecord()
        record.failCreates = true
        let sleep = RemoteIdleSleep(hold: record.hold, release: record.release)
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Off")
        #expect(record.attempts == 1)
        #expect(record.created.isEmpty)
        #expect(record.released.isEmpty)
    }

    @Test @MainActor func zeroIdentifierIsNotAClaim() {
        var releases = 0
        let sleep = RemoteIdleSleep(hold: { _ in 0 }, release: { _ in releases += 1 })
        sleep.apply(status: "Phone connected")
        sleep.apply(status: "Off")
        #expect(releases == 0)
    }
}

@MainActor
private final class IdleSleepRecord {
    private(set) var created: [String] = []
    private(set) var createdIDs: [UInt32] = []
    private(set) var released: [UInt32] = []
    private(set) var attempts = 0
    var failCreates = false
    private var nextID: UInt32 = 1

    func hold(_ type: String) -> UInt32? {
        attempts += 1
        guard !failCreates else { return nil }
        let id = nextID
        nextID += 1
        created.append(type)
        createdIDs.append(id)
        return id
    }

    func release(_ identifier: UInt32) {
        released.append(identifier)
    }
}
