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

    @Test func createHandlesSpacesSymlinksAndChattyHooks() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent(" spaced repo ")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: repo.appendingPathComponent("file.txt"))
        try git(["init", "-q"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
        try Data("#!/bin/sh\nhead -c 300000 /dev/zero | tr '\\0' x\nhead -c 300000 /dev/zero | tr '\\0' y >&2\n".utf8)
            .write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)

        #expect(SigilWorktree.isInRepository(link))
        let made = try #require(
            await SigilWorktree.create(for: link, root: base.appendingPathComponent("wt"), name: "sp"))
        #expect(FileManager.default.fileExists(atPath: made.appendingPathComponent("file.txt").path))
    }

    @Test func createReturnsNilOutsideARepository() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("worktrees")
        #expect(try await SigilWorktree.create(for: base, root: root) == nil)
        #expect(!SigilWorktree.isInRepository(base))
    }

    @Test(arguments: [false, true])
    func missingChosenSubfolderIsRejectedBeforeCreatingResources(ignored: Bool) async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        let selected = repo.appendingPathComponent("chosen package")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        if ignored {
            try Data("chosen package/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
            try git(["add", ".gitignore"], in: repo)
        }
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let root = base.appendingPathComponent("worktrees")
        do {
            _ = try await SigilWorktree.create(for: selected, root: root, name: "missing")
            Issue.record("A selected folder absent from HEAD must not start at the checkout root")
        } catch let error as SigilWorktree.Failure {
            #expect(error.message.contains(selected.path))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try git(["branch", "--list", "sigil/*"], in: repo).isEmpty)
    }

    @Test func unbornRepositoryCreatesNoWorktreeParentOrBranch() async throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q"], in: repo)
        let root = base.appendingPathComponent("worktrees")
        await #expect(throws: SigilWorktree.Failure.self) {
            _ = try await SigilWorktree.create(for: repo, root: root, name: "unborn")
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try git(["branch", "--list", "sigil/*"], in: repo).isEmpty)
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
