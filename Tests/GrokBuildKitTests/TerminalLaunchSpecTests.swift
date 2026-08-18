import Foundation
import Testing

@testable import GrokBuildKit

struct TerminalLaunchSpecTests {

    private let cwd = URL(fileURLWithPath: "/tmp/grok-build-spec-cwd")

    @Test func newModeArguments() {
        let sessionID = UUID()
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .new(sessionID: sessionID))
        #expect(
            spec.arguments() == [
                "--cwd", cwd.path,
                "--session-id", sessionID.uuidString.lowercased(),
            ]
        )
    }

    @Test func resumeModeArguments() {
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .resume(sessionID: "abc-123"))
        #expect(spec.arguments() == ["--cwd", cwd.path, "--resume", "abc-123"])
    }

    @Test func continueLatestArguments() {
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .continueLatest)
        #expect(spec.arguments() == ["--cwd", cwd.path, "--continue"])
    }

    @Test func optionalFlagsAndExtraArgumentsFollowMode() {
        let spec = GrokLaunchSpec(
            workingDirectory: cwd,
            mode: .continueLatest,
            model: "grok-4",
            reasoningEffort: "high",
            extraArguments: ["--verbose"]
        )
        #expect(
            spec.arguments() == [
                "--cwd", cwd.path,
                "--continue",
                "--model", "grok-4",
                "--reasoning-effort", "high",
                "--verbose",
            ]
        )
    }

    @Test func environmentPutsGrokBinOnPATHOnceAndSetsTERM() {
        let spec = GrokLaunchSpec(workingDirectory: cwd, mode: .continueLatest)
        let env = spec.environment()
        let grokBin = GrokPaths.home.appendingPathComponent("bin").path
        let pathEntries = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(pathEntries.filter { $0 == grokBin }.count == 1)
        #expect(env["TERM"] == "xterm-256color")
    }
}
