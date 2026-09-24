import Foundation
import Testing

@testable import SigilKit

struct SigilWorktreeTests {
    @Test func projectPathDecodesTheEncodedFolder() {
        let root = URL(fileURLWithPath: "/Users/me/.sigil/worktrees")
        let folder = GrokPaths.encode(path: "/Users/me/code/app")
        #expect(
            SigilWorktree.projectPath(of: "/Users/me/.sigil/worktrees/\(folder)/ab12cd34", root: root)
                == "/Users/me/code/app")
        #expect(
            SigilWorktree.projectPath(of: "/Users/me/.sigil/worktrees/\(folder)/ab12cd34/web", root: root)
                == "/Users/me/code/app")
        #expect(SigilWorktree.projectPath(of: "/Users/me/code/app", root: root) == nil)
        #expect(SigilWorktree.projectPath(of: "/Users/me/.sigil/worktrees/\(folder)", root: root) == nil)
        #expect(SigilWorktree.projectPath(of: "/Users/me/.sigil/worktrees/plain/x", root: root) == nil)
    }

    @Test func createAddsABranchCheckoutInTheSameSubfolder() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        let sub = repo.appendingPathComponent("web")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("file.txt"))
        try git(["init", "-q"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)

        let root = base.appendingPathComponent("worktrees")
        let made = try #require(await SigilWorktree.create(for: sub, root: root, name: "abc"))
        #expect(made.lastPathComponent == "web")
        #expect(FileManager.default.fileExists(atPath: made.appendingPathComponent("file.txt").path))
        #expect(SigilWorktree.projectPath(of: made.path, root: root) == GrokPaths.canonicalPath(sub.path))
        let branch = try git(["rev-parse", "--abbrev-ref", "HEAD"], in: made)
        #expect(branch == "sigil/abc")
        #expect(SigilWorktree.isInRepository(sub))
    }

    @Test func createReturnsNilOutsideARepository() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("worktrees")
        #expect(try await SigilWorktree.create(for: base, root: root) == nil)
        #expect(!SigilWorktree.isInRepository(base))
    }

    @Test func createReportsGitFailures() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        try git(["init", "-q"], in: base)
        // No commit yet, so there is no HEAD to branch from.
        await #expect(throws: SigilWorktree.Failure.self) {
            _ = try await SigilWorktree.create(for: base, root: base.appendingPathComponent("wt"))
        }
    }
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sigil-worktree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: GrokPaths.canonicalPath(url.path))
}

@discardableResult
private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
