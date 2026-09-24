import Darwin
import Foundation
import Testing

@testable import SigilKit

struct BridgeRegistrationTests {

    private let grok = URL(fileURLWithPath: "/opt/grok")
    private let binary = URL(fileURLWithPath: "/tmp/sigil-mcp")

    @Test func initDoesNotCallRunner() {
        let probe = RunnerProbe()
        _ = BridgeRegistration(executable: grok, runner: probe.run)
        #expect(probe.calls.isEmpty)
    }

    @Test func installSendsExactArguments() throws {
        let probe = RunnerProbe()
        let registration = BridgeRegistration(executable: grok, runner: probe.run)
        try registration.install(mcpBinary: binary)
        #expect(probe.calls == [["mcp", "add", "sigil", binary.path, "-s", "user"]])
    }

    @Test func removeSendsExactArguments() throws {
        let probe = RunnerProbe()
        probe.responses = [(0, "| sigil |"), (0, "removed")]
        let registration = BridgeRegistration(executable: grok, runner: probe.run)
        try registration.remove()
        #expect(
            probe.calls == [
                ["mcp", "list"],
                ["mcp", "remove", "sigil", "-s", "user"],
            ])
    }

    @Test func removeAlreadyAbsentSucceedsWithoutRemoveCommand() throws {
        let probe = RunnerProbe()
        probe.response = (0, "| another-server |")
        let registration = BridgeRegistration(executable: grok, runner: probe.run)

        try registration.remove()

        #expect(probe.calls == [["mcp", "list"]])
    }

    @Test func removeRaceSucceedsWhenASecondListConfirmsAbsence() throws {
        let probe = RunnerProbe()
        probe.responses = [
            (0, "| sigil |"),
            (1, "server not found"),
            (0, "| another-server |"),
        ]
        let registration = BridgeRegistration(executable: grok, runner: probe.run)

        try registration.remove()

        #expect(
            probe.calls == [
                ["mcp", "list"],
                ["mcp", "remove", "sigil", "-s", "user"],
                ["mcp", "list"],
            ])
    }

    /// `grok mcp list` prints one `  name: command` line per server. Only the
    /// name counts; a `sigil` folder in another server's command does not.
    @Test(arguments: [
        ListingCase(
            output: "  sigil: /Applications/Sigil.app/Contents/MacOS/sigil-mcp\n",
            code: 0,
            expected: true
        ),
        ListingCase(output: "  sigil: /tmp/sigil-mcp (disabled)\n", code: 0, expected: true),
        ListingCase(
            output: "  other: /Users/me/sigil/bin/server\n  github: npx server-github\n",
            code: 0,
            expected: false
        ),
        ListingCase(output: "| other | stdio | /opt/sigil/server |", code: 0, expected: false),
        ListingCase(
            output: "No MCP servers configured. Run `grok mcp add --help` to get started.\n",
            code: 0,
            expected: false
        ),
        ListingCase(
            output: """
                | Server | Transport | Endpoint / Package |
                | sigil | stdio | /tmp/sigil-mcp |
                """,
            code: 0,
            expected: true
        ),
        ListingCase(output: "", code: 0, expected: false),
        ListingCase(
            output: """
                | Server | Transport | Endpoint / Package |
                | sigilprobe | stdio | /tmp/sigilprobe |
                | my-sigil | stdio | /tmp/my-sigil |
                """,
            code: 0,
            expected: false
        ),
    ])
    func removeRunsOnlyWhenAServerIsNamedSigil(listing: ListingCase) throws {
        let probe = RunnerProbe()
        probe.responses = [(listing.code, listing.output), (0, "removed")]
        let registration = BridgeRegistration(executable: grok, runner: probe.run)

        try registration.remove()

        let removed = probe.calls.contains(["mcp", "remove", "sigil", "-s", "user"])
        #expect(removed == listing.expected)
    }

    @Test func installAndRemoveThrowRunnerOutputOnFailure() {
        let probe = RunnerProbe()
        probe.response = (2, "denied by config")
        let registration = BridgeRegistration(executable: grok, runner: probe.run)

        do {
            try registration.install(mcpBinary: binary)
            Issue.record("install should have thrown")
        } catch let error as BridgeRegistration.Error {
            #expect(error == .failed(output: "denied by config"))
        } catch {
            Issue.record("install threw \(error)")
        }

        do {
            try registration.remove()
            Issue.record("remove should have thrown")
        } catch let error as BridgeRegistration.Error {
            #expect(error == .failed(output: "denied by config"))
        } catch {
            Issue.record("remove threw \(error)")
        }
    }

    @Test func realRunnerDrainsLargeOutputWithoutPipeDeadlock() {
        let start = ContinuousClock.now
        let (code, output) = BridgeRegistration.processRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/yes x | /usr/bin/head -c 200000"]
        )
        #expect(code == 0)
        #expect(output.utf8.count == 200_000)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func realRunnerDoesNotWaitForeverForADescendantHoldingThePipe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let start = ContinuousClock.now

        let (code, output) = BridgeRegistration.processRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/sleep 30 & echo $! > \"$1\"; echo parent-finished",
                "sigil-test",
                pidFile.path,
            ]
        )
        if let rawPID = try? String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(rawPID)
        {
            Darwin.kill(pid, SIGKILL)
        }

        #expect(code == 0)
        #expect(output.contains("parent-finished"))
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func helperMustBeARegularExecutableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!BridgeRegistration.isUsableMCPBinary(at: root))

        let file = root.appendingPathComponent("sigil-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
        #expect(!BridgeRegistration.isUsableMCPBinary(at: file))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: file.path)
        #expect(BridgeRegistration.isUsableMCPBinary(at: file))
    }
}

struct ListingCase: Sendable {
    var output: String
    var code: Int32
    var expected: Bool
}

private final class RunnerProbe: @unchecked Sendable {
    var calls: [[String]] = []
    var response: (Int32, String) = (0, "")
    var responses: [(Int32, String)] = []

    func run(executable: URL, arguments: [String]) -> (Int32, String) {
        calls.append(arguments)
        if !responses.isEmpty { return responses.removeFirst() }
        return response
    }
}
