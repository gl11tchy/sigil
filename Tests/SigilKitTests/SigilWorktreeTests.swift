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

    @Test func pristineUnusedRollbackRemovesOnlyItsAttempt() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let unrelated = fixture.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let first = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "first"))
        let second = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "second"))
        #expect(await SigilWorktree.rollback(first, processMayHaveStarted: false) == .removed)
        #expect(!FileManager.default.fileExists(atPath: first.checkout.path))
        #expect(try git(["branch", "--list", first.branch], in: fixture.repo).isEmpty)
        #expect(FileManager.default.fileExists(atPath: second.checkout.path))
        #expect(try git(["branch", "--list", second.branch], in: fixture.repo).contains(second.branch))
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        #expect(await SigilWorktree.rollback(second, processMayHaveStarted: false) == .removed)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func rollbackRemovesItsNewEmptyParents() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "new"))
        #expect(await SigilWorktree.rollback(made, processMayHaveStarted: false) == .removed)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test(arguments: ["tracked", "untracked", "ignored"])
    func rollbackPreservesEveryKindOfFileChange(kind: String) async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "changed"))
        let path = made.checkout.appendingPathComponent(kind == "tracked" ? "file.txt" : kind + ".txt")
        try Data("new work".utf8).write(to: path)
        let result = await SigilWorktree.rollback(made, processMayHaveStarted: false)
        #expect(result.recoveryMessage?.contains(made.checkout.path) == true)
        #expect(result.recoveryMessage?.contains(made.branch) == true)
        #expect(try Data(contentsOf: path) == Data("new work".utf8))
        #expect(try git(["branch", "--list", made.branch], in: fixture.repo).contains(made.branch))
    }

    @Test func rollbackPreservesMovedBranchesAndCommits() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "moved"))
        try git(
            ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "keep"],
            in: made.checkout)
        let moved = try git(["rev-parse", "HEAD"], in: made.checkout)
        #expect(moved != made.originalHead)
        #expect(await SigilWorktree.rollback(made, processMayHaveStarted: false).recoveryMessage != nil)
        #expect(try git(["rev-parse", "refs/heads/" + made.branch], in: fixture.repo) == moved)
        #expect(FileManager.default.fileExists(atPath: made.checkout.path))
    }

    @Test func possibleProcessStartNeverAllowsRollback() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "uncertain"))
        let result = await SigilWorktree.rollback(made, processMayHaveStarted: true)
        #expect(result.recoveryMessage?.contains("process may have started") == true)
        #expect(FileManager.default.fileExists(atPath: made.checkout.path))
        #expect(try git(["branch", "--list", made.branch], in: fixture.repo).contains(made.branch))
    }

    @Test func nonForceCleanupFailureKeepsCheckoutAndReportsRecovery() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "locked"))
        try git(["worktree", "lock", made.checkout.path], in: fixture.repo)
        let result = await SigilWorktree.rollback(made, processMayHaveStarted: false)
        #expect(result.recoveryMessage?.contains("Git could not remove") == true)
        #expect(result.recoveryMessage?.contains(made.checkout.path) == true)
        #expect(FileManager.default.fileExists(atPath: made.checkout.path))
        #expect(try git(["branch", "--list", made.branch], in: fixture.repo).contains(made.branch))
    }

    @Test(arguments: [false, true])
    func collisionsPreserveExistingFoldersAndBranches(branchCollision: Bool) async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let checkout = fixture.root.appendingPathComponent(GrokPaths.encode(path: fixture.repo.path))
            .appendingPathComponent("taken")
        if branchCollision {
            try git(["branch", "sigil/taken"], in: fixture.repo)
        } else {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try Data("unrelated".utf8).write(to: checkout.appendingPathComponent("keep"))
        }
        await #expect(throws: SigilWorktree.Failure.self) {
            _ = try await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "taken")
        }
        if branchCollision {
            #expect(
                try git(["rev-parse", "sigil/taken"], in: fixture.repo) == git(["rev-parse", "HEAD"], in: fixture.repo))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        } else {
            #expect(try Data(contentsOf: checkout.appendingPathComponent("keep")) == Data("unrelated".utf8))
            #expect(try git(["branch", "--list", "sigil/*"], in: fixture.repo).isEmpty)
        }
    }

    @Test func replacedCheckoutIdentityNeverAllowsRollback() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "replaced"))
        let original = fixture.base.appendingPathComponent("original")
        try FileManager.default.moveItem(at: made.checkout, to: original)
        try FileManager.default.createDirectory(at: made.checkout, withIntermediateDirectories: false)
        let keep = made.checkout.appendingPathComponent("keep")
        try Data("replacement".utf8).write(to: keep)
        #expect(await SigilWorktree.rollback(made, processMayHaveStarted: false).recoveryMessage != nil)
        #expect(try Data(contentsOf: keep) == Data("replacement".utf8))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func rollbackPreservesABranchAlsoReferencedByAnotherCheckout() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let made = try #require(
            await SigilWorktree.createAttempt(for: fixture.repo, root: fixture.root, name: "shared"))
        let other = fixture.base.appendingPathComponent("other")
        try git(["worktree", "add", "--detach", other.path, made.originalHead], in: fixture.repo)
        try git(["symbolic-ref", "HEAD", "refs/heads/" + made.branch], in: other)
        #expect(await SigilWorktree.rollback(made, processMayHaveStarted: false).recoveryMessage != nil)
        #expect(FileManager.default.fileExists(atPath: made.checkout.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(try git(["branch", "--list", made.branch], in: fixture.repo).contains(made.branch))
    }

    @Test func committedSubfolderThroughASymlinkKeepsTheSelectedFolder() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let sub = fixture.repo.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        try Data("package".utf8).write(to: sub.appendingPathComponent("file"))
        try git(["add", "."], in: fixture.repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "package"], in: fixture.repo)
        let link = fixture.base.appendingPathComponent("selected-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)
        let made = try #require(await SigilWorktree.createAttempt(for: link, root: fixture.root, name: "linked"))
        #expect(made.workingDirectory == made.checkout.appendingPathComponent("package"))
        #expect(try Data(contentsOf: made.workingDirectory.appendingPathComponent("file")) == Data("package".utf8))
        #expect(await SigilWorktree.rollback(made, processMayHaveStarted: false) == .removed)
    }

    @Test func homeRepositoryIsRecognizedButDoesNotDefaultToAWorktree() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")
        let project = home.appendingPathComponent("projects/app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try git(["init", "-q"], in: home)
        #expect(SigilWorktree.isInRepository(project))
        #expect(!SigilWorktree.shouldDefaultToWorktree(project, home: home))
        let link = base.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        #expect(!SigilWorktree.shouldDefaultToWorktree(link.appendingPathComponent("projects/app"), home: link))
        try git(["init", "-q"], in: project)
        #expect(SigilWorktree.shouldDefaultToWorktree(project, home: home))
    }

    @Test func submoduleSelectionBranchesFromTheSubmodulesOwnRepository() async throws {
        let fixture = try WorktreeFixture()
        defer { fixture.cleanup() }
        let source = fixture.base.appendingPathComponent("submodule-source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: source.appendingPathComponent("child.txt"))
        try git(["init", "-q"], in: source)
        try git(["add", "."], in: source)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "child"], in: source)
        try git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, "child"], in: fixture.repo)
        let selected = fixture.repo.appendingPathComponent("child")
        let made = try #require(await SigilWorktree.createAttempt(for: selected, root: fixture.root, name: "child"))
        #expect(made.repository.path == GrokPaths.canonicalPath(selected.path))
        #expect(try Data(contentsOf: made.workingDirectory.appendingPathComponent("child.txt")) == Data("child".utf8))
        #expect(await SigilWorktree.rollback(made, processMayHaveStarted: false) == .removed)
    }
}

private struct WorktreeFixture {
    let base: URL
    let repo: URL
    let root: URL

    init() throws {
        base = try scratch()
        repo = base.appendingPathComponent("repo")
        root = base.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: repo.appendingPathComponent("file.txt"))
        try Data("ignored.txt\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try git(["init", "-q"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
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
    guard process.terminationStatus == 0 else {
        throw SigilWorktree.Failure(message: "Fixture git failed: \(arguments)")
    }
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
