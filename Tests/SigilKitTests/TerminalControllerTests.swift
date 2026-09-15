import AppKit
import Darwin
import Foundation
import SwiftTerm
import Testing

@testable import SigilKit

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

    @Test func droppedFilePathIsPastedIntoTheChild() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: ["/bin/cat"]
            )
        )
        #expect(
            await TerminalTestSupport.waitUntil {
                controller.isRunning
            })

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-drop-pty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("shot.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: photo)

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([photo as NSURL]))
        #expect(controller.pasteDroppedContent(from: pasteboard))

        let sawPath = await TerminalTestSupport.waitUntil {
            controller.bufferText().contains(photo.path)
        }
        controller.terminate()
        #expect(sawPath)
        #expect(await TerminalTestSupport.waitUntil { !controller.isRunning })
    }

    @Test func inputSubmissionIgnoresBracketedPasteNewlines() {
        let view = GrokProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            options: .default
        )
        var submissions = 0
        view.onUserSubmit = { submissions += 1 }

        view.send(source: view, data: [0x0D][...])
        #expect(submissions == 1)

        view.send(source: view, data: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E][...])
        view.send(source: view, data: Array("first\nsecond".utf8)[...])
        view.send(source: view, data: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E][...])
        #expect(submissions == 1)

        view.send(source: view, data: [0x0A][...])
        #expect(submissions == 2)
    }

    @Test func enhancedKeyboardReturnStillReportsSubmission() {
        let view = GrokProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            options: .default
        )
        var submissions = 0
        view.onUserSubmit = { submissions += 1 }

        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        #expect(submissions == 1)

        view.doCommand(by: #selector(NSTextView.moveUp(_:)))
        #expect(submissions == 1)

        view.feed(byteArray: [0x1B, 0x5B, 0x3E, 0x31, 0x31, 0x75][...])
        view.doCommand(by: #selector(NSTextView.insertNewline(_:)))
        #expect(submissions == 2)

        view.send(source: view, data: Array("\u{1b}[13;1:3u".utf8)[...])
        #expect(submissions == 2)
    }

    @Test func synchronousTerminationFinishesAnEarlierAsynchronousStop() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        var terminations = 0
        controller.onTerminate = { _ in terminations += 1 }

        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: [
                    "/bin/sh", "-c",
                    "trap '' TERM; printf RESIST_READY; while :; do /bin/sleep 1; done",
                ]
            )
        )
        #expect(controller.isRunning)
        #expect(
            await TerminalTestSupport.waitUntil {
                controller.bufferText().contains("RESIST_READY")
            })
        let pid = controller.processID
        #expect(pid > 0)
        defer {
            if TerminalTestSupport.processIsAlive(pid) {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                _ = TerminalController.reap(pid)
            }
        }

        controller.terminate()
        controller.terminateAndWait(timeout: .milliseconds(300))

        #expect(
            await TerminalTestSupport.waitUntil(timeout: .seconds(2)) {
                !TerminalTestSupport.processIsAlive(pid)
                    && TerminalTestSupport.processGroupMembers(pid).isEmpty
                    && !controller.isRunning
                    && terminations == 1
            })
    }

    @Test func accessibilityExposesBoundedUnicodeTerminalText() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let controller = TerminalController()
        let marker = "AX_👩‍💻界_END"
        let output = String(repeating: "x", count: 52_000) + marker

        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: ["/usr/bin/printf", "%s", output]
            )
        )
        let sawExit = await TerminalTestSupport.waitUntil { !controller.isRunning }
        let sawFinalValue = await TerminalTestSupport.waitUntil {
            (controller.view.accessibilityValue() as? String)?.contains(marker) == true
        }
        let value = controller.view.accessibilityValue() as? String

        #expect(sawExit)
        #expect(sawFinalValue)
        #expect(controller.view.isAccessibilityElement())
        #expect(controller.view.accessibilityRole() == .textArea)
        #expect(controller.view.accessibilityLabel() == "Grok terminal")
        #expect(value?.contains(marker) == true)
        #expect((value?.count ?? .max) <= 50_000)
        #expect(
            value?.unicodeScalars.allSatisfy {
                $0 == "\n" || $0 == "\t" || $0.properties.generalCategory != .control
            } == true
        )
    }

    @Test func anAlreadyReapedChildIsGoneEvenIfItsPIDCouldBeReused() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        #expect(TerminalController.reap(process.processIdentifier))
    }
}
