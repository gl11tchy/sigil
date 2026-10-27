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

        let derived = URL(fileURLWithPath: try XCTUnwrap(environment["SIGIL_UI_DERIVED_DATA"]))
            .standardizedFileURL.resolvingSymlinksInPath()
        let host = URL(fileURLWithPath: try XCTUnwrap(environment["SIGIL_UI_HOST_PATH"]))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard host.path.hasPrefix(derived.path + "/"), host.lastPathComponent == "SigilSidebarFixtureHost.app",
            let bundle = Bundle(url: host), bundle.bundleIdentifier == "com.gl11tchy.sigil.sidebar-fixture-host",
            bundle.executableURL?.lastPathComponent == "SigilSidebarFixtureHost"
        else { XCTFail("Requires the fresh isolated fixture host, never the installed app"); return }

        XCTAssertNotEqual(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
        XCTAssertNotEqual(bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool, true)
        let app = XCUIApplication(url: host)
        guard app.state == .notRunning else {
            XCTFail("The exact fixture is already running; do not replace another launch")
            return
        }
        let keys = ["HOME", "CFFIXED_USER_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME",
                    "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "TMPDIR", "PATH", "SHELL"]
        let isolated = try Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, try XCTUnwrap(environment[key], "Missing isolated launch environment: \(key)"))
        })
        let home = derived.deletingLastPathComponent().appendingPathComponent("home")
            .resolvingSymlinksInPath().path
        for key in keys.filter({ $0 != "PATH" }) {
            let path = URL(fileURLWithPath: try XCTUnwrap(isolated[key])).resolvingSymlinksInPath().path
            guard path == home || path.hasPrefix(home + "/") else {
                XCTFail("Launch environment escaped the isolated home: \(key)")
                return
            }
        }
        guard isolated["PATH"] == isolated["HOME"]! + "/bin:/usr/bin:/bin:/usr/sbin:/sbin" else {
            XCTFail("Requires only fake providers and system tools on PATH")
            return
        }
        app.launchEnvironment = isolated
        app.launch()
        defer { app.terminate() } // Only this newly launched fixture at its fresh product URL.
        let observed = app.state
        XCTAssertEqual(observed, .runningForeground, "XCUIApplication foreground launch precondition")
        guard observed == .runningForeground else { return }
        let receipt: [String: Any] = [
            "sourceSHA": expected, "nonce": try XCTUnwrap(environment["SIGIL_UI_NONCE"]),
            "hostPath": host.path, "bundleID": try XCTUnwrap(bundle.bundleIdentifier),
            "foreground": true, "stateRawValue": observed.rawValue,
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(
            to: URL(fileURLWithPath: try XCTUnwrap(environment["SIGIL_UI_RESULT_PATH"])), options: .atomic)
        print("REA-1230 XCUI launch: source=\(expected), host=\(host.path), state=\(observed.rawValue); About/Close untested")
    }
}
