import Foundation
import SigilKit
import Testing

@testable import SigilApp

@Suite(.serialized)
@MainActor
struct SessionWorktreeStartTests {
    @Test func explicitFolderChoicesDoNotReplaceTheNextFoldersSavedDefault() throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let first = try fixture.directory("first")
        let second = try fixture.directory("second")
        try initialize(first)
        try initialize(second)
        var choice = NewSessionLaunch.WorktreeChoice()
        choice.choose(false, for: first)
        #expect(!choice.startsInWorktree(for: first, savedDefault: true))
        #expect(choice.startsInWorktree(for: second, savedDefault: true))
        choice.choose(true, for: first)
        #expect(choice.startsInWorktree(for: first, savedDefault: false))
        #expect(!choice.startsInWorktree(for: second, savedDefault: false))
        #expect(!choice.startsInWorktree(for: fixture.root, savedDefault: true))
    }

    @Test(arguments: ["inline", "options", "phone"])
    func everyEntryRejectsTheMissingSelectedFolder(entry: String) async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo")
        try initialize(repo)
        let selected = repo.appendingPathComponent("uncommitted")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        let root = fixture.root.appendingPathComponent("worktrees")
        _ = await start(entry, fixture: fixture, project: selected, root: root)
        #expect(fixture.model.tabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try command(["branch", "--list", "sigil/*"], in: repo).isEmpty)
    }

    @Test(arguments: ["inline", "options", "phone"])
    func cancellationAfterCreationCleansOnlyTheUnusedAttempt(entry: String) async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo")
        try initialize(repo)
        let gate = try CheckoutGate(repo: repo)
        defer { gate.release() }
        let root = fixture.root.appendingPathComponent("worktrees")
        let task = Task { await start(entry, fixture: fixture, project: repo, root: root) }
        let checkout = try await gate.waitForCheckout()
        #expect(FileManager.default.fileExists(atPath: checkout.path))
        task.cancel()
        gate.release()
        let message = await task.value
        #expect(fixture.model.tabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: checkout.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try command(["branch", "--list", "sigil/*"], in: repo).isEmpty)
        if entry == "phone" { #expect(message?.contains("cancelled") == true) }
    }

    @Test(arguments: [false, true])
    func cancelledPhoneRetainsChangedOrLockedResourcesAndReportsFullPath(locked: Bool) async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo")
        try initialize(repo)
        let gate = try CheckoutGate(repo: repo)
        defer { gate.release() }
        let root = fixture.root.appendingPathComponent("worktrees")
        let task = Task { await start("phone", fixture: fixture, project: repo, root: root) }
        let checkout = try await gate.waitForCheckout()
        let branch = try command(["symbolic-ref", "--short", "HEAD"], in: checkout)
        if locked {
            _ = try command(["worktree", "lock", checkout.path], in: repo)
        } else {
            try Data("keep my work".utf8).write(to: checkout.appendingPathComponent("untracked.txt"))
        }
        task.cancel()
        gate.release()
        let message = await task.value
        #expect(message?.contains(checkout.path) == true)
        #expect(message?.contains(branch) == true)
        #expect(FileManager.default.fileExists(atPath: checkout.path))
        #expect(try command(["branch", "--list", branch], in: repo).contains(branch))
        #expect(fixture.model.tabs.isEmpty)
        #expect(fixture.alerts.count == 0)
    }

    @Test func aLateAcceptedLaunchIsRetainedWithoutDuplicateCreation() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo")
        try initialize(repo)
        let root = fixture.root.appendingPathComponent("worktrees")
        var receipt: SigilWorktree.Creation?
        var creates = 0
        var launches = 0
        var task: Task<SessionWorktreeStart.Result, Never>?
        task = Task {
            await SessionWorktreeStart.start(
                project: repo, useWorktree: true, root: root,
                create: { project, root in
                    creates += 1
                    receipt = try await SigilWorktree.createAttempt(for: project, root: root)
                    return receipt
                }, validate: { nil },
                launch: { _ in
                    launches += 1
                    task?.cancel()
                    return true
                })
        }
        let result = await task!.value
        #expect(result.message == nil)
        #expect(creates == 1)
        #expect(launches == 1)
        let made = try #require(receipt)
        #expect(FileManager.default.fileExists(atPath: made.checkout.path))
        #expect(try command(["branch", "--list", made.branch], in: repo).contains(made.branch))
    }

    @Test func providerFailureAfterCreationRollsBackBeforeDispatch() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo")
        try initialize(repo)
        let gate = try CheckoutGate(repo: repo)
        defer { gate.release() }
        let root = fixture.root.appendingPathComponent("worktrees")
        let task = Task { await start("phone", fixture: fixture, project: repo, root: root) }
        let checkout = try await gate.waitForCheckout()
        fixture.settings.executablePath = fixture.root.appendingPathComponent("missing-cli").path
        gate.release()
        #expect(await task.value != nil)
        #expect(fixture.model.tabs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: checkout.path))
        #expect(try command(["branch", "--list", "sigil/*"], in: repo).isEmpty)
    }

    @Test func dispatchRejectedBeforeAProcessStartsRemovesTheAttempt() async throws {
        let fixture = try PhoneCommandFixture()
        defer { fixture.cleanup() }
        let repo = try fixture.directory("repo")
        try initialize(repo)
        let root = fixture.root.appendingPathComponent("worktrees")
        let result = await SessionWorktreeStart.start(
            project: repo, useWorktree: true, root: root, validate: { nil }, launch: { _ in false })
        #expect(result.message?.contains("Could not start") == true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try command(["branch", "--list", "sigil/*"], in: repo).isEmpty)
    }

    private func start(_ entry: String, fixture: PhoneCommandFixture, project: URL, root: URL) async -> String? {
        if entry == "phone" {
            let saved = RemoteCommands.worktreeRoot
            RemoteCommands.worktreeRoot = root
            defer { RemoteCommands.worktreeRoot = saved }
            fixture.settings.showWorktreeSessions = true
            fixture.model.addProject(project)
            return await fixture.command("new", text: project.path, worktree: true).error
        }
        fixture.model.requestNewSession(in: project)
        if entry == "inline" {
            await fixture.model.startDefaultSession(.grokBuild, worktreeRoot: root)
        } else {
            fixture.model.isShowingNewSessionSheet = true
            _ = await NewSessionLaunch.start(
                .grokBuild, model: fixture.model, project: project, useWorktree: true,
                launch: ("", "", false), worktreeRoot: root)
        }
        return nil
    }
}

private struct CheckoutGate {
    let signal: URL
    let resume: URL

    init(repo: URL) throws {
        signal = repo.appendingPathComponent(".git/created")
        resume = repo.appendingPathComponent(".git/resume")
        let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
        let script = """
            #!/bin/sh
            pwd > \(quote(signal.path))
            for i in $(seq 1 1000); do
              [ -f \(quote(resume.path)) ] && exit 0
              sleep 0.01
            done
            exit 1
            """
        try Data(script.utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
    }

    func waitForCheckout() async throws -> URL {
        for _ in 0..<500 {
            if let path = try? String(contentsOf: signal, encoding: .utf8), !path.isEmpty {
                return URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SigilWorktree.Failure(message: "Fixture checkout did not reach its bounded gate")
    }

    func release() { try? Data().write(to: resume) }
}

private func initialize(_ repo: URL) throws {
    _ = try command(["init", "-q"], in: repo)
    _ = try command(
        ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
}

private func command(_ arguments: [String], in repo: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", repo.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw SigilWorktree.Failure(message: "Fixture git failed: \(arguments)")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
