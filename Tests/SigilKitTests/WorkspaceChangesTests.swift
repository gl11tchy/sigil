import Foundation
import Testing

@testable import SigilKit

struct WorkspaceChangesTests {
    @Test func statusParsingCoversRenamesUntrackedConflictsAndSpaces() {
        let raw =
            [
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

    @Test func statusParsingReadsTheOldPathOfAWorkTreeRenameOrCopy() {
        // Git 2.54 output. The work-tree column carries R when the new path is
        // intent-to-add, and C with `status.renames=copies`.
        let raw =
            [
                " R new.txt", "ab/x.txt", " M x.txt", "R  b.txt", "a.txt", " R c.txt", "b.txt", " C copy.txt",
                "orig.txt", " M last.txt",
            ].joined(separator: "\0") + "\0"
        let entries = WorkspaceChangesReader.parseStatus(Data(raw.utf8))
        #expect(
            entries == [
                .init(path: "new.txt", oldPath: "ab/x.txt", status: .renamed),
                .init(path: "x.txt", oldPath: nil, status: .modified),
                .init(path: "b.txt", oldPath: "a.txt", status: .renamed),
                .init(path: "c.txt", oldPath: "b.txt", status: .renamed),
                .init(path: "copy.txt", oldPath: "orig.txt", status: .copied),
                .init(path: "last.txt", oldPath: nil, status: .modified),
            ])
    }

    @Test func statusParsingNamesALoneIntentToAddFileAdded() {
        // `git add -N new.txt` with no deletion to pair it with.
        let raw = [" A new.txt", "A  staged.txt", "UA theirs.txt"].joined(separator: "\0") + "\0"
        let entries = WorkspaceChangesReader.parseStatus(Data(raw.utf8))
        #expect(
            entries == [
                .init(path: "new.txt", oldPath: nil, status: .added),
                .init(path: "staged.txt", oldPath: nil, status: .added),
                .init(path: "theirs.txt", oldPath: nil, status: .conflicted),
            ])
    }

    @Test func statusParsingKeepsAPathThatStartsWithACombiningMark() {
        // As Characters, the separator space and U+0301 are one grapheme.
        let raw =
            [" R \u{301}", "ab.txt", " M \u{301}x.txt", "?? \u{301}u.txt", " M last.txt"]
            .joined(separator: "\0") + "\0"
        let entries = WorkspaceChangesReader.parseStatus(Data(raw.utf8))
        #expect(
            entries == [
                .init(path: "\u{301}", oldPath: "ab.txt", status: .renamed),
                .init(path: "\u{301}x.txt", oldPath: nil, status: .modified),
                .init(path: "\u{301}u.txt", oldPath: nil, status: .untracked),
                .init(path: "last.txt", oldPath: nil, status: .modified),
            ])
    }

    @Test func numstatParsingCountsRenamesAndLeavesBinaryUncounted() {
        let raw =
            ["3\t1\tsrc/a.swift", "-\t-\timage.png", "2\t0\t", "old.txt", "new.txt"]
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

    @Test func aStagedRenameThatNoLongerResemblesItsOriginalKeepsItsDeletedLines() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try git(["mv", "old.txt", "new.txt"], in: repo)
        try "w\nx\ny\nz\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        // Git no longer pairs the two against HEAD: old.txt −3, new.txt +4.
        #expect(try gitTotals(in: repo) == (added: 4, removed: 3))

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(
            changes.files == [.init(path: "new.txt", oldPath: "old.txt", status: .renamed, added: 4, removed: 3)])
        #expect(changes.added == 4)
        #expect(changes.removed == 3)
    }

    @Test func countsMatchGitAndNoPathIsCountedTwice() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "a\nb\nc\nd\ne\n".write(to: repo.appendingPathComponent("similar.txt"), atomically: true, encoding: .utf8)
        try "1\n2\n3\n4\n5\n".write(to: repo.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        try "k\n".write(to: repo.appendingPathComponent("unstaged.txt"), atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 3]).write(to: repo.appendingPathComponent("image.bin"))
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)

        // A rename Git still pairs, with one line changed.
        try git(["mv", "similar.txt", "renamed.txt"], in: repo)
        try "a\nb\nC\nd\ne\n".write(to: repo.appendingPathComponent("renamed.txt"), atomically: true, encoding: .utf8)
        // A rename whose old path holds a new, untracked file.
        try git(["mv", "moved.txt", "there.txt"], in: repo)
        try "fresh\n".write(to: repo.appendingPathComponent("moved.txt"), atomically: true, encoding: .utf8)
        // Removed from the index but kept on disk: a deletion and an untracked file at one path.
        try git(["rm", "-q", "--cached", "unstaged.txt"], in: repo)
        try Data([9, 0, 9]).write(to: repo.appendingPathComponent("image.bin"))

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        let git = try gitTotals(in: repo)
        #expect(changes.added == git.added)
        #expect(changes.removed == git.removed)
        let renamed = changes.files.first { $0.path == "renamed.txt" }
        #expect(renamed == .init(path: "renamed.txt", oldPath: "similar.txt", status: .renamed, added: 1, removed: 1))
        #expect(changes.files.first { $0.path == "there.txt" }?.oldPath == "moved.txt")
        #expect(changes.files.first { $0.path == "unstaged.txt" && $0.status == .deleted }?.removed == 1)
        // Git does not count untracked files, so the reader does not either.
        for file in changes.files where file.status == .untracked {
            #expect(file.added == nil && file.removed == nil, "\(file.path)")
        }
        let binary = changes.files.first { $0.path == "image.bin" }
        #expect(binary?.status == .modified)
        #expect(binary?.added == nil)
    }

    @Test func aFileRemovedFromTheIndexButKeptOnDiskIsTwoRowsWithTheirOwnIDs() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "k\nl\n".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try git(["rm", "-q", "--cached", "kept.txt"], in: repo)
        // Git lists the path twice: `D  kept.txt` and `?? kept.txt`.
        #expect(try git(["status", "--porcelain=v1"], in: repo) == "D  kept.txt\n?? kept.txt")

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(
            changes.files == [
                .init(path: "kept.txt", status: .deleted, added: 0, removed: 2),
                .init(path: "kept.txt", status: .untracked, added: nil, removed: nil),
            ])
        #expect(Set(changes.files.map(\.id)).count == 2, "each row needs its own identity")
        #expect(changes.added == 0)
        #expect(changes.removed == 2)

        guard case .changes(let again) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(again.files.map(\.id) == changes.files.map(\.id), "the same state reads to the same identities")
    }

    @Test func aWorkTreeRenameIsOneRowAndItsOldPathIsNotReadAsAnotherFile() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        let folder = repo.appendingPathComponent("ab")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "1\n2\n3\n4\n".write(to: folder.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try "p\nq\nr\n".write(to: repo.appendingPathComponent("old_name.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try FileManager.default.moveItem(
            at: folder.appendingPathComponent("x.txt"), to: repo.appendingPathComponent("new.txt"))
        try FileManager.default.moveItem(
            at: repo.appendingPathComponent("old_name.txt"), to: repo.appendingPathComponent("new_name.txt"))
        try git(["add", "-N", "new.txt", "new_name.txt"], in: repo)
        try "x\ny\n".write(to: repo.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        // Intent-to-add new paths make Git report the renames in the work-tree column.
        let status = GitOutput.run(
            git: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repo.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            timeout: .seconds(5))
        #expect(status?.text == " R new.txt\0ab/x.txt\0 R new_name.txt\0old_name.txt\0 M x.txt\0")

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(
            changes.files == [
                .init(path: "new.txt", oldPath: "ab/x.txt", status: .renamed, added: 0, removed: 0),
                .init(path: "new_name.txt", oldPath: "old_name.txt", status: .renamed, added: 0, removed: 0),
                .init(path: "x.txt", status: .modified, added: 1, removed: 0),
            ])
        #expect(Set(changes.files.map(\.id)).count == changes.files.count, "each row needs its own identity")
        let git = try gitTotals(in: repo)
        #expect(changes.added == git.added)
        #expect(changes.removed == git.removed)
    }

    @Test func aWorkTreeRenameOfAPathWithStagedChangesCountsEachLineOnce() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "1\n2\n3\n4\n5\n6\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try "p\nq\nr\ns\ne\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: repo)
        try FileManager.default.moveItem(
            at: repo.appendingPathComponent("a.txt"), to: repo.appendingPathComponent("c.txt"))
        try git(["add", "-N", "c.txt"], in: repo)
        // Status pairs the index's a.txt with c.txt and also lists a.txt's
        // staged change; numstat, from HEAD, does not pair them: a.txt −6, c.txt +5.
        #expect(try gitTotals(in: repo) == (added: 5, removed: 6))

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(
            changes.files == [
                .init(path: "a.txt", status: .modified, added: 0, removed: 6),
                .init(path: "c.txt", oldPath: "a.txt", status: .renamed, added: 5, removed: 0),
            ])
        #expect(changes.added == 5)
        #expect(changes.removed == 6)
    }

    @Test func aLoneIntentToAddFileIsAddedAndCountedAsGitCountsIt() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "1\n2\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try "n1\nn2\nn3\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try git(["add", "-N", "new.txt"], in: repo)
        // With no deletion to pair it with, Git reports it in the work-tree column.
        let status = GitOutput.run(
            git: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repo.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            timeout: .seconds(5))
        #expect(status?.text == " A new.txt\0")

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(changes.files == [.init(path: "new.txt", status: .added, added: 3, removed: 0)])
        let git = try gitTotals(in: repo)
        #expect(changes.added == git.added)
        #expect(changes.removed == git.removed)
    }

    @Test func aPathThatStartsWithACombiningMarkKeepsItsNameAndItsOldPath() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        let mark = "\u{301}"
        try "p\nq\n".write(to: repo.appendingPathComponent("ab.txt"), atomically: true, encoding: .utf8)
        try "k\n".write(to: repo.appendingPathComponent(mark + "x.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"], in: repo)
        try FileManager.default.moveItem(
            at: repo.appendingPathComponent("ab.txt"), to: repo.appendingPathComponent(mark))
        try git(["add", "-N", mark], in: repo)
        try "k\nl\n".write(to: repo.appendingPathComponent(mark + "x.txt"), atomically: true, encoding: .utf8)
        try "u\n".write(to: repo.appendingPathComponent(mark + "u.txt"), atomically: true, encoding: .utf8)
        let status = GitOutput.run(
            git: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", repo.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
            timeout: .seconds(5))
        #expect(status?.text == " R \u{301}\0ab.txt\0 M \u{301}x.txt\0?? \u{301}u.txt\0")

        guard case .changes(let changes) = await WorkspaceChangesReader.read(repo) else {
            Issue.record("expected changes")
            return
        }
        #expect(
            changes.files == [
                .init(path: mark, oldPath: "ab.txt", status: .renamed, added: 0, removed: 0),
                .init(path: mark + "x.txt", status: .modified, added: 1, removed: 0),
                .init(path: mark + "u.txt", status: .untracked, added: nil, removed: nil),
            ])
        #expect(Set(changes.files.map(\.id)).count == changes.files.count, "each row needs its own identity")
        let git = try gitTotals(in: repo)
        #expect(changes.added == git.added)
        #expect(changes.removed == git.removed)
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
    }

    @Test func aGitThatOutlivesTheDeadlineIsKilledAndFails() async throws {
        let plain = try scratch()
        let pids = plain.appendingPathComponent("pids")
        defer {
            killRecorded(pids)
            try? FileManager.default.removeItem(at: plain)
        }
        // The Git itself sleeps, and a child it started holds the pipes too.
        let slow = try fakeGit(
            in: plain, "echo $$ >> \(quoted(pids))\nsleep 10 &\necho $! >> \(quoted(pids))\nexec sleep 10\n")

        let start = ContinuousClock.now
        let output = GitOutput.run(git: slow, arguments: [], timeout: .seconds(1))
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        let git = try #require(recorded(pids).first)
        #expect(await exits(git), "the timed-out Git is killed")
        let reading = await WorkspaceChangesReader.read(plain, git: slow, timeout: .seconds(1))
        #expect(reading == .failed("Git did not answer."))
    }

    @Test func aGitThatNeverStopsWritingIsKilledAtTheDeadline() async throws {
        let plain = try scratch()
        let pids = plain.appendingPathComponent("pids")
        defer {
            killRecorded(pids)
            try? FileManager.default.removeItem(at: plain)
        }
        let chatty = try fakeGit(in: plain, "echo $$ >> \(quoted(pids))\nexec yes\n")

        let start = ContinuousClock.now
        #expect(GitOutput.run(git: chatty, arguments: [], timeout: .seconds(1)) == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        let git = try #require(recorded(pids).first)
        #expect(await exits(git), "the timed-out Git is killed")
    }

    @Test func aChildHoldingThePipesAfterGitExitsCannotOutlastTheDeadline() async throws {
        let plain = try scratch()
        let pids = plain.appendingPathComponent("pids")
        defer {
            killRecorded(pids)
            try? FileManager.default.removeItem(at: plain)
        }
        // Git answers and exits 0, but a child it started keeps the pipes open.
        let answered = plain.appendingPathComponent("answered")
        let git = try fakeGit(
            in: plain, "sleep 10 &\necho $! >> \(quoted(pids))\necho true\ntouch \(quoted(answered))\nexit 0\n")

        let start = ContinuousClock.now
        let output = GitOutput.run(git: git, arguments: [], timeout: .seconds(1))
        #expect(output == nil)
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(FileManager.default.fileExists(atPath: answered.path), "Git ran to its successful exit")
        let reading = await WorkspaceChangesReader.read(plain, git: git, timeout: .seconds(1))
        #expect(reading == .failed("Git did not answer."))
        #expect(ContinuousClock.now - start < .seconds(6))
    }

    @Test func aGitThatClosesItsPipesIsReadInFull() throws {
        let plain = try scratch()
        defer { try? FileManager.default.removeItem(at: plain) }
        let git = try fakeGit(in: plain, "printf 'out'\nprintf 'err' >&2\nexit 3\n")

        let output = try #require(GitOutput.run(git: git, arguments: [], timeout: .seconds(5)))
        #expect(output.status == 3)
        #expect(output.text == "out")
        #expect(output.error == "err")
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

/// What Git itself counts against HEAD, binary files left out.
private func gitTotals(in repo: URL) throws -> (added: Int, removed: Int) {
    try git(["diff", "HEAD", "--numstat", "-M"], in: repo)
        .split(whereSeparator: \.isNewline)
        .reduce(into: (added: 0, removed: 0)) { totals, line in
            let parts = line.split(separator: "\t")
            totals.added += Int(parts[0]) ?? 0
            totals.removed += Int(parts[1]) ?? 0
        }
}

private func fakeGit(in directory: URL, _ body: String) throws -> URL {
    let url = directory.appendingPathComponent("fake-git")
    try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func quoted(_ url: URL) -> String {
    "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func recorded(_ pids: URL) -> [pid_t] {
    ((try? String(contentsOf: pids, encoding: .utf8)) ?? "")
        .split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
}

/// Every process a fake Git recorded, stopped so no test leaves one behind.
private func killRecorded(_ pids: URL) {
    for pid in recorded(pids) { kill(pid, SIGKILL) }
}

/// True once `pid` is gone. A killed child stays a zombie until it is reaped.
private func exits(_ pid: pid_t) async -> Bool {
    for _ in 0..<40 {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
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
