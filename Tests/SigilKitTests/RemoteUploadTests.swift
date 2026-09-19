import Foundation
import Testing

@testable import SigilKit

struct RemoteUploadTests {
    private let png = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    @Test func assemblesChunksAndWritesTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var inbox = RemoteUpload.Inbox()
        let transfer = String(repeating: "ab", count: 16)
        let first = png.prefix(10).base64EncodedString()
        let second = png.suffix(from: 10).base64EncodedString()
        #expect(
            try inbox.receive(
                transfer: transfer, name: "shot.png", index: 0, count: 2, base64: first, directory: root)
                == nil)
        let url = try #require(
            try inbox.receive(
                transfer: transfer, name: "shot.png", index: 1, count: 2, base64: second, directory: root))
        #expect(url.pathExtension == "png")
        #expect(try Data(contentsOf: url) == png)
    }

    @Test func emptyFilesAreWritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-upload-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var inbox = RemoteUpload.Inbox()
        let url = try #require(
            try inbox.receive(
                transfer: String(repeating: "ee", count: 16), name: "empty.txt", index: 0, count: 1,
                base64: Data().base64EncodedString(), directory: root))
        #expect(try Data(contentsOf: url).isEmpty)
    }

    @Test func rejectsBadIdentifiersMismatchedChunksAndChunkCounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-upload-bad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var inbox = RemoteUpload.Inbox()
        let transfer = String(repeating: "cd", count: 16)
        #expect(throws: RemoteError.invalidMessage) {
            try inbox.receive(
                transfer: "nope", name: "a.txt", index: 0, count: 1, base64: Data("hi".utf8).base64EncodedString(),
                directory: root)
        }
        #expect(throws: RemoteError.invalidMessage) {
            try inbox.receive(
                transfer: transfer, name: "a.txt", index: 0, count: 1, base64: "%%%", directory: root)
        }
        _ = try inbox.receive(
            transfer: transfer, name: "a.txt", index: 0, count: 2,
            base64: Data("hello".utf8).base64EncodedString(), directory: root)
        #expect(throws: RemoteError.invalidMessage) {
            try inbox.receive(
                transfer: transfer, name: "b.txt", index: 1, count: 2,
                base64: Data("world".utf8).base64EncodedString(), directory: root)
        }
        // maxChunks and maxChunkBytes bound a transfer at exactly TerminalDrop.maxRemoteBytes,
        // so the chunk count is the reachable half of the 4 MB guard.
        #expect(throws: RemoteError.invalidMessage) {
            try inbox.receive(
                transfer: String(repeating: "ef", count: 16), name: "many.bin", index: 0,
                count: RemoteUpload.maxChunks + 1, base64: "YQ==", directory: root)
        }
    }
}
