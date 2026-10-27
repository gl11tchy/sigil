import XCTest

/// Separate XCTest UI runner: prove launch context before any About/Close action.
final class AboutForegroundUITests: XCTestCase {
    @MainActor
    func testIsolatedFixtureLaunchIsForeground() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let expected = try XCTUnwrap(environment["SIGIL_EXPECTED_SOURCE_SHA"])
        guard environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true",
            expected.count == 40, expected.allSatisfy({ "0123456789abcdef".contains($0) }),
            environment["GITHUB_SHA"] == expected
        else { XCTFail("Requires the exact source-pinned CI diagnostic"); return }

        let nonce = try XCTUnwrap(environment["SIGIL_UI_NONCE"])
        let resultURL = URL(fileURLWithPath: try XCTUnwrap(environment["SIGIL_UI_RESULT_PATH"]))
        let diagnosticURL = resultURL.deletingLastPathComponent().appendingPathComponent("foreground-environment.json")
        func bounded(_ value: String?) -> String { String((value ?? "<unset>").prefix(512)) }
        // Record strings only: never resolve or read the runner's ambient home.
        var diagnostic: [String: Any] = [
            "sourceSHA": expected, "nonce": nonce, "stage": "before-launch-plan-validation",
            "runnerHOME": bounded(environment["HOME"]),
            "runnerCFFIXED_USER_HOME": bounded(environment["CFFIXED_USER_HOME"]),
            "declaredDerivedData": bounded(environment["SIGIL_UI_DERIVED_DATA"]),
            "declaredHostPath": bounded(environment["SIGIL_UI_HOST_PATH"]),
            "maximumCharactersPerPath": 512,
        ]
        func saveDiagnostic() throws {
            try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
                .write(to: diagnosticURL, options: .atomic)
        }
        try saveDiagnostic()
        let planData = Data(try XCTUnwrap(environment["SIGIL_UI_LAUNCH_PLAN"]).utf8)
        guard planData.count <= 16384 else { XCTFail("Oversized launch plan"); return }
        let plan = try JSONDecoder().decode(FixtureLaunchPlan.self, from: planData)
        diagnostic["declaredGeneratedRoot"] = bounded(plan.generatedRoot)
        diagnostic["declaredFixtureHOME"] = bounded(plan.environment["HOME"])
        try saveDiagnostic()
        guard plan.sourceSHA == expected, plan.nonce == nonce, plan.generatedRoot.hasPrefix("/"),
            !plan.generatedRoot.split(separator: "/").contains("..")
        else { XCTFail("Launch plan does not match the exact source/nonce"); return }
        let root = URL(fileURLWithPath: plan.generatedRoot).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("sigil-about-xcui-"),
            root.path == plan.generatedRoot, root.path == root.resolvingSymlinksInPath().path
        else { XCTFail("Requires the canonical generated diagnostic root"); return }
        let derived = URL(fileURLWithPath: try XCTUnwrap(environment["SIGIL_UI_DERIVED_DATA"]))
            .standardizedFileURL
        guard derived.path == root.appendingPathComponent("DerivedData").path,
            derived.path == derived.resolvingSymlinksInPath().path
        else {
            XCTFail("DerivedData does not belong to the generated launch plan")
            return
        }
        let host = URL(fileURLWithPath: try XCTUnwrap(environment["SIGIL_UI_HOST_PATH"]))
            .standardizedFileURL
        guard host.path.hasPrefix(derived.path + "/"), host.lastPathComponent == "SigilSidebarFixtureHost.app",
            host.path == host.resolvingSymlinksInPath().path,
            let bundle = Bundle(url: host), bundle.bundleIdentifier == "com.gl11tchy.sigil.sidebar-fixture-host",
            bundle.executableURL?.lastPathComponent == "SigilSidebarFixtureHost"
        else { XCTFail("Requires the fresh isolated fixture host, never the installed app"); return }

        XCTAssertNotEqual(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
        XCTAssertNotEqual(bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool, true)
        let home = root.appendingPathComponent("home").path
        diagnostic["computedExpectedHOME"] = bounded(home)
        diagnostic["derivedParentExpectedHOME"] = bounded(
            derived.deletingLastPathComponent().appendingPathComponent("home").resolvingSymlinksInPath().path)
        try saveDiagnostic()
        let isolated = plan.environment
        let required = [
            "HOME": home, "CFFIXED_USER_HOME": home, "CODEX_HOME": home + "/.codex",
            "CLAUDE_CONFIG_DIR": home + "/.claude", "GROK_HOME": home + "/.grok",
            "XDG_CACHE_HOME": home + "/cache", "XDG_CONFIG_HOME": home + "/config",
            "TMPDIR": home + "/tmp/", "SHELL": home + "/bin/sigil-fixture-shell",
            "PATH": home + "/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        guard isolated == required else {
            XCTFail("Launch plan must contain exactly the generated homes and fake-provider PATH")
            return
        }
        let keys = Array(required.keys)
        for key in keys.filter({ $0 != "PATH" }) {
            let url = URL(fileURLWithPath: try XCTUnwrap(isolated[key])).standardizedFileURL
            guard url.resolvingSymlinksInPath().path == url.path else {
                XCTFail("Generated launch path contains a symlink: \(key)")
                return
            }
        }
        diagnostic["stage"] = "launch-environment-validated"
        try saveDiagnostic()
        let app = XCUIApplication(url: host)
        guard app.state == .notRunning else {
            XCTFail("The exact fixture is already running; do not replace another launch")
            return
        }
        app.launchEnvironment = isolated
        app.launch()
        defer { app.terminate() } // Only this newly launched fixture at its fresh product URL.
        let observed = app.state
        XCTAssertEqual(observed, .runningForeground, "XCUIApplication foreground launch precondition")
        guard observed == .runningForeground else { return }
        let receipt: [String: Any] = [
            "sourceSHA": expected, "nonce": nonce,
            "hostPath": host.path, "bundleID": try XCTUnwrap(bundle.bundleIdentifier),
            "foreground": true, "stateRawValue": observed.rawValue, "requestedLaunchEnvironment": isolated,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(
            to: resultURL, options: .atomic)
        print("REA-1230 XCUI launch: source=\(expected), host=\(host.path), state=\(observed.rawValue); About/Close untested")
    }
}

private struct FixtureLaunchPlan: Decodable {
    let sourceSHA: String
    let nonce: String
    let generatedRoot: String
    let environment: [String: String]
}
