import Foundation
import Testing
import os

@testable import SigilKit

struct NativeSessionSelectionTests {
    let id = "11111111-1111-4111-8111-111111111111"
    let otherID = "22222222-2222-4222-8222-222222222222"
    let file = URL(fileURLWithPath: "/tmp/generated-selection.jsonl")
    let modified = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func sixHundredFortyKiBDecodesOnlyTheRowCandidate() throws {
        var data = claudeHeader
        let irrelevant = Data(
            ("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\""
                + String(repeating: "x", count: 4096) + "\"}]}}\n").utf8)
        while data.count + irrelevant.count < 640 * 1024 { data.append(irrelevant) }
        data.append(
            Data(
                ("{\"type\":\"progress\",\"data\":\"" + String(repeating: "x", count: 640 * 1024 - data.count - 30)
                    + "\"}\n").utf8))
        let meter = RecordDecodeMeter()
        #expect(data.count == 640 * 1024)
        #expect(
            outcome(.claudeCode, data, meter.decoder) == outcome(.claudeCode, data, .init(selectsCandidates: false)))
        #expect(meter.counts().transcript == 1)
    }

    @Test func selectionMatchesFullDecodingForLateAndEscapedMetadata() {
        let claudeRecords = [
            #"{"type":"summary","summary":"Earlier summary"}"#,
            #"{"type":"user","message":{"content":"<command-result>"}}"#,
            #"{"type":"user","message":{"content":"Later real prompt"}}"#,
            #"{"type":"assistant","message":{"model":"late-model","content":[]}}"#,
            #"{ "type" : "custom-title", "custom\u0054itle" : "Escaped rename" }"#,
            #"{"type":"custom-title","customTitle":""}"#,
            #"{"type":"summary","summary":"Ignored later summary"}"#,
            #"{"type":"user","session\u0049d":"22222222-2222-4222-8222-222222222222","cwd":"/tmp/project","version":"2.1.283"}"#,
            #"{"type":"progress","type":"user","sessionId":"22222222-2222-4222-8222-222222222222","cwd":"/tmp/project","version":"2.1.283"}"#,
            #"{"type":"user","sessionId":"11111111-1111-4111-8111-111111111111","cwd":"/tmp/other","version":"2.1.283"}"#,
            #"{"type":"user","version":"3.0.0"}"#,
            #"{"type":"assistant","message":{"model":"partial"}"#,
        ]
        let codexRecords = [
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real response title"}]}}"#,
            #"{ "type" : "turn_context", "payload" : { "model" : "late-model" } }"#,
            #"{"ty\u0070e":"turn_context","payload":{"model":"escaped-model"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Later event title","images":["generated"]}}"#,
            #"{"type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111","cwd":"/tmp/project","cli_version":"0.160.0"}}"#,
            #"{"type":"sess\u0069on_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","cwd":"/tmp/project","cli_version":"0.160.0"}}"#,
            #"{"type":"progress","type":"session_meta","payload":{"id":"22222222-2222-4222-8222-222222222222","cwd":"/tmp/project","cli_version":"0.160.0"}}"#,
            #"{"type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111","cwd":"/tmp/project","cli_version":"1.0.0"}}"#,
            #"{"type":"session_meta","payload":null}"#,
            #"{"type":"session_meta","payload":{"id":"broken"}"#,
        ]
        for (provider, header, records) in [
            (CLIProvider.claudeCode, claudeHeader, claudeRecords), (.codex, codexHeader, codexRecords),
        ] {
            for record in records {
                let data = header + Data((record + "\n").utf8)
                #expect(outcome(provider, data, .init()) == outcome(provider, data, .init(selectsCandidates: false)))
            }
            let all = header + Data((records.joined(separator: "\n") + "\n").utf8)
            #expect(outcome(provider, all, .init()) == outcome(provider, all, .init(selectsCandidates: false)))
        }
    }

    @Test func deferredTitlesAndObservedContentStillMatch() {
        let claude = Data(
            "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/tmp/project\",\"version\":\"2.1.283\",\"message\":{\"content\":\"<command-result>\"}}\n{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"Skip meta\"}}\n{\"type\":\"user\",\"message\":{\"content\":\"Real Claude prompt\"}}\n"
                .utf8)
        let sources = [
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Real event title"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real response title"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Observed assistant"}]}}"#,
        ]
        #expect(outcome(.claudeCode, claude, .init()) == outcome(.claudeCode, claude, .init(selectsCandidates: false)))
        for source in sources {
            let data = codexHeader + Data((source + "\n").utf8)
            #expect(outcome(.codex, data, .init()) == outcome(.codex, data, .init(selectsCandidates: false)))
        }
    }

    @Test func oversizedMetadataKeepsTheExistingBoundedPolicy() {
        let huge = String(repeating: "x", count: NativeSessionScanner.prefixLimit)
        for (provider, header) in [(CLIProvider.codex, codexHeader), (.claudeCode, claudeHeader)] {
            let record = Data("{\"type\":\"session_meta\",\"instructions\":\"\(huge)\"}\n".utf8)
            #expect(
                outcome(provider, header + record, .init())
                    == outcome(provider, header + record, .init(selectsCandidates: false)))
        }
    }

    @Test func largeMetadataInstructionsStillValidateAfterATitleIsKnown() throws {
        let title = Data(
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Known title\"}}\n".utf8)
        let instructions = String(repeating: "x", count: 256 * 1024)
        for version in ["0.160.0", "1.0.0"] {
            let header =
                try JSONSerialization.data(withJSONObject: [
                    "type": "session_meta",
                    "payload": ["id": id, "cwd": "/tmp/project", "cli_version": version, "instructions": instructions],
                ]) + Data([10])
            let data = codexHeader + title + header
            let meter = RecordDecodeMeter()
            #expect(outcome(.codex, data, meter.decoder) == outcome(.codex, data, .init(selectsCandidates: false)))
            #expect(meter.counts().transcript == 3)
            if version == "1.0.0" { #expect(outcome(.codex, data, .init()) == .unsupported("1.0.0")) }
        }
    }

    @Test func boundedMarkerSearchHandlesEmptyMalformedAndAlternateEncodingBuffers() throws {
        let buffers = [
            Data(), Data([34]), Data([34, 34]), Data([0]), Data([92]), Data([34, 92]),
            Data(repeating: 34, count: 4096), Data(repeating: 120, count: NativeSessionScanner.prefixLimit),
        ]
        for buffer in buffers {
            for provider in [CLIProvider.codex, .claudeCode] {
                #expect(
                    outcome(provider, buffer, .init()) == outcome(provider, buffer, .init(selectsCandidates: false)))
            }
        }
        let text = String(decoding: claudeHeader, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        for encoding in [String.Encoding.utf16, .utf32] {
            let data = try #require(text.data(using: encoding))
            #expect(outcome(.claudeCode, data, .init()) == outcome(.claudeCode, data, .init(selectsCandidates: false)))
            // The JSONL framing/legacy decoder determines encoding support;
            // selection must preserve that result rather than expanding it.
            if case .session(let row) = outcome(.claudeCode, data, .init()) {
                #expect(row.summary == "First prompt")
            }
        }
    }

    @Test func boundedFramingMatchesFoundationDataSplittingIncludingSlices() {
        let data = Data("\n\nfirst\n\nsecond\nlast without delimiter".utf8)
        for input in [Data(), data, data.dropFirst(3), Data([10]), Data([34, 0, 92, 10, 34])] {
            for limit in [0, 1, 7, NativeSessionScanner.prefixLimit] {
                let reference = input.split(separator: 10).filter { $0.count <= limit }.map { Data($0) }
                #expect(NativeSessionRecordDecoder.records(in: input, limit: limit) == reference)
            }
            for cursor in input.indices {
                #expect(
                    NativeSessionRecordDecoder.nextNewline(in: input, from: cursor)
                        == input[cursor...].firstIndex(of: 10))
            }
            #expect(NativeSessionRecordDecoder.nextNewline(in: input, from: input.endIndex) == nil)
        }
    }

    @Test func unchangedIndexParsesOnceAndAppendOnlyDecodesNewRecords() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        let meter = RecordDecodeMeter()
        try indexTitle("First").write(to: fixture.index)
        #expect(fixture.names(meter.decoder)[id] == "First")
        #expect(meter.counts().index == 1)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let reader = NativeSessionScanner.ContentReader(read: { handle, offset, count in
            reads.withLock { $0 += 1 }
            return try NativeSessionScanner.ContentReader.disk.read(handle, offset, count)
        })
        #expect(fixture.cache.names(at: fixture.index, reader: reader)[id] == "First")
        #expect(reads.withLock { $0 } == 0)
        #expect(fixture.names(meter.decoder)[id] == "First")
        #expect(meter.counts().index == 1)
        try fixture.append(indexTitle("Second"))
        #expect(fixture.names(meter.decoder)[id] == "Second")
        #expect(meter.counts().index == 2)
        #expect(fixture.cache.names(at: fixture.index, ignoringCache: true, decoder: meter.decoder)[id] == "Second")
        #expect(meter.counts().index == 4)
    }

    @Test func indexCarriesPartialUTF8AndProjectsLegacyEOF() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        let record = try indexTitle("Generated 🧪 title")
        let emoji = try #require(record.range(of: Data("🧪".utf8)))
        let split = record.distance(from: record.startIndex, to: emoji.lowerBound) + 2
        try record.prefix(split).write(to: fixture.index)
        #expect(fixture.names().isEmpty)
        try fixture.append(Data(record.dropFirst(split).dropLast()))
        #expect(fixture.names()[id] == "Generated 🧪 title")
        try fixture.append(Data([10]) + indexTitle("After delimiter"))
        #expect(fixture.names()[id] == "After delimiter")
        #expect(fixture.names() == referenceIndex(fixture.index))
    }

    @Test func indexInvalidationMatchesColdParsing() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        try (indexTitle("First") + indexTitle("Other", id: otherID)).write(to: fixture.index)
        _ = fixture.names()
        let date = try #require(
            FileManager.default.attributesOfItem(atPath: fixture.index.path)[.modificationDate] as? Date)
        try (indexTitle("Fresh") + indexTitle("Other", id: otherID)).write(to: fixture.index)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fixture.index.path)
        #expect(fixture.names()[id] == "Fresh")
        #expect(fixture.names() == referenceIndex(fixture.index))
        try indexTitle("Short").write(to: fixture.index)
        #expect(fixture.names() == referenceIndex(fixture.index))
        #expect(fixture.names()[otherID] == nil)
        try indexTitle("Replacement").write(to: fixture.index, options: .atomic)
        #expect(fixture.names() == referenceIndex(fixture.index))
        try FileManager.default.removeItem(at: fixture.index)
        #expect(fixture.names().isEmpty)
    }

    @Test func growthValidatesTheEntireRetainedIndexWindow() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        let padding = Data(("{\"ignored\":\"" + String(repeating: "x", count: 1000) + "\"}\n").utf8)
        var prefix = Data()
        while prefix.count < 170 * 1024 { prefix.append(padding) }
        var suffix = Data()
        while suffix.count < 170 * 1024 { suffix.append(padding) }
        try (prefix + indexTitle("Old middle") + suffix).write(to: fixture.index)
        #expect(fixture.names()[id] == "Old middle")
        try (prefix + indexTitle("New middle") + suffix + indexTitle("Appended", id: otherID)).write(to: fixture.index)
        #expect(fixture.names()[id] == "New middle")
        #expect(fixture.names() == referenceIndex(fixture.index))
    }

    @Test func indexWindowEvictionRestoresTranscriptTitle() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        let transcript = fixture.sessions.appendingPathComponent("rollout.jsonl")
        try
            (codexHeader
            + Data(
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Transcript title\"}}\n"
                    .utf8)).write(to: transcript)
        try indexTitle("Index title").write(to: fixture.index)
        let first = NativeSessionScanner.scan(
            provider: .codex, root: fixture.sessions, cache: [:], ignoringCache: false, titleIndexCache: fixture.cache)
        #expect(first.sessions.first?.summary == "Index title")
        let padding = Data(("{\"ignored\":\"" + String(repeating: "x", count: 1000) + "\"}\n").utf8)
        var growth = Data()
        while growth.count < CodexTitleIndexCache.windowLimit { growth.append(padding) }
        try fixture.append(growth)
        let evicted = NativeSessionScanner.scan(
            provider: .codex, root: fixture.sessions, cache: first.cache, ignoringCache: false,
            titleIndexCache: fixture.cache)
        #expect(evicted.sessions.first?.summary == "Transcript title")
        #expect(fixture.names() == referenceIndex(fixture.index))
    }

    @Test func movingIndexWindowKeepsTheSameCompleteRecordBoundary() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        let padding = Data(("{\"ignored\":\"" + String(repeating: "x", count: 1000) + "\"}\n").utf8)
        var data = try indexTitle("Evicted")
        while data.count < CodexTitleIndexCache.windowLimit + 500 { data.append(padding) }
        data.append(try indexTitle("Retained", id: otherID))
        try data.write(to: fixture.index)
        #expect(fixture.names() == referenceIndex(fixture.index))
        for number in 0..<4 {
            try fixture.append(Data([10, 10]) + padding + indexTitle("New \(number)"))
            #expect(fixture.names()[id] == "New \(number)")
            #expect(fixture.names()[otherID] == "Retained")
            #expect(fixture.names() == referenceIndex(fixture.index))
        }
    }

    @Test func irrelevantPartialClaudeRecordStillReportsIncompleteHistory() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        let transcript = fixture.sessions.appendingPathComponent("generated-claude.jsonl")
        try (claudeHeader + Data("{\"type\":\"progress\",\"ignored\":".utf8)).write(to: transcript)
        let partial = NativeSessionScanner.scan(
            provider: .claudeCode, root: fixture.sessions, cache: [:], ignoringCache: false)
        #expect(partial.sessions.first?.summary == "First prompt")
        #expect(partial.notice != nil)
        try (claudeHeader + Data("{\"type\":\"progress\",\"ignored\":true}".utf8)).write(to: transcript)
        let complete = NativeSessionScanner.scan(
            provider: .claudeCode, root: fixture.sessions, cache: partial.cache, ignoringCache: false)
        #expect(complete.sessions.first?.summary == "First prompt")
        #expect(complete.notice == nil)
    }

    @Test func indexRejectsOversizedInvalidAndEscapedMalformedRecords() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        var data = try indexTitle("Valid")
        data.append(Data("{\"id\":\"\(id)\",\"thread_name\":\"\(String(repeating: "x", count: 17000))\"}\n".utf8))
        data.append(
            Data(
                "{\"id\":\"invalid\",\"thread_name\":\"Wrong\"}\n{\"id\":\"\(id)\",\"thread_name\":\"\"}\n{\"id\":\"\(id)\",\"thread_\\u006eame\":\"Escaped title\"}\n{\"id\":\"\(id)\",\"thread_name\":\"partial"
                    .utf8))
        try data.write(to: fixture.index)
        #expect(fixture.names()[id] == "Escaped title")
        #expect(fixture.names() == referenceIndex(fixture.index))
    }

    @Test func indexRaceAndCancellationKeepValidatedTitles() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        try indexTitle("Validated").write(to: fixture.index)
        #expect(fixture.names()[id] == "Validated")
        try fixture.append(indexTitle("Unpublished"))
        let cancelled = NativeSessionScanner.ContentReader(
            read: NativeSessionScanner.ContentReader.disk.read, isCancelled: { true })
        #expect(fixture.cache.names(at: fixture.index, reader: cancelled)[id] == "Validated")
        let replaced = OSAllocatedUnfairLock(initialState: false)
        let index = fixture.index
        let replacement = try indexTitle("Replacement")
        let racing = NativeSessionScanner.ContentReader(read: { handle, offset, count in
            let data = try NativeSessionScanner.ContentReader.disk.read(handle, offset, count)
            let first = replaced.withLock { flag in
                let old = flag
                flag = true
                return !old
            }
            if first { try replacement.write(to: index, options: .atomic) }
            return data
        })
        #expect(fixture.cache.names(at: fixture.index, reader: racing)[id] == "Validated")
        #expect(fixture.names()[id] == "Replacement")
        try FileManager.default.removeItem(at: fixture.index)
        #expect(fixture.cache.names(at: fixture.index, reader: cancelled)[id] == "Replacement")
        #expect(fixture.names().isEmpty)
    }

    @Test func indexSymlinkIsNeverReadAsAReplacement() throws {
        let fixture = try IndexSelectionFixture()
        defer { fixture.remove() }
        try indexTitle("Validated").write(to: fixture.index)
        _ = fixture.names()
        let target = fixture.root.appendingPathComponent("generated-target.jsonl")
        try indexTitle("Symlink title").write(to: target)
        try FileManager.default.removeItem(at: fixture.index)
        try FileManager.default.createSymbolicLink(at: fixture.index, withDestinationURL: target)
        let meter = RecordDecodeMeter()
        #expect(fixture.names(meter.decoder)[id] == "Validated")
        #expect(meter.counts().index == 0)
        #expect(CodexTitleIndexCache().names(at: fixture.index).isEmpty)
    }

    private var claudeHeader: Data {
        Data(
            "{\"type\":\"user\",\"sessionId\":\"\(id)\",\"cwd\":\"/tmp/project\",\"version\":\"2.1.283\",\"message\":{\"content\":\"First prompt\"}}\n"
                .utf8)
    }
    private var codexHeader: Data {
        Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/tmp/project\",\"cli_version\":\"0.160.0\"}}\n"
                .utf8)
    }
    private enum Outcome: Equatable {
        case session(GrokSession)
        case unsupported(String)
        case unrecognized
    }
    private func outcome(_ provider: CLIProvider, _ data: Data, _ decoder: NativeSessionRecordDecoder) -> Outcome {
        switch NativeSessionScanner.parseResult(
            provider: provider, data: data, file: file, modified: modified, decoder: decoder)
        {
        case .session(let row): return .session(row)
        case .unsupportedVersion(let version): return .unsupported(version)
        case .unrecognized: return .unrecognized
        }
    }
    private func indexTitle(_ title: String, id: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id ?? self.id, "thread_name": title], options: .sortedKeys)
            + Data([10])
    }
    private func referenceIndex(_ file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let start = max(0, data.count - CodexTitleIndexCache.windowLimit)
        var lines = data.suffix(from: start).split(separator: 10)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var names: [String: String] = [:]
        for line in lines where line.count < 16 * 1024 {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let id = object["id"] as? String, UUID(uuidString: id) != nil,
                let name = object["thread_name"] as? String, !name.isEmpty
            else { continue }
            names[id] = String(name.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        }
        return names
    }
}

private final class RecordDecodeMeter: Sendable {
    let value = OSAllocatedUnfairLock(initialState: (transcript: 0, index: 0))
    var decoder: NativeSessionRecordDecoder {
        NativeSessionRecordDecoder(didDecode: { source in
            self.value.withLock { counts in
                switch source {
                case .transcript: counts.transcript += 1
                case .codexTitleIndex: counts.index += 1
                }
            }
        })
    }
    func counts() -> (transcript: Int, index: Int) { value.withLock { $0 } }
}

private struct IndexSelectionFixture {
    let root: URL
    let cache = CodexTitleIndexCache()
    var sessions: URL { root.appendingPathComponent("sessions") }
    var index: URL { root.appendingPathComponent("session_index.jsonl") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rea-1268-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func names(_ decoder: NativeSessionRecordDecoder = .init()) -> [String: String] {
        cache.names(at: index, decoder: decoder)
    }
    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: index)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
