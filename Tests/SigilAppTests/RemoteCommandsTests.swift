import AppKit
import Foundation
import SigilKit
import Testing
import Vision

@testable import SigilApp

@Suite(.serialized)
struct RemoteCommandsTests {
    @Test @MainActor func controlsOnlyKnownTabsAndRejectsControlSequences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let received = root.appendingPathComponent("received")
        let executable = root.appendingPathComponent("fake-grok")
        let script = """
            #!/bin/sh
            stty -echo
            printf '\\033[?1hREMOTE_READY\\n'
            while IFS= read -r line; do
                printf '%s' "$line" > '\(received.path)'
                printf 'RECEIVED:%s\\n' "$line"
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "sigil-remote-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        let model = AppModel(settings: settings, presentError: { _ in })
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: root))
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("REMOTE_READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("REMOTE_READY"))
        func command(_ action: String, text: String? = nil, tabID: String? = nil) -> RemoteReply {
            RemoteCommands.execute(
                RemoteRequest(
                    challenge: "test", sequence: 1, action: action, tabID: tabID ?? tab.id.uuidString, text: text),
                model: model)
        }
        #expect(!command("input", text: "\u{1b}[201~injected\r").ok)
        #expect(!command("input", text: "hello", tabID: UUID().uuidString).ok)
        #expect(!command("key", text: "shell").ok)
        #expect(!command("delete").ok)
        #expect(!command("input", text: "first\nsecond").ok)
        #expect(command("input", text: "phone-test").ok)
        #expect(command("key", text: "enter").ok)
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("phone-test") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("phone-test"))
        #expect(try String(contentsOf: received, encoding: .utf8) == "phone-test")
        let reply = command("state")
        #expect(reply.state?.tabs.first?.id == tab.id.uuidString)
        #expect(reply.state?.terminal.contains("phone-test") == true)
        #expect(command("key", text: "up").ok)
        #expect(command("key", text: "enter").ok)
        for _ in 0..<100 {
            if (try? String(contentsOf: received, encoding: .utf8)) == "\u{1b}OA" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: received, encoding: .utf8) == "\u{1b}OA")
        tab.terminateAndWait()
        #expect(!command("input", text: "after exit").ok)
    }

    @Test @MainActor func fileChunksWriteToTheDropCacheAndPasteThePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let received = root.appendingPathComponent("received")
        let executable = root.appendingPathComponent("fake-grok")
        let script = """
            #!/bin/sh
            stty -echo
            printf '\\033[?1hREMOTE_READY\\n'
            while IFS= read -r line; do
                printf '%s' "$line" > '\(received.path)'
                printf 'RECEIVED:%s\\n' "$line"
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "sigil-remote-file-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.executablePath = executable.path
        settings.defaultDirectory = root.path
        let model = AppModel(settings: settings, presentError: { _ in })
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: root))
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("REMOTE_READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("REMOTE_READY"))
        RemoteCommands.uploads = RemoteUpload.Inbox()
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
            ))
        let reply = RemoteCommands.execute(
            RemoteRequest(
                challenge: "test", sequence: 1, action: "file", tabID: tab.id.uuidString,
                text: png.base64EncodedString(), name: "shot.png", index: 0, count: 1,
                transfer: String(repeating: "ef", count: 16)),
            model: model)
        #expect(reply.ok)
        #expect(
            RemoteCommands.execute(
                RemoteRequest(challenge: "test", sequence: 2, action: "key", tabID: tab.id.uuidString, text: "enter"),
                model: model
            ).ok)
        for _ in 0..<100 {
            if (try? String(contentsOf: received, encoding: .utf8))?.contains(".png") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pasted = try String(contentsOf: received, encoding: .utf8)
        #expect(pasted.contains(".png"))
        #expect(pasted.hasSuffix(" ") || pasted.contains(".png "))
        #expect(FileManager.default.fileExists(atPath: pasted.trimmingCharacters(in: .whitespaces)))
        tab.terminateAndWait()
    }

    @Test @MainActor func qrIsDecodableAndURLValidationIsStrict() throws {
        for address in [
            "https://example.com/path", "https://user:password@example.com", "https://example.com?token=x",
            "https://example.com/#key=x", "http://192.168.1.5", "file:///tmp/a",
        ] {
            #expect(RemoteControl.origin(address) == nil)
        }
        #expect(RemoteControl.origin("https://example.com/")?.absoluteString == "https://example.com")
        #expect(RemoteControl.origin(RemoteControl.productionOrigin)?.absoluteString == RemoteControl.productionOrigin)
        #expect(RemoteControl.productionOrigin == "https://remote.sigilapp.dev")
        #expect(RemoteControl.preferredOrigin(RemoteControl.legacyRailwayOrigin) == RemoteControl.productionOrigin)
        #expect(
            RemoteControl.preferredOrigin("https://sidereal-production-587c.up.railway.app/")
                == RemoteControl.productionOrigin)
        #expect(
            RemoteControl.preferredOrigin("  https://sidereal-production-587c.up.railway.app  ")
                == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin(RemoteControl.legacyApexOrigin) == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://sigilapp.dev/") == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://SIGILAPP.DEV") == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://sigilapp.dev:443") == RemoteControl.productionOrigin)
        #expect(RemoteControl.origin("https://SIGILAPP.DEV")?.absoluteString == RemoteControl.legacyApexOrigin)
        #expect(RemoteControl.origin("https://sigilapp.dev:443")?.absoluteString == RemoteControl.legacyApexOrigin)
        #expect(RemoteControl.preferredOrigin(RemoteControl.productionOrigin) == RemoteControl.productionOrigin)
        #expect(RemoteControl.preferredOrigin("https://example.com") == "https://example.com")
        let value =
            "https://example.com/#room=\(String(repeating: "a", count: 32))&key=\(String(repeating: "b", count: 64))"
        let image = try #require(RemoteControlView.qrImage(value))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        #expect(request.results?.first?.payloadStringValue == value)
    }

    @Test @MainActor func visibleTabsKeepsASelectedTabBeyondTheFirstHundred() {
        let tabs = (0..<101).map { RemoteState.Tab(id: "tab-\($0)", title: "Tab \($0)", status: "idle") }
        let visible = RemoteCommands.visibleTabs(tabs, selectedID: "tab-100")
        #expect(visible.count == 100)
        #expect(visible.last?.id == "tab-100")
        #expect(Set(visible.map(\.id)).count == 100)
        #expect(visible.prefix(99).map(\.id) == tabs.prefix(99).map(\.id))
        #expect(tabs.count == 101)
        let few = Array(tabs.prefix(50))
        #expect(RemoteCommands.visibleTabs(few, selectedID: "tab-10").map(\.id) == few.map(\.id))
        #expect(RemoteCommands.visibleTabs(few, selectedID: "missing").map(\.id) == few.map(\.id))
    }

    @Test @MainActor func boundedStringsCutOnScalarBoundariesWithoutReplacementCharacters() {
        let cut = RemoteCommands.bounded(String(repeating: "é", count: 60), bytes: 97)
        #expect(cut == String(repeating: "é", count: 48))
        #expect(!cut.contains("\u{FFFD}"))
        #expect(cut.utf8.count <= 97)
        let tail = RemoteCommands.boundedSuffix("start-" + String(repeating: "\u{1D11E}", count: 10), bytes: 18)
        #expect(tail == String(repeating: "\u{1D11E}", count: 4))
        #expect(!tail.contains("\u{FFFD}"))
        #expect(tail.utf8.count <= 18)
        #expect(RemoteCommands.bounded("héllo", bytes: 3) == "hé")
        #expect(RemoteCommands.bounded("short", bytes: 96) == "short")
        #expect(RemoteCommands.boundedSuffix("end", bytes: 12_000) == "end")
        #expect(RemoteCommands.bounded("abc", bytes: 0) == "")
        #expect(RemoteCommands.boundedSuffix("abc", bytes: 0) == "")
    }

    @Test @MainActor func stopRevokesPendingStartup() async {
        let remote = RemoteControl(store: InMemoryRemotePairingStore())
        let model = AppModel(pairingStore: InMemoryRemotePairingStore())
        remote.start(urlText: "http://127.0.0.1:1", model: model)
        remote.stop()
        await Task.yield()
        #expect(!remote.isEnabled)
        #expect(remote.pairingURL == nil)
        #expect(remote.error == nil)
    }
}
