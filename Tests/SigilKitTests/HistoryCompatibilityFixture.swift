import Foundation

@testable import SigilKit

/// Generated transcripts only; all provider roots belong to this disposable directory.
struct HistoryCompatibilityFixture {
    let directory: URL
    let grok: URL
    let claude: URL
    let codex: URL
    static let firstID = "11111111-1111-4111-8111-111111111111"
    static let secondID = "22222222-2222-4222-8222-222222222222"
    static let cwd = "/tmp/generated-history-project"

    init(createProviderRoots: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Sigil-REA1264-\(UUID().uuidString)")
        grok = directory.appendingPathComponent("grok")
        claude = directory.appendingPathComponent("claude/projects")
        codex = directory.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if createProviderRoots {
            for root in [grok, claude, codex] {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func root(_ provider: CLIProvider) -> URL {
        switch provider {
        case .claudeCode: claude
        case .codex: codex
        default: grok
        }
    }

    @MainActor func store() -> SessionStore {
        SessionStore(root: grok, timing: SessionStoreTiming(), nativeRoots: [(.claudeCode, claude), (.codex, codex)])
    }

    @discardableResult
    func writeNative(
        provider: CLIProvider = .codex, id: String = HistoryCompatibilityFixture.firstID, version: String = "0.158.0",
        filename: String = "rollout.jsonl"
    ) throws -> URL {
        let object: [String: Any] =
            provider == .codex
            ? ["type": "session_meta", "payload": ["id": id, "cwd": Self.cwd, "cli_version": version]]
            : [
                "type": "user", "sessionId": id, "cwd": Self.cwd, "version": version,
                "message": ["content": "Generated"],
            ]
        let file = root(provider).appendingPathComponent(filename)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }

    @discardableResult
    func grokDirectory(
        id: String = HistoryCompatibilityFixture.firstID, cwd: String = HistoryCompatibilityFixture.cwd
    ) throws -> URL {
        let folder = GrokPaths.sessionFolderName(forCanonicalPath: GrokPaths.canonicalPath(cwd))
        let result = grok.appendingPathComponent(folder).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    @discardableResult
    func writeGrok(
        id: String = HistoryCompatibilityFixture.firstID, cwd: String = HistoryCompatibilityFixture.cwd
    ) throws -> URL {
        let result = try grokDirectory(id: id, cwd: cwd).appendingPathComponent("summary.json")
        try JSONSerialization.data(withJSONObject: ["info": ["id": id, "cwd": cwd], "session_summary": "Generated"])
            .write(to: result)
        return result
    }
}
