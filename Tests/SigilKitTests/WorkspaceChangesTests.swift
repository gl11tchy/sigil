import Foundation
import Testing

@testable import SigilKit

struct WorkspaceChangesTests {
    @Test func statusParsingCoversRenamesUntrackedConflictsAndSpaces() {
        let raw = [
            " M src/a file.swift", "R  new.txt", "old.txt", "?? notes/todo.md", "A  added.txt",
            " D gone.txt", "UU both.txt", "AA also.txt", "!! ignored.log", "C  copy.txt", "orig.txt",
            "T  link",
        ].joined(separator: "\0") + "\0"
        let entries = WorkspaceChangesReader.parseStatus(Data(raw.utf8))
        #expect(
            entries == [
                .init(path: "src/a file.swift", oldPath: nil, status: .modified),
                .init(path: "new.txt", oldPath: "old.txt", status: .renamed),
                .init(path: "notes/todo.md", oldPath: nil, status: .untracked),
                .init(path: "added.txt", oldPath: nil, status: .added),
                .init(path: "gone.txt", oldPath: nil, status: .deleted),
                .init(path: "both.txt", oldPath: nil, status: .conflicted),
                .init(path: "also.txt", oldPath: nil, status: .conflicted),
                .init(path: "copy.txt", oldPath: "orig.txt", status: .copied),
                .init(path: "link", oldPath: nil, status: .typeChanged),
            ])
    }

    @Test func numstatParsingCountsRenamesAndLeavesBinaryUncounted() {
        let raw = ["3\t1\tsrc/a.swift", "-\t-\timage.png", "2\t0\t", "old.txt", "new.txt"]
            .joined(separator: "\0") + "\0"
        let counts = WorkspaceChangesReader.parseNumstat(Data(raw.utf8))
        #expect(counts["src/a.swift"]?.added == 3)
        #expect(counts["src/a.swift"]?.removed == 1)
        #expect(counts["image.png"] != nil)
        #expect(counts["image.png"]?.added == nil)
        #expect(counts["new.txt"]?.added == 2)
        #expect(counts["old.txt"] == nil)
    }

    @Test func readsARealRepository() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "bye\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)

        try "one\nTWO\nthree\nfour\n".write(
            to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("b.txt"))
        try "new\n".write(to: repo.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
        try git(["add", "staged.txt"], in: repo)
        try "loose\n".write(to: repo.appendingPathComponent("loose file.txt"), atomically: true, encoding: .utf8)

        let reading = await WorkspaceChangesReader.read(repo)
        guard case .changes(let changes) = reading else {
            Issue.record("expected changes, got \(reading)")
            return
        }
        #expect(changes.head == "main")
        let byPath = Dictionary(uniqueKeysWithValues: changes.files.map { ($0.path, $0) })
        #expect(byPath["a.txt"]?.status == .modified)
        #expect(byPath["a.txt"]?.added == 2)
        #expect(byPath["a.txt"]?.removed == 1)
        #expect(byPath["b.txt"]?.status == .deleted)
        #expect(byPath["b.txt"]?.removed == 1)
        #expect(byPath["staged.txt"]?.status == .added)
        #expect(byPath["staged.txt"]?.added == 1)
        #expect(byPath["loose file.txt"]?.status == .untracked)
        #expect(byPath["loose file.txt"]?.added == nil)
        #expect(changes.added == 3)
        #expect(changes.removed == 2)
        #expect(!changes.isTruncated)
        // Reading never leaves an index lock behind for the agent to trip on.
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))
    }

    @Test func readsARepositoryWithNoCommitYet() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["init", "-q", "-b", "trunk"], in: repo)
        try "x\ny\n".write(to: repo.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try git(["add", "first.txt"], in: repo)

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(changes.head == "trunk")
        #expect(changes.files.map(\.path) == ["first.txt"])
        #expect(changes.files.first?.status == .added)
        #expect(changes.files.first?.added == 2)
    }

    @Test func cleanRepositoryHasNoFiles() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "a\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try git(["checkout", "-q", "--detach"], in: repo)

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(changes.files.isEmpty)
        #expect(changes.head?.hasPrefix("detached at ") == true)
    }

    @Test func plainAndMissingFoldersSayWhy() async throws {
        let plain = try scratch()
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(await WorkspaceChangesReader.read(plain) == .notRepository)
        #expect(await WorkspaceChangesReader.read(plain.appendingPathComponent("nope")) == .missingFolder)
    }

    @Test func aGitThatCannotRunFailsInsteadOfHanging() async throws {
        let plain = try scratch()
        defer { try? FileManager.default.removeItem(at: plain) }
        let missing = URL(fileURLWithPath: "/nonexistent/git")
        #expect(await WorkspaceChangesReader.read(plain, git: missing) == .failed("Git did not answer."))

        let slow = plain.appendingPathComponent("slow-git")
        try "#!/bin/sh\nsleep 5\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        let reading = await WorkspaceChangesReader.read(plain, git: slow, timeout: .milliseconds(200))
        #expect(reading == .failed("Git did not answer."))
    }

    @Test func gitRunsWithoutLocksPromptsOrAnInheritedRepository() {
        let env = GitOutput.environment(["GIT_DIR": "/elsewhere", "GIT_WORK_TREE": "/x", "PATH": "/usr/bin"])
        #expect(env["GIT_DIR"] == nil)
        #expect(env["GIT_WORK_TREE"] == nil)
        #expect(env["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(env["GIT_TERMINAL_PROMPT"] == "0")
        #expect(env["PATH"] == "/usr/bin")
    }
}

private func scratch() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sigil-changes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: GrokPaths.canonicalPath(url.path))
}

@discardableResult
private func git(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]) { $1 }
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
