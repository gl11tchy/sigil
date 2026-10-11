import Darwin
import Foundation

/// Markers only select records. Foundation still validates every selected JSON
/// envelope; a marker never supplies an identity, version, title or model.
struct NativeSessionRecordDecoder: Sendable {
    enum Source: Sendable { case transcript, codexTitleIndex }
    /// Differential tests use the unchanged consume path without selection.
    var selectsCandidates = true
    var didDecode: @Sendable (Source) -> Void = { _ in }
    private static let claudeMetadata = ["sessionId", "cwd", "version", "isSidechain", "customTitle", "model"]
        .map { Array($0.utf8) }
    private static let claudeMessages = ["message", "content"].map { Array($0.utf8) }
    private static let summary = [Array("summary".utf8)]
    private static let codexMetadata = ["session_meta", "turn_context"].map { Array($0.utf8) }
    private static let codexMessages = ["event_msg", "response_item"].map { Array($0.utf8) }

    func object(_ line: Data, source: Source = .transcript) -> [String: Any]? {
        didDecode(source)
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Data's generic split/firstIndex traversed every byte after JSON selection
    /// removed that work. Keep framing bounded too; returned records own their bytes.
    static func records(in data: Data, limit: Int) -> [Data] {
        var records: [Data] = []
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var cursor = 0
            while cursor < buffer.count {
                let newline = memchr(base.advanced(by: cursor), 0x0A, buffer.count - cursor)
                let end = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? buffer.count
                let count = end - cursor
                if count > 0, count <= limit { records.append(Data(bytes: base.advanced(by: cursor), count: count)) }
                cursor = end + 1
            }
        }
        return records
    }

    static func nextNewline(in data: Data, from cursor: Data.Index) -> Data.Index? {
        data.withUnsafeBytes { buffer in
            let offset = data.distance(from: data.startIndex, to: cursor)
            guard offset >= 0, offset < buffer.count, let base = buffer.baseAddress,
                let newline = memchr(base.advanced(by: offset), 0x0A, buffer.count - offset)
            else { return nil }
            return data.index(data.startIndex, offsetBy: base.distance(to: UnsafeRawPointer(newline)))
        }
    }

    func mayChangeRow(
        _ line: Data, provider: CLIProvider, needsPrompt: Bool, needsContent: Bool, needsSummary: Bool = false
    ) -> Bool {
        guard selectsCandidates else { return true }
        // Measured byte-by-byte Swift/Data searches cost as much as full JSON.
        // Borrow one bounded buffer; memchr skips long content strings without
        // copying them. Every pointer stays inside its storage lifetime, and every
        // C search/comparison is bounded by the buffer or a matched token length.
        return line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            // Any escape could spell a metadata key/type. NUL can indicate an
            // encoding Foundation understands. Fall back instead of unescaping.
            if memchr(base, 0x5C, buffer.count) != nil || memchr(base, 0, buffer.count) != nil { return true }
            var cursor = 0
            while cursor < buffer.count,
                let opening = memchr(base.advanced(by: cursor), 0x22, buffer.count - cursor)
            {
                let start = base.distance(to: UnsafeRawPointer(opening)) + 1
                guard start < buffer.count,
                    let closing = memchr(base.advanced(by: start), 0x22, buffer.count - start)
                else { return false }
                let end = base.distance(to: UnsafeRawPointer(closing))
                let count = end - start
                func matches(_ markers: [[UInt8]]) -> Bool {
                    markers.contains { marker in
                        guard marker.count == count else { return false }
                        return marker.withUnsafeBufferPointer { bytes in
                            memcmp(base.advanced(by: start), bytes.baseAddress!, count) == 0
                        }
                    }
                }
                // Markers in values/nested objects only add a conservative decode.
                if provider == .claudeCode {
                    if matches(Self.claudeMetadata) || (needsSummary && matches(Self.summary))
                        || ((needsPrompt || needsContent) && matches(Self.claudeMessages))
                    {
                        return true
                    }
                } else if matches(Self.codexMetadata)
                    || ((needsPrompt || needsContent) && matches(Self.codexMessages))
                {
                    return true
                }
                cursor = end + 1
            }
            return false
        }
    }
}
