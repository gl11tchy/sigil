import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
struct RemoteIntegrationTests {
    @Test @MainActor func pairsOverRelayAndRevokesOnStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let server = Process()
        defer {
            if server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
        }
        let origin: String
        let phoneOrigin: String
        if let external = ProcessInfo.processInfo.environment["SIGIL_REMOTE_TEST_ORIGIN"] {
            let url = try #require(RemoteControl.origin(external))
            #expect(url.scheme == "https")
            origin = url.absoluteString
            phoneOrigin = origin
        } else {
            let portFile = root.appendingPathComponent("port")
            server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            server.arguments = ["node", repo.appendingPathComponent("Sidereal/test/relay-fixture.mjs").path]
            server.environment = ProcessInfo.processInfo.environment.merging(["SIGIL_TEST_PORT_FILE": portFile.path]) {
                _, new in new
            }
            server.standardOutput = FileHandle.nullDevice
            server.standardError = FileHandle.nullDevice
            try server.run()
            for _ in 0..<200 {
                if FileManager.default.fileExists(atPath: portFile.path) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let port = try String(contentsOf: portFile, encoding: .utf8)
            origin = "http://127.0.0.1:\(port)"
            phoneOrigin = "http://localhost:3099"
        }
        let defaultsName = "sigil-remote-integration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let executable = root.appendingPathComponent("fake-grok")
        try Data(
            "#!/bin/sh\nstty -echo\nprintf 'RELAY_READY\\n'\nwhile IFS= read -r line; do printf 'RELAY:%s\\n' \"$line\"; done\n"
                .utf8
        ).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let settings = AppSettings(defaults: defaults)
        settings.executablePath = executable.path
        let pairingStore = InMemoryRemotePairingStore()
        let model = AppModel(
            settings: settings, presentError: { _ in }, pairingStore: pairingStore,
            providerInstallations: fixtureProviderInstallations(executable))
        defer { model.closeAllTabsAndWait() }
        let tab = try #require(model.newTab(in: root))
        for _ in 0..<100 {
            if tab.controller.remoteSnapshot().contains("RELAY_READY") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.controller.remoteSnapshot().contains("RELAY_READY"))
        model.remoteControl.start(urlText: origin, model: model)
        for _ in 0..<200 {
            if model.remoteControl.pairingURL != nil || model.remoteControl.error != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.remoteControl.error == nil)
        let link = try #require(model.remoteControl.pairingURL)
        let fragment = try #require(URLComponents(url: link, resolvingAgainstBaseURL: false)?.fragment)
        var parts = URLComponents()
        parts.query = fragment
        let room = try #require(parts.queryItems?.first { $0.name == "room" }?.value)
        let bootstrap = try #require(parts.queryItems?.first { $0.name == "key" }?.value)
        let network = URLSession(configuration: .ephemeral)
        defer { network.invalidateAndCancel() }
        var endpoint = try #require(URLComponents(string: origin))
        endpoint.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        endpoint.path = "/connect"
        endpoint.queryItems = [URLQueryItem(name: "role", value: "phone")]
        var request = URLRequest(url: try #require(endpoint.url))
        request.setValue(phoneOrigin, forHTTPHeaderField: "Origin")
        let phone = network.webSocketTask(with: request)
        phone.resume()
        defer { phone.cancel(with: .goingAway, reason: nil) }
        // Bounds receive even if the host never answers.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { phone.cancel(with: .goingAway, reason: nil) }
        }
        defer { timeout.cancel() }
        let routeHello = try await receive(phone)
        try await send(
            [
                "route": RemoteCrypto.seal(
                    ["room": room], key: try #require(routeHello["route"]), direction: "relay-phone")
            ], phone)
        let hello = try await receive(phone)
        let challenge = try #require(hello["hello"])
        let device = RemoteCrypto.randomKey()
        let pair = RemoteRequest(challenge: challenge, sequence: 1, action: "pair", text: device)
        let ciphertext = try RemoteCrypto.seal(pair, key: bootstrap, direction: "phone")
        try await send(["data": ciphertext], phone)
        let pairFrame = try await receive(phone)
        let pairReply: RemoteReply = try RemoteCrypto.open(
            try #require(pairFrame["data"]), key: device, direction: "mac")
        #expect(pairReply.ok)
        #expect(pairReply.state?.tabs.first?.id == tab.id.uuidString)
        let ticket = try #require(pairReply.ticket)
        #expect(RemoteCrypto.isValidKey(ticket))
        #expect(model.remoteControl.isPaired)
        #expect(model.remoteControl.pairingURL == nil)
        for command in [
            RemoteRequest(
                challenge: challenge, sequence: 2, action: "input", tabID: tab.id.uuidString,
                text: "encrypted-phone-input"),
            RemoteRequest(challenge: challenge, sequence: 3, action: "key", tabID: tab.id.uuidString, text: "enter"),
        ] {
            try await send(["data": RemoteCrypto.seal(command, key: device, direction: "phone")], phone)
            let frame = try await receive(phone)
            let reply: RemoteReply = try RemoteCrypto.open(try #require(frame["data"]), key: device, direction: "mac")
            #expect(reply.ok)
        }
        var output = ""
        for sequence in 4..<104 {
            let state = RemoteRequest(challenge: challenge, sequence: sequence, action: "state")
            try await send(["data": RemoteCrypto.seal(state, key: device, direction: "phone")], phone)
            let frame = try await receive(phone)
            let reply: RemoteReply = try RemoteCrypto.open(try #require(frame["data"]), key: device, direction: "mac")
            output = reply.state?.terminal ?? ""
            if output.contains("RELAY:encrypted-phone-input") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(output.contains("RELAY:encrypted-phone-input"))
        model.remoteControl.stop()
        do {
            _ = try await phone.receive()
            Issue.record("Phone remained connected after the Mac closed the socket")
        } catch {}
        #expect(!model.remoteControl.isEnabled)
        #expect(pairingStore.load() != nil)
        model.remoteControl.start(urlText: origin, model: model)
        #expect(model.remoteControl.isPaired)
        for _ in 0..<200 {
            if model.remoteControl.status == "Phone disconnected" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.remoteControl.status == "Phone disconnected")
        endpoint.queryItems = [URLQueryItem(name: "role", value: "phone")]
        #expect(endpoint.query == "role=phone")
        var restoredRequest = URLRequest(url: try #require(endpoint.url))
        restoredRequest.setValue(phoneOrigin, forHTTPHeaderField: "Origin")
        let restored = network.webSocketTask(with: restoredRequest)
        restored.resume()
        defer { restored.cancel(with: .goingAway, reason: nil) }
        let restoredRoute = try await receive(restored)
        try await send(
            [
                "route": RemoteCrypto.seal(
                    ["ticket": ticket], key: try #require(restoredRoute["route"]), direction: "relay-phone")
            ], restored)
        let restoredHello = try await receive(restored)
        let restoredChallenge = try #require(restoredHello["hello"])
        try await send(
            [
                "data": RemoteCrypto.seal(
                    RemoteRequest(challenge: restoredChallenge, sequence: 1, action: "state"), key: device,
                    direction: "phone")
            ], restored)
        let restoredFrame = try await receive(restored)
        let restoredReply: RemoteReply = try RemoteCrypto.open(
            try #require(restoredFrame["data"]), key: device, direction: "mac")
        #expect(restoredReply.ok)
        #expect(restoredReply.ticket == ticket)
        model.remoteControl.stop(revoke: true)
        #expect(pairingStore.load() == nil)
        #expect(!model.remoteControl.isEnabled)
    }

    private func send(_ frame: [String: String], _ socket: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(frame)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws -> [String: String] {
        let message = try await socket.receive()
        let bytes: Data
        switch message {
        case .string(let text): bytes = Data(text.utf8)
        case .data(let data): bytes = data
        @unknown default: throw RemoteError.invalidMessage
        }
        return try JSONDecoder().decode([String: String].self, from: bytes)
    }
}
