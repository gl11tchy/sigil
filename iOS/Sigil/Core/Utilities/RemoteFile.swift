import Foundation

/// Files from the phone travel as 32 KB chunks; the Mac assembles them in its drop cache.
enum RemoteFile {
    static let maxBytes = 4 * 1024 * 1024
    static let chunkBytes = 32 * 1024
    static let maxAttachments = 16

    struct Chunk: Equatable {
        let index: Int
        let count: Int
        let base64: String
    }

    static func chunks(of data: Data) -> [Chunk] {
        let count = max(1, (data.count + chunkBytes - 1) / chunkBytes)
        return (0..<count).map { index in
            let start = data.startIndex + index * chunkBytes
            let end = min(start + chunkBytes, data.endIndex)
            return Chunk(index: index, count: count, base64: data[start..<end].base64EncodedString())
        }
    }

    /// 32 lowercase hex characters, the transfer id shape the Mac accepts.
    static func transferID() -> String {
        String(RemoteCrypto.randomKey().prefix(32))
    }

    /// A safe name under 80 bytes. Keeps the extension: the Mac CLI reads the file type from it.
    static func safeName(_ name: String) -> String {
        let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let dot = base.lastIndex(of: ".").flatMap { $0 == base.startIndex ? nil : $0 }
        var ext = dot.map { clean(String(base[base.index(after: $0)...])) } ?? ""
        if ext.utf8.count > 16 { ext = "" }
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let stemSource = !ext.isEmpty && dot != nil ? String(base[..<dot!]) : base
        var stem = Array(clean(stemSource).isEmpty ? "file" : clean(stemSource))
        while stem.count > 1, (String(stem) + suffix).utf8.count > 80 { stem.removeLast() }
        var trimmed = String(stem)
        while let last = trimmed.last, last == "." || last == "-" { trimmed.removeLast() }
        return (trimmed.isEmpty ? "file" : trimmed) + suffix
    }

    private static func clean(_ part: String) -> String {
        var out = ""
        for scalar in part.unicodeScalars {
            let allowed =
                scalar.properties.isAlphabetic || scalar.properties.numericType != nil
                || scalar.properties.generalCategory == .nonspacingMark
                || scalar.properties.generalCategory == .spacingMark
                || scalar.properties.generalCategory == .enclosingMark
                || scalar == "." || scalar == "_" || scalar == "-"
            let next: Character = allowed ? Character(scalar) : "-"
            if next == "-", out.last == "-" { continue }
            out.append(next)
        }
        while let first = out.first, first == "." || first == "-" { out.removeFirst() }
        while let last = out.last, last == "." || last == "-" { out.removeLast() }
        return out
    }
}
