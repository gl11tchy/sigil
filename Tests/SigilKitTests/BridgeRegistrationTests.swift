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
        let registration = BridgeRegistration(executable: grok, runner: probe.run)
        try registration.remove()
        #expect(probe.calls == [["mcp", "remove", "sigil", "-s", "user"]])
    }

    @Test(arguments: [
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
        ListingCase(output: "sigil", code: 1, expected: false),
    ])
    func isInstalledRequiresWholeServerName(listing: ListingCase) {
        let probe = RunnerProbe()
        probe.response = (listing.code, listing.output)
        let registration = BridgeRegistration(executable: grok, runner: probe.run)
        #expect(registration.isInstalled() == listing.expected)
        #expect(probe.calls == [["mcp", "list"]])
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
}

struct ListingCase: Sendable {
    var output: String
    var code: Int32
    var expected: Bool
}

private final class RunnerProbe: @unchecked Sendable {
    var calls: [[String]] = []
    var response: (Int32, String) = (0, "")

    func run(executable: URL, arguments: [String]) -> (Int32, String) {
        calls.append(arguments)
        return response
    }
}
