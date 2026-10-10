import Darwin
import Foundation
import Testing

@testable import SigilKit

struct ProcessOpenFilesTests {
    @Test func aNewDescendantDuringTheWalkInvalidatesTheObservation() {
        let child = ChildProcessGeneration(pid: 42, seconds: 1, microseconds: 0)
        let root = ProcessOpenFiles.Node(generation: child, parent: getpid())
        var walks = 0
        let reader = ProcessOpenFiles.Reader(
            node: { _ in root },
            children: { _ in
                walks += 1
                return walks == 1 ? [] : [43]
            }, files: { _, _ in [:] })
        #expect(
            ProcessOpenFiles.snapshot(of: child, historyRoot: URL(fileURLWithPath: "/fixtures"), reader: reader)
                == nil)
    }

    @Test(arguments: [false, true])
    func aReusedOrReparentedDescendantInvalidatesTheWholeObservation(reparented: Bool) {
        let child = ChildProcessGeneration(pid: 42, seconds: 1, microseconds: 0)
        let root = ProcessOpenFiles.Node(generation: child, parent: getpid())
        let descendant = ProcessOpenFiles.Node(
            generation: ChildProcessGeneration(pid: 43, seconds: 2, microseconds: 0), parent: child.pid)
        var descendantReads = 0
        let reader = ProcessOpenFiles.Reader(
            node: { pid in
                if pid == child.pid { return root }
                descendantReads += 1
                if descendantReads == 1 { return descendant }
                return ProcessOpenFiles.Node(
                    generation: reparented
                        ? descendant.generation
                        : ChildProcessGeneration(pid: 43, seconds: 3, microseconds: 0),
                    parent: reparented ? getpid() : child.pid)
            },
            children: { $0 == child.pid ? [43] : [] }, files: { _, _ in [:] })
        #expect(
            ProcessOpenFiles.snapshot(of: child, historyRoot: URL(fileURLWithPath: "/fixtures"), reader: reader) == nil)
    }

    @Test(arguments: ["node", "children", "files"])
    func missingOrDeniedKernelEvidenceNeverFallsBackToGuessing(boundary: String) {
        let child = ChildProcessGeneration(pid: 42, seconds: 1, microseconds: 0)
        let node = ProcessOpenFiles.Node(generation: child, parent: getpid())
        let reader = ProcessOpenFiles.Reader(
            node: { _ in boundary == "node" ? nil : node },
            children: { _ in boundary == "children" ? nil : [] },
            files: { _, _ in boundary == "files" ? nil : [:] })
        #expect(
            ProcessOpenFiles.snapshot(of: child, historyRoot: URL(fileURLWithPath: "/fixtures"), reader: reader) == nil)
    }

    @Test func aWritableExactRolloutProvesOnlyItsOwnChild() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("own")
        defer { child.stop() }
        let session = try await fixture.session("own")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        let outside = try fixture.start("outside")
        defer { outside.stop() }
        let outsideSession = try await fixture.session("outside")

        let matched = CodexSessionBinding.resolve(
            process: generation, historyRoot: fixture.root,
            sessions: [outsideSession, session], workingDirectory: fixture.cwd)
        #expect(matched?.nativeSessionID == session.nativeSessionID)
        #expect(matched?.directory == session.directory)
    }

    @Test func aFolderAndRecentOutsideWriterAreNotIdentity() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let waiting = try fixture.start("waiting", writes: false)
        defer { waiting.stop() }
        let outside = try fixture.start("outside")
        defer { outside.stop() }
        let session = try await fixture.session("outside")
        let generation = try #require(ProcessOpenFiles.ownedChild(waiting.process.processIdentifier))
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func twoSameFolderChildrenKeepTheirOwnChatsInReversedFirstUse() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let first = try fixture.start("first", writes: false)
        defer { first.stop() }
        let second = try fixture.start("second")
        defer { second.stop() }
        let secondSession = try await fixture.session("second")
        try first.input.fileHandleForWriting.write(contentsOf: Data("write\n".utf8))
        let firstSession = try await fixture.session("first")
        for (child, expected) in [(first, firstSession), (second, secondSession)] {
            let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
            #expect(
                CodexSessionBinding.resolve(
                    process: generation, historyRoot: fixture.root,
                    sessions: [secondSession, firstSession], workingDirectory: fixture.cwd)?.nativeSessionID
                    == expected.nativeSessionID)
        }
    }

    @Test func aShimCanProveItsDescendantsExactFile() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("nested", descendant: true)
        defer { child.stop() }
        let session = try await fixture.session("nested")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd)?.nativeSessionID == session.nativeSessionID)
    }

    @Test func aFourChildShimCannotOmitThreeHeldRollouts() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("forest", descendant: true, childCount: 4)
        defer { child.stop() }
        let session = try await fixture.session("forest")
        for index in 1..<4 { try await fixture.awaitReady("forest.ready.\(index)", suffix: "") }
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        let snapshot = try #require(ProcessOpenFiles.snapshot(of: generation, historyRoot: fixture.root))
        #expect(snapshot.nodes.count == 5)
        #expect(snapshot.files.count == 4)
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func multipleHeldFilesStayAmbiguousEvenWhenOneIsMalformed() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("one", extraFile: true)
        defer { child.stop() }
        let session = try await fixture.session("one")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func aReadOnlyOldFileDoesNotProveCreation() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let session = try fixture.write("old")
        let child = try fixture.start("old", readOnly: true)
        defer { child.stop() }
        try await fixture.awaitReady("old")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func anOlderWritableFileDoesNotProveCreation() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let session = try fixture.write("old-writable")
        let child = try fixture.start("old-writable")
        defer { child.stop() }
        try await fixture.awaitReady("old-writable")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func changedBirthIdentityAndExitedChildrenCannotBind() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("reused")
        defer { child.stop() }
        let session = try await fixture.session("reused")
        let actual = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        let reused = ChildProcessGeneration(
            pid: actual.pid, seconds: actual.seconds + 1, microseconds: actual.microseconds)
        #expect(ProcessOpenFiles.snapshot(of: reused, historyRoot: fixture.root) == nil)
        child.stop()
        #expect(
            CodexSessionBinding.resolve(
                process: actual, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func replacementCannotReuseTheOldDescriptorProof() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("replace")
        defer { child.stop() }
        let session = try await fixture.session("replace")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        try fixture.data("different").write(to: session.directory, options: .atomic)
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
    }

    @Test func staleCachedMetadataAndAnotherFolderCannotBind() async throws {
        let fixture = try HeldRolloutFixture()
        defer { fixture.cleanup() }
        let child = try fixture.start("changed")
        defer { child.stop() }
        let session = try await fixture.session("changed")
        let generation = try #require(ProcessOpenFiles.ownedChild(child.process.processIdentifier))
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root, sessions: [session],
                workingDirectory: fixture.root.appendingPathComponent("another-folder")) == nil)
        let handle = try FileHandle(forWritingTo: session.directory)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: fixture.data("another-id"))
        try handle.close()
        #expect(
            CodexSessionBinding.resolve(
                process: generation, historyRoot: fixture.root,
                sessions: [session], workingDirectory: fixture.cwd) == nil)
        #expect(CodexSessionBinding.validateForExplicitLink(session) == nil)
    }
}

private final class HeldChild {
    let process: Process
    let input: Pipe
    private let termination = DispatchGroup()
    init(process: Process, input: Pipe) {
        self.process = process
        self.input = input
        termination.enter()
        process.terminationHandler = { [termination] _ in termination.leave() }
    }
    func stop() {
        try? input.fileHandleForWriting.close()
        if termination.wait(timeout: .now() + .seconds(2)) == .success { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // Foundation owns reaping; do not enter an unbounded run-loop wait on
        // the Swift Testing worker. The group remains complete on repeat stops.
        #expect(
            termination.wait(timeout: .now() + .seconds(2)) == .success,
            "The test-owned process did not report termination within its shutdown bounds")
    }
}

private final class HeldRolloutFixture {
    let root: URL
    let cwd: URL
    private var ids: [String: String] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func file(_ name: String) -> URL { root.appendingPathComponent("\(name).jsonl") }
    func data(_ name: String) throws -> Data {
        if ids[name] == nil { ids[name] = UUID().uuidString.lowercased() }
        return try JSONSerialization.data(withJSONObject: [
            "type": "session_meta", "payload": ["id": ids[name]!, "cwd": cwd.path, "cli_version": "0.157.1"],
        ]) + Data([0x0A])
    }
    func write(_ name: String) throws -> GrokSession {
        try data(name).write(to: file(name))
        return try #require(
            NativeSessionScanner.parse(provider: .codex, data: data(name), file: file(name), modified: .now))
    }
    func start(
        _ name: String, writes: Bool = true, descendant: Bool = false,
        extraFile: Bool = false, readOnly: Bool = false, childCount: Int = 1
    ) throws -> HeldChild {
        let body = String(decoding: try data(name), as: UTF8.self)
        let worker = root.appendingPathComponent("\(name).sh")
        let script = """
            #!/bin/sh
            write_rollout() {
                exec 3>"$1"
                printf '%s' "$2" >&3
                \(extraFile ? "exec 4>\"$1.extra.jsonl\"; printf malformed >&4" : "")
                printf ready >"$3"
            }
            \(readOnly ? "exec 3<\"$1\"; printf ready >\"$3\"" : writes ? "write_rollout \"$@\"" : "")
            while IFS= read -r command; do
                [ "$command" = write ] && write_rollout "$@"
            done
            exit 0
            """
        try script.write(to: worker, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let args = [worker.path, file(name).path, body, root.appendingPathComponent("\(name).ready").path]
        if descendant, childCount > 1 {
            // Three children hold empty extra rollouts. All four PIDs and
            // files must still enter the ambiguity set before envelope parsing.
            let shim = """
                i=1
                while [ "$i" -lt "$5" ]; do
                    /bin/sh -c 'exec 3>"$1"; printf ready >"$2"; read -r done' sibling "$2.$i.jsonl" "$4.$i" <&0 &
                    i=$((i + 1))
                done
                /bin/sh "$1" "$2" "$3" "$4" <&0 &
                wait
                """
            process.arguments = ["-c", shim, "shim"] + args + [String(childCount)]
        } else {
            process.arguments = descendant ? ["-c", "/bin/sh \"$@\" <&0 & wait $!", "shim"] + args : args
        }
        process.environment = ["PATH": "/usr/bin:/bin", "CODEX_HOME": root.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = HeldChild(process: process, input: input)
        try process.run()
        return child
    }
    func awaitReady(_ name: String, suffix: String = ".ready") async throws {
        let marker = root.appendingPathComponent("\(name)\(suffix)")
        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
    func session(_ name: String) async throws -> GrokSession {
        try await awaitReady(name)
        return try #require(
            NativeSessionScanner.parse(
                provider: .codex, data: Data(contentsOf: file(name)), file: file(name), modified: .now))
    }
}
