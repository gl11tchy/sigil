import AppKit
import Foundation

/// Turns Finder drops and clipboard images into prompt text Grok already
/// understands: absolute paths. Image files become chips; other files paste as
/// paths. SwiftTerm has no drag destination, so the host has to do this.
public enum TerminalDrop {
    public static let maxFiles = 16
    public static let maxImageBytes = 20 * 1024 * 1024
    public static let maxRemoteBytes = 4 * 1024 * 1024

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "heif",
    ]

    public static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
    ]

    public enum Error: Swift.Error, Equatable {
        case tooLarge
        case notAnImage
        case nothingToPaste
    }

    public static func isImagePath(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    public static func filesToPaste(from urls: [URL]) -> [URL] {
        var files: [URL] = []
        files.reserveCapacity(min(urls.count, maxFiles))
        for url in urls {
            guard files.count < maxFiles else { break }
            let resolved = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            files.append(resolved)
        }
        return files
    }

    public static func pasteText(for paths: [String]) -> String {
        paths.map(quoteIfNeeded).joined(separator: " ")
    }

    public static func imageExtension(for data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.count >= 12,
            data.starts(with: [0x52, 0x49, 0x46, 0x46]),
            data[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50])
        {
            return "webp"
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00])
            || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        {
            return "tiff"
        }
        return nil
    }

    public static let cacheKeepCount = 8

    public static func sanitizedFileName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
        let mapped = String(
            base.unicodeScalars.map { scalar -> Character in
                if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
                if scalar == "." || scalar == "_" || scalar == "-" { return Character(scalar) }
                return "-"
            })
        let collapsed = mapped.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let clipped = String(trimmed.prefix(80))
        return clipped.isEmpty ? "file" : clipped
    }

    public static func writeRemoteFile(_ data: Data, name: String, to directory: URL) throws -> URL {
        guard data.count <= maxRemoteBytes else { throw Error.tooLarge }
        if imageExtension(for: data) != nil {
            return try writeImage(data, to: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("drop-\(UUID().uuidString)-\(sanitizedFileName(name))")
        try data.write(to: url, options: .withoutOverwriting)
        pruneCache(in: directory, keeping: max(cacheKeepCount, maxFiles), protecting: url)
        return url
    }

    public static func writeImage(_ data: Data, to directory: URL) throws -> URL {
        guard data.count <= maxImageBytes else { throw Error.tooLarge }
        guard let ext = imageExtension(for: data) else { throw Error.notAnImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("drop-\(UUID().uuidString).\(ext)")
        try data.write(to: url, options: .withoutOverwriting)
        pruneCache(in: directory, keeping: cacheKeepCount, protecting: url)
        return url
    }

    public static func pruneCache(in directory: URL, keeping newest: Int, protecting: URL? = nil) {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles)) ?? []
        var sorted = files.sorted { lhs, rhs in
            let left =
                (try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            let right =
                (try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
            return left > right
        }
        if let protecting {
            let protected = protecting.standardizedFileURL.path
            sorted.removeAll { $0.standardizedFileURL.path == protected }
            sorted.insert(protecting, at: 0)
            for extra in sorted.dropFirst(newest) where extra.standardizedFileURL.path != protected {
                try? FileManager.default.removeItem(at: extra)
            }
        } else {
            for extra in sorted.dropFirst(newest) {
                try? FileManager.default.removeItem(at: extra)
            }
        }
    }

    public static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png), imageExtension(for: png) == "png",
            png.count <= maxImageBytes
        {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff), tiff.count <= maxImageBytes,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        {
            return png
        }
        return nil
    }

    public static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let fromObjects =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [
                    .urlReadingFileURLsOnly: true
                ]) as? [URL] ?? []
        if !fromObjects.isEmpty { return fromObjects }
        if let filenames = pasteboard.propertyList(forType: .init("NSFilenamesPboardType"))
            as? [String]
        {
            return filenames.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    public static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        if !filesToPaste(from: fileURLs(from: pasteboard)).isEmpty { return true }
        if let png = pasteboard.data(forType: .png), png.count <= maxImageBytes,
            imageExtension(for: png) == "png"
        {
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff), tiff.count <= maxImageBytes {
            return true
        }
        return false
    }

    /// Cache directory for clipboard images that have no file on disk.
    public static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("SigilDrops", isDirectory: true)
    }

    public static func pathsToPaste(from pasteboard: NSPasteboard) throws -> [String] {
        let files = filesToPaste(from: fileURLs(from: pasteboard))
        if !files.isEmpty {
            return files.map(\.path)
        }
        guard let data = pngData(from: pasteboard) else { throw Error.nothingToPaste }
        let written = try writeImage(data, to: cacheDirectory())
        return [written.path]
    }

    private static let unquotedPath = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")

    private static func quoteIfNeeded(_ path: String) -> String {
        if path.unicodeScalars.contains(where: { !unquotedPath.contains($0) }) {
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return path
    }
}
