import Foundation

/// Assembles bounded phone file chunks and writes them into the drop cache.
public enum RemoteUpload: Sendable {
    public static let maxChunks = 128
    public static let maxPending = 4
    public static let maxChunkBytes = 32 * 1024
    public static let timeout: TimeInterval = 60

    public struct Inbox: Sendable {
        private struct Transfer: Sendable {
            var scope: String
            var name: String
            var count: Int
            var chunks: [Int: Data]
            var updated: Date
        }

        private var pending: [String: Transfer] = [:]
        private var completed: [String: Date] = [:]

        public init() {}

        public mutating func receive(
            transfer: String, name: String, index: Int, count: Int, base64: String, directory: URL,
            now: Date = Date(), scope: String = ""
        ) throws -> URL? {
            prune(now: now)
            guard isTransferID(transfer), count >= 1, count <= RemoteUpload.maxChunks, index >= 0,
                index < count
            else { throw RemoteError.invalidMessage }
            let data = base64.isEmpty ? Data() : Data(base64Encoded: base64)
            guard let data, data.count <= RemoteUpload.maxChunkBytes else { throw RemoteError.invalidMessage }
            // A transfer belongs to one authenticated connection and one tab.
            // A late tail must not begin a new upload after reconnect or expiry.
            guard completed[transfer] == nil,
                pending[transfer] != nil || (index == 0 && completed.count < 256)
            else { throw RemoteError.invalidMessage }
            if pending[transfer] == nil, pending.count >= RemoteUpload.maxPending {
                throw RemoteError.invalidMessage
            }
            var item = pending[transfer] ?? Transfer(scope: scope, name: name, count: count, chunks: [:], updated: now)
            guard item.scope == scope, item.count == count, item.name == name else { throw RemoteError.invalidMessage }
            if let existing = item.chunks[index], existing != data { throw RemoteError.invalidMessage }
            item.chunks[index] = data
            item.updated = now
            let total = item.chunks.values.reduce(0) { $0 + $1.count }
            guard total <= TerminalDrop.maxRemoteBytes else { throw TerminalDrop.Error.tooLarge }
            if item.chunks.count != count {
                pending[transfer] = item
                return nil
            }
            pending[transfer] = nil
            // Consume before writing/pasting. A lost reply never repeats the write.
            completed[transfer] = now
            var assembled = Data(capacity: total)
            for chunkIndex in 0..<count {
                guard let chunk = item.chunks[chunkIndex] else { throw RemoteError.invalidMessage }
                assembled.append(chunk)
            }
            return try TerminalDrop.writeRemoteFile(assembled, name: name, to: directory)
        }

        public mutating func prune(now: Date = Date()) {
            pending = pending.filter { now.timeIntervalSince($0.value.updated) < RemoteUpload.timeout }
            completed = completed.filter { now.timeIntervalSince($0.value) < RemoteUpload.timeout }
        }

        private func isTransferID(_ value: String) -> Bool {
            value.utf8.count == 32
                && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}
