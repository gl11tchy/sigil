import AppKit
import Foundation
import Testing

@testable import SigilKit

/// Tabs are independent `TerminalController`s. These cover the invariant the tab
/// strip relies on: two sessions run at once without touching each other.
@Suite("TerminalConcurrency", .serialized)
@MainActor
struct TerminalConcurrencyTests {

    init() { TerminalTestSupport.prepareAppKit() }

    @Test func twoControllersRunIndependently() async throws {
        let first = TerminalController()
        let second = TerminalController()

        let markerA = "TAB_A_\(UUID().uuidString.prefix(6))"
        let markerB = "TAB_B_\(UUID().uuidString.prefix(6))"
        first.start(
            TerminalTestSupport.launchSpec(
                executable: URL(fileURLWithPath: "/bin/echo"), extraArguments: [markerA]))
        second.start(
            TerminalTestSupport.launchSpec(
                executable: URL(fileURLWithPath: "/bin/echo"), extraArguments: [markerB]))

        #expect(first.processID != second.processID)

        let sawA = await TerminalTestSupport.waitUntil { first.bufferText().contains(markerA) }
        let sawB = await TerminalTestSupport.waitUntil { second.bufferText().contains(markerB) }
        #expect(sawA)
        #expect(sawB)
        // Neither session may show the other's output.
        #expect(!first.bufferText().contains(markerB))
        #expect(!second.bufferText().contains(markerA))
    }

    @Test func closingOneTabLeavesTheOtherRunning() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let closed = TerminalController()
        let kept = TerminalController()

        closed.start(
            TerminalTestSupport.launchSpec(
                executable: helper, extraArguments: ["/bin/sh", "-c", "sleep 30"]))
        kept.start(
            TerminalTestSupport.launchSpec(
                executable: helper, extraArguments: ["/bin/sh", "-c", "sleep 30"]))

        let keptPid = kept.processID
        #expect(closed.processID > 0)
        #expect(keptPid > 0)

        closed.terminate()
        let closedGone = await TerminalTestSupport.waitUntil(timeout: .seconds(3)) {
            !closed.isRunning
        }

        #expect(closedGone)
        #expect(kept.isRunning)
        #expect(TerminalTestSupport.processIsAlive(keptPid))

        kept.terminateAndWait()
        #expect(!TerminalTestSupport.processIsAlive(keptPid))
    }
}
