import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing

@testable import GrokBuildKit

@Suite("TerminalController", .serialized)
@MainActor
struct TerminalControllerTests {

    init() {
        TerminalTestSupport.prepareAppKit()
    }

    @Test func ptyEchoesTextAndReportsExitZero() async {
        let controller = TerminalController()
        var exitCode: Int32?
        var didExit = false
        controller.onTerminate = { code in
            exitCode = code
            didExit = true
        }

        let marker = "PTY_OK_\(UUID().uuidString.prefix(8))"
        controller.start(
            TerminalTestSupport.launchSpec(
                executable: URL(fileURLWithPath: "/bin/echo"),
                extraArguments: [marker]
            )
        )

        let sawText = await TerminalTestSupport.waitUntil {
            controller.bufferText().contains(marker)
        }
        let sawExit = await TerminalTestSupport.waitUntil { didExit }

        #expect(sawText)
        #expect(sawExit)
        #expect(exitCode == 0)
        #expect(!controller.isRunning)
        #expect(controller.view is LocalProcessTerminalView)
    }

    @Test func terminateKillsProcessGroupPromptly() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        var didExit = false
        controller.onTerminate = { _ in didExit = true }

        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: ["/bin/sh", "-c", "sleep 30"]
            )
        )
        #expect(controller.isRunning)

        let pid = controller.processID
        #expect(pid > 0)
        #expect(TerminalTestSupport.processIsAlive(pid))

        controller.terminate()
        controller.terminate()

        let sawExit = await TerminalTestSupport.waitUntil(timeout: .seconds(2)) { didExit }
        let groupGone = await TerminalTestSupport.waitUntil(timeout: .seconds(2)) {
            !TerminalTestSupport.processIsAlive(pid)
                && TerminalTestSupport.processGroupMembers(pid).isEmpty
        }

        #expect(sawExit)
        #expect(!controller.isRunning)
        #expect(groupGone)
        #expect(!TerminalTestSupport.processIsAlive(pid))
        #expect(TerminalTestSupport.processGroupMembers(pid).isEmpty)
    }

    @Test func startTwiceDoesNotSpawnASecondProcess() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: ["/bin/sh", "-c", "sleep 30"]
            )
        )
        #expect(controller.isRunning)
        let firstPid = controller.processID
        #expect(firstPid > 0)

        controller.start(
            TerminalTestSupport.launchSpec(
                executable: URL(fileURLWithPath: "/bin/echo"),
                extraArguments: ["SECOND_SPAWN_SHOULD_NOT_RUN"]
            )
        )

        #expect(controller.processID == firstPid)
        #expect(controller.isRunning)
        #expect(TerminalTestSupport.processIsAlive(firstPid))

        try await Task.sleep(for: .milliseconds(200))
        #expect(!controller.bufferText().contains("SECOND_SPAWN_SHOULD_NOT_RUN"))

        controller.terminate()
        _ = await TerminalTestSupport.waitUntil {
            !TerminalTestSupport.processIsAlive(firstPid)
        }
    }

    @Test func onActivityIsCoalesced() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        var activityCount = 0
        controller.onActivity = { activityCount += 1 }

        // Write a short line to stderr (unbuffered) about every 10 ms for ~1 s.
        // A `yes` flood would prove coalescing too, but it also saturates the
        // emulator; this still writes far more often than 200 ms.
        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: [
                    "/bin/sh", "-c",
                    "i=0; while [ $i -lt 80 ]; do printf x >&2; i=$((i+1)); sleep 0.012; done",
                ]
            )
        )
        #expect(controller.isRunning)

        try await Task.sleep(for: .milliseconds(1100))
        let count = activityCount
        controller.terminate()
        _ = await TerminalTestSupport.waitUntil { !controller.isRunning }

        #expect(count >= 2)
        #expect(count <= 12)
    }
}
