import Foundation
import Testing

@testable import SigilKit

@Suite("Terminal remote screen", .serialized)
@MainActor
struct TerminalRemoteScreenTests {
    init() {
        TerminalTestSupport.prepareAppKit()
    }

    @Test func windowCarriesTextStylesAndOlderRowsByAbsoluteIndex() async throws {
        let helper = try TerminalTestSupport.makeFlagStrippingHelper()
        let directory = helper.deletingLastPathComponent()
        let payload = directory.appendingPathComponent("payload.bin")
        var text = ""
        for line in 0..<60 { text += "line \(line)\n" }
        // Red bold "ERR", then plain text, then a true-colour word.
        text += "\u{1b}[1;31mERR\u{1b}[0m plain \u{1b}[38;2;18;52;86mdeep\u{1b}[0m\nLAST\n"
        try Data(text.utf8).write(to: payload)
        let controller = TerminalController()
        controller.start(
            TerminalTestSupport.launchSpec(
                executable: helper, extraArguments: ["/bin/cat", payload.path], cwd: directory))
        let done = await TerminalTestSupport.waitUntil(timeout: .seconds(8)) {
            !controller.isRunning && controller.remoteSnapshot().contains("LAST")
        }
        #expect(done)

        let window = controller.remoteScreenWindow(maxRows: 10, maxCharacters: 12_000)
        #expect(window.rows.count == 10)
        #expect(window.end == window.rows.last!.i + 1)
        #expect(window.first == window.rows.first!.i)
        #expect(window.palette.count == 16)
        #expect(window.fg.count == 6)
        let styled = try #require(window.rows.first { $0.t.hasPrefix("ERR") })
        #expect(styled.t == "ERR plain deep")
        let runs = try #require(styled.s)
        #expect(runs.contains([0, 3, 1, -1, 1]))
        #expect(runs.contains([10, 4, RemoteScreen.trueColor(red: 18, green: 52, blue: 86), -1, 0]))
        let plain = try #require(window.rows.first { $0.t == "line 59" })
        #expect(plain.s == nil)

        let older = controller.remoteScreenRows(before: window.first, maxRows: 5)
        #expect(older.count == 5)
        #expect(older.last!.i == window.first - 1)
        // "line N" sits at absolute row N, so the rows before the window are numbered by index.
        #expect(older.map(\.t) == ((window.first - 5)..<window.first).map { "line \($0)" })
        #expect(controller.remoteScreenRows(before: 0).isEmpty)

        // The generation only moves when the index space restarts.
        #expect(controller.remoteScreenWindow().gen == window.gen)
    }
}
