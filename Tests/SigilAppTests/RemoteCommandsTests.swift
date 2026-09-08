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

    @Test @MainActor func qrIsDecodableAndURLValidationIsStrict() throws {
        for address in [
            "https://example.com/path", "https://user:password@example.com", "https://example.com?token=x",
            "https://example.com/#key=x", "http://192.168.1.5", "file:///tmp/a",
        ] {
            #expect(RemoteControl.origin(address) == nil)
        }
        #expect(RemoteControl.origin("https://example.com/")?.absoluteString == "https://example.com")
        let value =
            "https://example.com/#room=\(String(repeating: "a", count: 32))&key=\(String(repeating: "b", count: 64))"
        let image = try #require(RemoteControlView.qrImage(value))
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: cg).perform([request])
        #expect(request.results?.first?.payloadStringValue == value)
    }

    @Test @MainActor func stopRevokesPendingStartup() async {
        let remote = RemoteControl()
        let model = AppModel()
        remote.start(urlText: "http://127.0.0.1:1", model: model)
        remote.stop()
        await Task.yield()
        #expect(!remote.isEnabled)
        #expect(remote.pairingURL == nil)
        #expect(remote.error == nil)
    }
}
