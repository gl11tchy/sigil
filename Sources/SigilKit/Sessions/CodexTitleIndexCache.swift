import CryptoKit
import Darwin
import Foundation
import os

/// One in-memory cache per store. Only validated display titles and a bounded
/// unfinished record survive; this does not persist provider history or messages.
final class CodexTitleIndexCache: Sendable {
    static let windowLimit = 2 * 1024 * 1024
    static let recordLimit = 16 * 1024 - 1
    private struct Title: Sendable {
        var text: String
        var offset: UInt64
    }
    private struct State: Sendable {
        var identity: NativeSessionScanner.FileSnapshot
        var windowStart: UInt64
        var offset: UInt64
        var digest: [UInt8] = []
        var titles: [String: Title] = [:]
        var remainder = Data()
        var recordStart: UInt64
        var discarding = false
        var discardFirstNonempty: Bool
        var names: [String: String] = [:]
    }
    private let states = OSAllocatedUnfairLock(initialState: [String: State]())

    func names(
        at file: URL, ignoringCache: Bool = false,
        reader: NativeSessionScanner.ContentReader = .disk,
        decoder: NativeSessionRecordDecoder = .init()
    ) -> [String: String] {
        states.withLock { states in
            let key = file.standardizedFileURL.path
            let old = ignoringCache ? nil : states[key]
            if reader.isCancelled() { return old?.names ?? [:] }
            // O_NOFOLLOW rejects a replaced symlink before any contents are read.
            let fd = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else {
                if errno == ENOENT, !reader.isCancelled() {
                    states.removeValue(forKey: key)
                    return [:]
                }
                return old?.names ?? [:]
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            do {
                try checkCancellation(reader)
                let before = try snapshot(fd)
                var pathInfo = stat()
                guard lstat(file.path, &pathInfo) == 0, pathInfo.st_mode & S_IFMT == S_IFREG,
                    NativeSessionScanner.FileSnapshot(pathInfo) == before, before.size >= 0
                else { throw CocoaError(.fileReadUnknown) }
                if let old, old.identity == before { return old.names }
                let size = UInt64(before.size)
                let start = size > UInt64(Self.windowLimit) ? size - UInt64(Self.windowLimit) : 0
                var state = State(
                    identity: before, windowStart: start, offset: start, recordStart: start,
                    discardFirstNonempty: start > 0)
                if let old, before.isSameFile(as: old.identity), size > old.offset, start < old.offset {
                    let previous = try fingerprint(
                        handle, start: old.windowStart, end: old.offset, reader: reader)
                    if previous.digest == old.digest { state = old }
                }
                try readRecords(&state, handle: handle, end: size, reader: reader, decoder: decoder)
                // Validate every byte of the retained window, not sampled anchors.
                // Growth can move its boundary; evict titles before the first whole
                // record that the existing latest-2-MiB policy would have accepted.
                let retained = try fingerprint(handle, start: start, end: size, reader: reader)
                state.titles = state.titles.filter { $0.value.offset >= retained.firstUsableOffset }
                var projected = state.titles
                if !state.discarding, !state.discardFirstNonempty,
                    state.recordStart >= retained.firstUsableOffset, !state.remainder.isEmpty
                {
                    consume(state.remainder, offset: state.recordStart, titles: &projected, decoder: decoder)
                }
                try checkCancellation(reader)
                guard try snapshot(fd) == before, lstat(file.path, &pathInfo) == 0,
                    pathInfo.st_mode & S_IFMT == S_IFREG,
                    NativeSessionScanner.FileSnapshot(pathInfo) == before
                else { throw CocoaError(.fileReadUnknown) }
                state.identity = before
                state.windowStart = start
                state.digest = retained.digest
                state.names = projected.mapValues(\.text)
                states[key] = state
                return state.names
            } catch {
                // A cancelled/racing/unreadable scan cannot replace validated state.
                return old?.names ?? [:]
            }
        }
    }

    private func readRecords(
        _ state: inout State, handle: FileHandle, end: UInt64,
        reader: NativeSessionScanner.ContentReader, decoder: NativeSessionRecordDecoder
    ) throws {
        while state.offset < end {
            try checkCancellation(reader)
            let requested = min(NativeSessionScanner.chunkLimit, Int(end - state.offset))
            let chunk = try reader.read(handle, state.offset, requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw CocoaError(.fileReadUnknown) }
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                try checkCancellation(reader)
                let newline = NativeSessionRecordDecoder.nextNewline(in: chunk, from: cursor)
                let stop = newline ?? chunk.endIndex
                let count = chunk.distance(from: cursor, to: stop)
                if !state.discarding {
                    if state.remainder.count + count > Self.recordLimit {
                        state.remainder = Data()
                        state.discarding = true
                    } else {
                        state.remainder.append(chunk[cursor..<stop])
                    }
                }
                if let newline {
                    let nonempty = state.discarding || !state.remainder.isEmpty
                    if state.discardFirstNonempty, nonempty {
                        state.discardFirstNonempty = false
                    } else if !state.discarding, !state.discardFirstNonempty {
                        consume(state.remainder, offset: state.recordStart, titles: &state.titles, decoder: decoder)
                    }
                    state.remainder = Data()
                    state.discarding = false
                    cursor = chunk.index(after: newline)
                    state.recordStart = state.offset + UInt64(chunk.distance(from: chunk.startIndex, to: cursor))
                } else {
                    cursor = stop
                }
            }
            state.offset += UInt64(chunk.count)
        }
    }

    private func consume(
        _ record: Data, offset: UInt64, titles: inout [String: Title], decoder: NativeSessionRecordDecoder
    ) {
        guard !record.isEmpty, let object = decoder.object(record, source: .codexTitleIndex),
            let id = object["id"] as? String, UUID(uuidString: id) != nil,
            let name = object["thread_name"] as? String, !name.isEmpty
        else { return }
        titles[id] = Title(text: String(name.prefix(240)).replacingOccurrences(of: "\n", with: " "), offset: offset)
    }

    private func fingerprint(
        _ handle: FileHandle, start: UInt64, end: UInt64, reader: NativeSessionScanner.ContentReader
    ) throws -> (digest: [UInt8], firstUsableOffset: UInt64) {
        var hasher = SHA256()
        var offset = start
        var firstUsable = start == 0 ? UInt64(0) : end
        var foundFirst = start == 0
        var nonempty = false
        while offset < end {
            try checkCancellation(reader)
            let requested = min(NativeSessionScanner.chunkLimit, Int(end - offset))
            let chunk = try reader.read(handle, offset, requested)
            guard !chunk.isEmpty, chunk.count <= requested else { throw CocoaError(.fileReadUnknown) }
            hasher.update(data: chunk)
            if !foundFirst {
                for (index, byte) in chunk.enumerated() {
                    if byte == 0x0A {
                        if nonempty {
                            firstUsable = offset + UInt64(index + 1)
                            foundFirst = true
                            break
                        }
                    } else {
                        nonempty = true
                    }
                }
            }
            offset += UInt64(chunk.count)
        }
        return (Array(hasher.finalize()), firstUsable)
    }

    private func snapshot(_ fd: Int32) throws -> NativeSessionScanner.FileSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        return NativeSessionScanner.FileSnapshot(info)
    }

    private func checkCancellation(_ reader: NativeSessionScanner.ContentReader) throws {
        if reader.isCancelled() { throw CancellationError() }
    }
}
