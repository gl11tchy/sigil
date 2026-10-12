import Foundation
import Testing

@testable import SigilKit

struct CLIVersionTests {
    @Test func versionsCompareNumbersAndSemverSuffixes() throws {
        let versions = [
            "0.9.0", "0.157.1-alpha.2", "0.157.1-alpha.10", "0.157.1-beta", "0.157.1",
            "0.158.0-alpha.2", "0.158.0", "1.0.0", "2.1.283", "2.1.284",
        ]
        let parsed = try versions.map { try #require(CLIVersion($0)) }
        for (left, right) in zip(parsed, parsed.dropFirst()) { #expect(left < right) }
        #expect(CLIVersion("0.158") == CLIVersion("0.158.0+build.3"))
    }

    @Test(arguments: ["", "0", "0.bad", "0.158.0.1", "0.-1.0", "00.158.0", "0.158.0-", "0.158.0-alpha..2", "0.158.0+"])
    func malformedVersionsDoNotBecomeACompatibilityClaim(version: String) {
        #expect(CLIVersion(version) == nil)
    }

    @Test func noticesNameTheInstalledAndCheckedVersions() {
        let notice = CLIProvider.codex.versionNotice(for: installed("codex-cli 0.160.0"))
        #expect(
            notice == "Codex 0.160.0 is newer than Sigil checked (0.157.1). History and turn state are best effort.")
        #expect(
            CLIProvider.claudeCode.versionNotice(for: installed("2.1.284 (Claude Code)"))?.contains("2.1.283") == true)
        #expect(CLIProvider.grokBuild.versionNotice(for: installed("grok 1.0.41"))?.contains("1.0.40") == true)
        #expect(
            CLIProvider.codex.versionNotice(for: installed("codex-cli 0.158.0-alpha.2"))?.contains("0.158.0-alpha.2")
                == true)
    }

    @Test(arguments: [
        "codex-cli 0.156.0", "codex-cli 0.157.1", "codex-cli 0.157.1-alpha.2", "codex-cli 0.157.1+build.2", "unknown",
    ])
    func checkedOlderOrUnknownVersionsDoNotShowTheNewerNotice(version: String) {
        #expect(CLIProvider.codex.versionNotice(for: installed(version)) == nil)
    }

    @Test func unsupportedMajorNoticeDoesNotPromiseCompatibleHistory() {
        #expect(
            CLIProvider.codex.versionNotice(for: installed("codex-cli 1.0.0"))?.hasSuffix(
                "History format is not supported.") == true)
        #expect(
            CLIProvider.claudeCode.versionNotice(for: installed("3.0.0 (Claude Code)"))?.hasSuffix(
                "History format is not supported.") == true)
        #expect(CLIProvider.cursor.checkedVersion == nil)
        #expect(CLIProvider.cursor.versionNotice(for: installed("9.0.0")) == nil)
        #expect(CLIProvider.codex.versionNotice(for: nil) == nil)
        #expect(
            CLIProvider.codex.versionNotice(for: .init(executable: nil, version: "0.160.0", problem: "Missing")) == nil)
    }

    @Test func disclosureFactsPreserveAllThreeVersionsAndExistingNoticeText() throws {
        let cases: [(CLIProvider, String, String)] = [
            (.claudeCode, "2.1.296", "2.1.283"), (.codex, "0.160.0", "0.157.1"),
            (.grokBuild, "1.0.50", "1.0.40"),
        ]
        for (provider, version, checked) in cases {
            let installation = installed(version)
            let details = try #require(provider.versionNoticeDetails(for: installation))
            #expect(details.provider == provider)
            #expect(details.installedVersion == version)
            #expect(details.checkedVersion == checked)
            #expect(details.impact == .bestEffort)
            #expect(details.consequence == "History and turn state are best effort.")
            #expect(details.text == provider.versionNotice(for: installation))
        }
        #expect(
            CLIProvider.codex.versionNoticeDetails(for: installed("0.160.0-alpha.2"))?.installedVersion
                == "0.160.0-alpha.2")
    }

    @Test func actionableMajorAndUnavailableStatesCannotBecomeNonblockingDetails() throws {
        for (provider, version) in [(CLIProvider.codex, "1.0.0"), (.claudeCode, "3.0.0")] {
            let details = try #require(provider.versionNoticeDetails(for: installed(version)))
            #expect(details.impact == .unsupportedHistory)
            #expect(details.consequence == "History format is not supported.")
        }
        let absent: [ProviderInstallation?] = [
            nil, installed("unknown"), installed("0.157.1"),
            .init(executable: nil, version: "0.160.0", problem: "Not installed"),
            .init(executable: URL(fileURLWithPath: "/tmp/fake-cli"), version: "0.160.0", problem: "Read failed"),
            .init(executable: URL(fileURLWithPath: "/tmp/fake-cli"), version: "0.160.0", problem: nil, timedOut: true),
        ]
        for installation in absent { #expect(CLIProvider.codex.versionNoticeDetails(for: installation) == nil) }
    }

    private func installed(_ version: String) -> ProviderInstallation {
        .init(executable: URL(fileURLWithPath: "/tmp/fake-cli"), version: version, problem: nil)
    }
}
