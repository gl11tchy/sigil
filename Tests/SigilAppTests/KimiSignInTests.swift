import Foundation
import SigilKit
import Testing

@testable import SigilApp

struct KimiSignInTests {
    @Test func theLoginPromptGivesTheCodeAndPage() {
        let output = """
            Opening browser for Kimi device login: https://www.kimi.com/code/authorize_device?user_code=ABCD-1234
            If the browser did not open, paste the URL above and enter code: ABCD-1234
            Code expires in 1800s.
            Waiting for authorization to complete...
            """
        let prompt = KimiLogin.prompt(in: output)
        #expect(prompt.code == "ABCD-1234")
        #expect(prompt.page?.absoluteString == "https://www.kimi.com/code/authorize_device?user_code=ABCD-1234")
        #expect(KimiLogin.prompt(in: "Opening browser").code == nil)
    }

    @Test func aFailedLoginShowsTheCLIsLastLine() {
        #expect(KimiLogin.failure(in: "Waiting...\nLogin cancelled.\n", status: 1) == "Login cancelled.")
        #expect(KimiLogin.failure(in: "zsh: command not found: kimi\n", status: 127) == "Kimi Code is not installed.")
        #expect(KimiLogin.failure(in: "", status: 1) == "Sign-in did not finish.")
    }

    @Test func anAPIKeyNamesTheModelInMemory() {
        #expect(
            KimiCode.apiKeyEnvironment(key: "sk-test", model: " kimi-k2.7-code ")
                == ["KIMI_MODEL_NAME": "kimi-k2.7-code", "KIMI_MODEL_API_KEY": "sk-test"])
        #expect(KimiCode.apiKeyEnvironment(key: "sk-test", model: "")["KIMI_MODEL_NAME"] == KimiCode.defaultModel)
    }

    @Test func theAccountTokenFollowsKimiCodeHome() {
        #expect(
            KimiCode.accountCredentials(environment: ["KIMI_CODE_HOME": "/tmp/kimi"]).path
                == "/tmp/kimi/credentials/kimi-code.json")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(
            KimiCode.accountCredentials(environment: [:]).path == "\(home)/.kimi-code/credentials/kimi-code.json")
    }
}

@MainActor
struct KimiLoginTests {
    private func login(_ script: String) -> KimiLogin {
        KimiLogin {
            GrokLaunchSpec.HostCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        }
    }

    private func settle(_ login: KimiLogin, until done: (KimiLogin.State) -> Bool) async -> Bool {
        for _ in 0..<100 {
            if done(login.state) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done(login.state)
    }

    @Test func cancellingTheBrowserStepReturnsQuietly() async {
        let login = login(
            "printf 'Opening browser: https://www.kimi.com/code/x\\nIf the browser did not open, enter code: AB12-CD34\\n'; exec sleep 30"
        )
        login.start()
        let page = URL(string: "https://www.kimi.com/code/x")
        #expect(await settle(login) { $0 == .waiting(code: "AB12-CD34", page: page) })
        login.cancel()
        #expect(await settle(login) { $0 == .idle })
    }

    @Test func aFailedLoginShowsItsLastLine() async {
        let login = login("echo 'Waiting for authorization to complete...'; echo 'Network error'; exit 3")
        login.start()
        #expect(await settle(login) { $0 == .failed("Network error") })
    }
}
