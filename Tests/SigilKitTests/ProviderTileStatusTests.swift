import Foundation
import Testing

@testable import SigilKit

struct ProviderTileStatusTests {
    @Test func statusesPreserveProbeEvidenceAndKnownSignIn() {
        let ready = ProviderInstallation(executable: URL(fileURLWithPath: "/synthetic/cli"), version: nil, problem: nil)
        func status(
            _ installation: ProviderInstallation?, checking: Bool = false, stale: Bool = false, signIn: Bool = false
        ) -> ProviderTileStatus {
            .status(installation: installation, isChecking: checking, requiresCheck: stale, needsSignIn: signIn)
        }
        #expect(status(nil) == .checkRequired)
        #expect(status(nil, checking: true) == .checking)
        #expect(status(ready) == .available)
        #expect(status(ready, stale: true) == .checkRequired)
        #expect(status(ready, signIn: true) == .needsSignIn)
        let missing = ProviderInstallation(
            executable: nil, version: nil, problem: "lookup failed", failure: .notInstalled)
        #expect(status(missing, signIn: true) == .notInstalled)
        #expect(
            status(.init(executable: nil, version: nil, problem: "probe failed", failure: .probeFailed)) == .checkFailed
        )
        #expect(status(.init(executable: nil, version: nil, problem: "unclassified failure")) == .unavailable)
        let timeout = ProviderInstallation(executable: nil, version: nil, problem: "timeout", timedOut: true)
        #expect(status(timeout, stale: true) == .timedOut)
        #expect(status(timeout, checking: true) == .checking)
        #expect(ProviderTileStatus.notInstalled.caption == "Not installed")
        #expect(ProviderTileStatus.available.caption.isEmpty)
    }

    @Test(arguments: ["codex-cli 0.160.0", "codex-cli 1.0.0", "unrecognized version output"])
    func historyCompatibilityDoesNotPretendTheCLIIsMissing(output: String) {
        let installation = ProviderInstallation(
            executable: URL(fileURLWithPath: "/synthetic/codex"), version: output, problem: nil)
        #expect(
            ProviderTileStatus.status(
                installation: installation, isChecking: false, requiresCheck: false, needsSignIn: false) == .available)
        if output == "codex-cli 1.0.0" {
            #expect(
                CLIProvider.codex.versionNotice(for: installation)?.contains("History format is not supported") == true)
        } else if output == "unrecognized version output" {
            #expect(CLIProvider.codex.versionNotice(for: installation) == nil)
        } else {
            #expect(CLIProvider.codex.versionNotice(for: installation)?.contains("0.157.1") == true)
        }
    }
}
