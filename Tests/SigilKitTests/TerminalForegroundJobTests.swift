import AppKit
import Foundation
import Testing

@testable import SigilKit

@Suite("Terminal foreground job", .serialized)
@MainActor
struct TerminalForegroundJobTests {

    init() {
        TerminalTestSupport.prepareAppKit()
    }

    @Test func aCommandStartedFromAJobControlShellIsAForegroundJob() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        defer { controller.terminateAndWait() }

        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: ["/bin/sh", "-c", "set -m; /bin/sleep 5; exit 0"]))

        #expect(await TerminalTestSupport.waitUntil { controller.hasForegroundJob })
    }

    @Test func aShellWithNothingInFrontHasNoForegroundJob() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        defer { controller.terminateAndWait() }
        #expect(!controller.hasForegroundJob)

        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper, extraArguments: ["/bin/sleep", "5"]))
        try await Task.sleep(for: .milliseconds(300))

        #expect(controller.isRunning)
        #expect(!controller.hasForegroundJob)
    }
}
