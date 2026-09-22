import Foundation
import Testing

@testable import SigilKit

@Suite("Terminal remote slices", .serialized)
@MainActor
struct TerminalRemoteSliceTests {
    init() {
        TerminalTestSupport.prepareAppKit()
    }

    @Test func earlierSlicePrependsBeforeTheLiveTail() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let directory = helper.deletingLastPathComponent()
        let payload = directory.appendingPathComponent("payload.txt")
        let early = "EARLY_MARKER"
        let mid = "MID_MARKER"
        let late = "LATE_MARKER"
        let text =
            early + "\n" + String(repeating: "a", count: 6_000) + "\n" + mid + "\n"
            + String(repeating: "b", count: 14_000) + "\n" + late + "\n"
        try Data(text.utf8).write(to: payload)
        let controller = TerminalController()
        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper,
                extraArguments: ["/bin/cat", payload.path],
                cwd: directory
            )
        )
        let sawTail = await TerminalTestSupport.waitUntil(timeout: .seconds(8)) {
            !controller.isRunning && controller.remoteSnapshot().contains(late)
        }
        let tail = controller.remoteSnapshot()
        let crash = controller.crashSnapshot()

        #expect(sawTail)
        #expect(tail.contains(late))
        #expect(!tail.contains(early))
        #expect(tail.count <= 12_000)
        #expect(tail.utf8.count <= 12_000)
        #expect(crash.contains(late))
        #expect(!crash.contains(early))
        #expect(crash.count <= 4_000)

        let earlier = controller.remoteEarlierSlice(
            before: String(tail.prefix(80)),
            endAnchor: String(tail.suffix(40)),
            loadedCharacters: tail.count
        )
        #expect(earlier.contains(early))
        #expect(earlier.contains(mid))
        #expect(!earlier.contains(late))
        #expect(earlier.count <= 12_000)
        #expect(earlier.utf8.count <= 12_000)
        #expect(controller.remoteSnapshot() == tail)
        #expect(controller.crashSnapshot() == crash)

        let loaded = earlier + tail
        let next = controller.remoteEarlierSlice(
            before: String(loaded.prefix(80)),
            endAnchor: String(loaded.suffix(40)),
            loadedCharacters: loaded.count
        )
        #expect(!next.contains(late))
        #expect(!next.contains(mid))
        #expect(next.count <= 12_000)
    }
}
