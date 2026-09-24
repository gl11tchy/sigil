import Foundation

@MainActor
@main
enum TestMain {
    static func main() async {
        var failed = 0
        // Counted, not written down: every parallel branch used to collide on
        // one hardcoded total.
        var passed = 0

        func run(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                passed += 1
                print("PASS \(name)")
            } catch {
                failed += 1
                print("FAIL \(name): \(error)")
            }
        }

        run("tap target is 44") { try ThemeTests.tapTargetIs44() }
        run("space scale is ordered") { try ThemeTests.spaceScaleIsOrdered() }
        run("emphasis steps up for bold text") { try ThemeTests.emphasisStepsUp() }

        run("crypto round trip") { try ProtocolTests.cryptoRoundTrip() }
        run("crypto rejects wrong direction, key and tampering") { try ProtocolTests.cryptoRejectsWrongDirectionKeyAndTampering() }
        run("crypto rejects bad keys") { try ProtocolTests.cryptoRejectsBadKeys() }
        run("crypto frame layout matches SigilKit") { try ProtocolTests.cryptoFrameLayout() }
        run("pairing link table") { try ProtocolTests.pairingLinkTable() }
        run("credential addresses") { try ProtocolTests.credentialAddresses() }
        run("route omits a missing ticket") { try ProtocolTests.routeOmitsMissingTicket() }
        run("request omits missing fields") { try ProtocolTests.requestOmitsMissingFields() }
        run("decodes a Mac reply") { try ProtocolTests.decodesMacReply() }
        run("state validation") { try ProtocolTests.stateValidation() }
        run("new-session options round trip") { try ProtocolTests.newSessionOptionsRoundTrip() }
        run("chat list pages") { try ProtocolTests.chatListPages() }
        run("project name rules") { try ProtocolTests.projectNameRules() }

        run("history keeps scrolled text") { try OutputTests.historyKeepsScrolledText() }
        run("history redraw replaces tail") { try OutputTests.historyRedrawReplacesTail() }
        run("history prepends older text") { try OutputTests.historyPrependsOlderText() }
        run("history stays under cap") { try OutputTests.historyStaysUnderCap() }
        run("readable output matches the companion") { try OutputTests.readableOutputMatchesCompanion() }
        run("readable output falls back to raw") { try OutputTests.readableOutputFallsBackToRaw() }
        run("file chunks") { try OutputTests.fileChunks() }
        run("safe file names") { try OutputTests.safeFileNames() }

        if let port = ProcessInfo.processInfo.environment["SIGIL_RELAY_PORT"] {
            do {
                try await RelayTests.pairsAndReconnectsByTicket(port: port)
                passed += 1
                print("PASS relay: pairs, then reconnects by ticket")
            } catch {
                failed += 1
                print("FAIL relay: \(error)")
            }
        }

        if let port = ProcessInfo.processInfo.environment["SIGIL_RELAY_PORT"] {
            do {
                try await RelayTests.lostPairingReplyAsksForANewCode(port: port)
                passed += 1
                print("PASS relay: a lost pairing reply asks for a new code")
            } catch {
                failed += 1
                print("FAIL relay lost reply: \(error)")
            }
        }

        if failed > 0 {
            print("FAILED \(failed)")
            exit(1)
        }
        print("OK \(passed)")
    }
}
