import AppKit
import Foundation
import Testing

@testable import SigilKit

struct TerminalDropTests {
    @Test func imageExtensionsCoverCommonPhotoTypes() {
        #expect(TerminalDrop.isImagePath("/tmp/shot.PNG"))
        #expect(TerminalDrop.isImagePath("/tmp/photo.jpeg"))
        #expect(TerminalDrop.isImagePath("/tmp/photo.jpg"))
        #expect(TerminalDrop.isImagePath("/tmp/anim.gif"))
        #expect(TerminalDrop.isImagePath("/tmp/x.webp"))
        #expect(TerminalDrop.isImagePath("/tmp/x.heic"))
        #expect(!TerminalDrop.isImagePath("/tmp/notes.md"))
        #expect(!TerminalDrop.isImagePath("/tmp/photo.jpeg.exe"))
    }

    @Test func pasteTextQuotesPathsWithSpaces() {
        #expect(TerminalDrop.pasteText(for: ["/tmp/shot.png"]) == "/tmp/shot.png")
        #expect(
            TerminalDrop.pasteText(for: ["/tmp/my photo.png", "/tmp/other.png"])
                == "'/tmp/my photo.png' /tmp/other.png")
        #expect(TerminalDrop.pasteText(for: ["/tmp/a;b.png"]) == "'/tmp/a;b.png'")
        #expect(TerminalDrop.pasteText(for: ["/tmp/a&b.png"]) == "'/tmp/a&b.png'")
    }

    @Test func filesToPasteSkipDirectoriesAndCapTheCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let photo = root.appendingPathComponent("shot.png")
        let notes = root.appendingPathComponent("notes.md")
        let folder = root.appendingPathComponent("album", isDirectory: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: photo)
        try Data("hi".utf8).write(to: notes)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let kept = TerminalDrop.filesToPaste(from: [folder, photo, notes])
        #expect(kept == [photo, notes])

        let many = (0..<TerminalDrop.maxFiles + 3).map { index in
            root.appendingPathComponent("f\(index).txt")
        }
        for url in many {
            try Data("x".utf8).write(to: url)
        }
        #expect(TerminalDrop.filesToPaste(from: many).count == TerminalDrop.maxFiles)
    }

    @Test func pngMagicBytesAreRecognizedAndWritten() throws {
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        #expect(TerminalDrop.imageExtension(for: png) == "png")
        #expect(TerminalDrop.imageExtension(for: Data("not-an-image".utf8)) == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-img-\(UUID().uuidString)", isDirectory: true)
        let written = try TerminalDrop.writeImage(png, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(written.pathExtension == "png")
        #expect(FileManager.default.fileExists(atPath: written.path))
        #expect(try Data(contentsOf: written) == png)
    }

    @Test func remoteFilesAreSanitizedCappedAndWritten() throws {
        #expect(TerminalDrop.sanitizedFileName("/tmp/../shot name!.PNG") == "shot-name-.PNG")
        #expect(TerminalDrop.sanitizedFileName("...") == "file")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-remote-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try TerminalDrop.writeRemoteFile(Data("hi".utf8), name: "notes.md", to: root)
        #expect(notes.lastPathComponent.contains("notes.md"))
        #expect(try String(contentsOf: notes, encoding: .utf8) == "hi")
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let image = try TerminalDrop.writeRemoteFile(png, name: "x.bin", to: root)
        #expect(image.pathExtension == "png")
        #expect(throws: TerminalDrop.Error.tooLarge) {
            try TerminalDrop.writeRemoteFile(
                Data(repeating: 0x61, count: TerminalDrop.maxRemoteBytes + 1), name: "big.txt", to: root)
        }
    }

    @Test func oversizedImageBytesAreRejected() {
        let huge = Data(repeating: 0x89, count: TerminalDrop.maxImageBytes + 1)
        #expect(throws: TerminalDrop.Error.tooLarge) {
            try TerminalDrop.writeImage(huge, to: FileManager.default.temporaryDirectory)
        }
    }

    @Test func writeImageKeepsOnlyTheNewestCacheFiles() throws {
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sigil-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<(TerminalDrop.cacheKeepCount + 3) {
            _ = try TerminalDrop.writeImage(png, to: root)
        }
        let left = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(left.count == TerminalDrop.cacheKeepCount)
    }
}
