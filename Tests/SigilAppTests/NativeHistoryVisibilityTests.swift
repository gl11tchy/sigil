import AppKit
import Foundation
import Testing

@testable import SigilApp
@testable import SigilKit

@MainActor
struct NativeHistoryVisibilityTests {
    @Test func discoveredMultimodalHistoryAppearsOnDesktopAndPhoneButMetadataOnlyDoesNot() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "11111111-1111-4111-8111-111111111111"
        let emptyID = "22222222-2222-4222-8222-222222222222"
        let data = Data(
            """
            {"type":"user","sessionId":"\(id)","cwd":"\(root.path)","version":"2.1.283","message":{"content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"fixture"}}]}}
            """.utf8)
        let empty = Data(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(emptyID)\",\"cwd\":\"\(root.path)\",\"cli_version\":\"0.157.1\"}}\n"
                .utf8)
        let shown = try #require(
            NativeSessionScanner.parse(
                provider: .claudeCode, data: data, file: root.appendingPathComponent("claude.jsonl"), modified: Date()))
        let hidden = try #require(
            NativeSessionScanner.parse(
                provider: .codex, data: empty, file: root.appendingPathComponent("codex.jsonl"), modified: Date()))
        #expect(shown.summary.isEmpty && shown.hasObservedMessages)
        #expect(!hidden.hasObservedMessages)
        let store = SessionStore(
            root: root, timing: SessionStoreTiming(),
            scanOperation: { _, _, _ in
                .init(sessions: [shown, hidden], cache: [:], loadError: nil)
            })
        await store.reload()
        let suite = "NativeHistoryVisibilityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.showEmptySessions = false
        settings.showWorktreeSessions = true
        let model = AppModel(
            settings: settings, store: store, presentError: { _ in }, panel: RightPanel(defaults: defaults),
            pairingStore: InMemoryRemotePairingStore())
        #expect(model.sidebarSessions.map(\.id) == [shown.id])
        #expect(model.sidebarSessions.first?.title.hasPrefix("Untitled session in") == true)
        let reply = await RemoteCommands.execute(.init(challenge: "test", sequence: 1, action: "chats"), model: model)
        #expect(reply.chats?.map(\.id) == [shown.id])
    }
}
