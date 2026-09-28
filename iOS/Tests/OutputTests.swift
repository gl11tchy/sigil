#if canImport(Sigil)
@testable import Sigil
#endif
import Foundation

enum OutputTests {
    static func historyKeepsScrolledText() throws {
        var history = TerminalHistory()
        history.apply("one\ntwo\nthree")
        history.apply("two\nthree\nfour")
        try Expect.equal(history.text, "one\ntwo\nthree\nfour", "overlap appends")
        history.apply("two\nthree\nfour")
        try Expect.equal(history.text, "one\ntwo\nthree\nfour", "same snapshot is idempotent")
    }

    static func historyRedrawReplacesTail() throws {
        var history = TerminalHistory()
        history.apply("Working on it ⠋")
        history.apply("Working on it ⠙")
        try Expect.equal(history.text, "Working on it ⠙", "a spinner redraw is not new text")
    }

    static func historyPrependsOlderText() throws {
        var history = TerminalHistory()
        history.apply("three\nfour")
        try Expect.true(history.prepend("one\ntwo\nthree"), "prepended")
        try Expect.equal(history.text, "one\ntwo\nthree\nfour", "overlap trimmed")
        try Expect.true(!history.prepend(""), "empty slice ends history")
        try Expect.true(history.exhausted, "exhausted")
    }

    static func historyStaysUnderCap() throws {
        var history = TerminalHistory()
        let block = String(repeating: "x", count: 10_000)
        for i in 0..<60 { history.apply(block + "\(i)" + block) }
        try Expect.true(history.count <= TerminalHistory.cap + 30_000, "capped")
    }

    /// The bundled formatter is the web companion's file, byte for byte (test.sh checks that),
    /// so these are cases from Sidereal/test/output.test.mjs.
    @MainActor
    static func readableOutputMatchesCompanion() throws {
        #if os(iOS)
        let formatter = ReadableOutput.bundled()
        #else
        let script = try String(contentsOfFile: "Sigil/Resources/readable-output.js", encoding: .utf8)
        let formatter = ReadableOutput(script: script)
        #endif
        try Expect.true(formatter.isAvailable, "script loaded")
        let footer = "\n" + String(repeating: "─", count: 70)
            + "\n│ ❯ Build anything\n                 Grok 4.6\n(xhigh) · always-approve\n\n→:expand | Ctrl+e:collapse thinking | Ctrl+x:shortcuts"
        try Expect.equal(formatter.format("\n\n└\n┘\n" + String(repeating: "\n", count: 25) + footer), "", "idle screen")
        try Expect.equal(formatter.format("Finished the mobile layout.\n\n" + footer), "Finished the mobile layout.", "composer removed")
        let text = "Result\n\n  if (ready) {\n    send();\n  }\n\nPermission required: approve?"
        try Expect.equal(formatter.format(text), text, "real output kept")
    }

    @MainActor
    static func readableOutputFallsBackToRaw() throws {
        let formatter = ReadableOutput(script: "")
        try Expect.true(!formatter.isAvailable, "no script")
        try Expect.equal(formatter.format("raw\ntext"), "raw\ntext", "raw is lossless")
    }

    static func fileChunks() throws {
        let data = Data(repeating: 7, count: RemoteFile.chunkBytes * 2 + 5)
        let chunks = RemoteFile.chunks(of: data)
        try Expect.equal(chunks.map(\.index), [0, 1, 2], "indexes")
        try Expect.true(chunks.allSatisfy { $0.count == 3 }, "count on every chunk")
        let joined = chunks.reduce(into: Data()) { $0.append(Data(base64Encoded: $1.base64)!) }
        try Expect.equal(joined, data, "chunks reassemble")
        try Expect.equal(RemoteFile.chunks(of: Data()).count, 1, "empty file is one chunk")
        let id = RemoteFile.transferID()
        try Expect.true(id.utf8.count == 32 && RemoteCrypto.isLowerHex(id), "transfer id shape")
    }

    /// Mirrors remoteFileName in the web companion.
    static func safeFileNames() throws {
        let cases: [(String, String)] = [
            ("IMG_0001.HEIC", "IMG_0001.HEIC"),
            ("my photo (1).jpg", "my-photo-1.jpg"),
            ("../../etc/passwd", "passwd"),
            ("", "file"),
            (".hidden", "hidden"),
            ("résumé.pdf", "résumé.pdf"),
            ("notes.averyveryverylongextension", "notes.averyveryverylongextension"),
        ]
        for (input, expected) in cases {
            try Expect.equal(RemoteFile.safeName(input), expected, "name \(input)")
        }
        let long = RemoteFile.safeName(String(repeating: "a", count: 200) + ".png")
        try Expect.true(long.utf8.count <= 80 && long.hasSuffix(".png"), "long names keep the extension")
    }
}
