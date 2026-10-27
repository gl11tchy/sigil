import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location("foreground_driver", SCRIPTS / "about-foreground-ui-test.py")
driver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(driver)
sys.path.pop(0)
SCENARIOS = ["pass-v1", "pass-v2", "wrong-source", "dirty-source", "wrong-target", "escaped-app",
             "failed-case", "skipped-case", "duplicate-case", "wrong-case", "authorization-failure",
             "parse-failure", "changed-product", "missing-receipt", "wrong-receipt"]


class ForegroundDriverTests(unittest.TestCase):
    def test_bounded_driver_paths_without_native_execution(self):
        for scenario in SCENARIOS:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(prefix="sigil-foreground-mock-") as temporary:
                root = Path(temporary) / "source"
                source = root / "Tests/AboutUI/AboutForegroundUITests.swift"
                source.parent.mkdir(parents=True)
                source.write_text("generated fixture source")
                artifacts = Path(temporary) / "artifacts"
                calls, state = [], {}

                class Process:
                    def __init__(self, command, env, stdout, stderr, start_new_session):
                        self.build = "build-for-testing" in command
                        calls.append(command)
                        assert command[0] == "xcodebuild" and start_new_session
                        assert stderr == subprocess.STDOUT
                        home = Path(env["HOME"])
                        for key in ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "SHELL", "TMPDIR"]:
                            assert Path(env[key]).is_relative_to(home)
                        assert (home / "bin/grok").read_text().endswith('"1.0.40"\n')
                        if self.build:
                            assert command[command.index("-scheme") + 1] == "SigilAboutUI"
                            derived = Path(command[command.index("-derivedDataPath") + 1])
                            products = derived / "Build/Products"
                            runner = products / "Debug/SigilAboutUITests-Runner.app"
                            app = products / "Debug/SigilSidebarFixtureHost.app"
                            bundle = runner / "Contents/PlugIns/SigilAboutUITests.xctest"
                            for product, executable, identifier in [
                                (runner, "SigilAboutUITests-Runner", "com.gl11tchy.sigil.about-ui-tests.xctrunner"),
                                (app, "SigilSidebarFixtureHost", "com.gl11tchy.sigil.sidebar-fixture-host"),
                                (bundle, "SigilAboutUITests", "com.gl11tchy.sigil.about-ui-tests")]:
                                contents = product / "Contents"
                                (contents / "MacOS").mkdir(parents=True)
                                (contents / "Info.plist").write_bytes(plistlib.dumps({
                                    "CFBundleExecutable": executable, "CFBundleIdentifier": identifier}))
                                (contents / "MacOS" / executable).write_bytes(b"generated non-executable product")
                            state["app"] = app
                            target = {"BlueprintName": "SigilAboutUITests",
                                      "TestHostPath": "__TESTROOT__/Debug/SigilAboutUITests-Runner.app",
                                      "TestBundlePath": "__TESTHOST__/Contents/PlugIns/SigilAboutUITests.xctest",
                                      "UITargetAppPath": "__TESTROOT__/Debug/SigilSidebarFixtureHost.app"}
                            if scenario == "escaped-app":
                                target["UITargetAppPath"] = str(Path(temporary) / "outside.app")
                            name = "SigilSidebarHostTests" if scenario == "wrong-target" else "SigilAboutUITests"
                            parameters = {"__xctestrun_metadata__": {"FormatVersion": 1}, name: target}
                            if scenario == "pass-v2":
                                parameters = {"__xctestrun_metadata__": {"FormatVersion": 2},
                                              "TestConfigurations": [{"TestTargets": [target]}]}
                            (products / "fixture.xctestrun").write_bytes(plistlib.dumps(parameters))
                        else:
                            assert "-only-testing:SigilAboutUITests/AboutForegroundUITests/testIsolatedFixtureLaunchIsForeground" in command
                            parameters = plistlib.loads(Path(command[command.index("-xctestrun") + 1]).read_bytes())
                            target = (parameters["TestConfigurations"][0]["TestTargets"][0]
                                      if scenario == "pass-v2" else parameters["SigilAboutUITests"])
                            launch = target["EnvironmentVariables"]
                            assert launch["HOME"] == str(home) and launch["GITHUB_SHA"] == "a" * 40
                            assert Path(launch["SIGIL_UI_HOST_PATH"]) == state["app"]
                            result = Path(command[command.index("-resultBundlePath") + 1])
                            result.mkdir()
                            (result / "generated-raw-result").write_text(scenario)
                            if scenario == "authorization-failure":
                                stdout.write(b"Generated XCTest UI authorization failure; no grant attempted\n")
                            if scenario == "changed-product":
                                (state["app"] / "Contents/MacOS/SigilSidebarFixtureHost").write_bytes(b"changed product")
                            if scenario != "missing-receipt":
                                Path(launch["SIGIL_UI_RESULT_PATH"]).write_text(json.dumps({
                                    "sourceSHA": "a" * 40, "nonce": "wrong" if scenario == "wrong-receipt" else launch["SIGIL_UI_NONCE"],
                                    "hostPath": str(state["app"].resolve()), "foreground": True,
                                    "bundleID": "com.gl11tchy.sigil.sidebar-fixture-host"}))

                    def wait(self, timeout):
                        assert timeout == (900 if self.build else 240)
                        return 65 if not self.build and scenario in ["failed-case", "authorization-failure"] else 0

                def output(command, **kwargs):
                    if command[:3] == ["git", "-C", str(root)]:
                        if command[3:] == ["rev-parse", "HEAD"]:
                            return "a" * 40 + "\n"
                        if command[3:] == ["rev-parse", "HEAD^{tree}"]:
                            return "b" * 40 + "\n"
                        if command[3:] == ["status", "--porcelain", "--untracked-files=all"]:
                            return " M fixture\n" if scenario == "dirty-source" else ""
                        raise AssertionError(command)
                    assert command[:4] == ["xcrun", "xcresulttool", "get", "test-results"]
                    kind = command[4]
                    assert kind in ["summary", "tests"]
                    if scenario == "parse-failure":
                        return b"generated malformed JSON"
                    outcome = {"failed-case": "Failed", "skipped-case": "Skipped"}.get(scenario, "Passed")
                    cases = [{"nodeType": "Test Case", "nodeIdentifier": driver.EXPECTED, "result": outcome}]
                    if scenario == "authorization-failure": cases = []
                    if scenario == "duplicate-case": cases *= 2
                    if scenario == "wrong-case": cases[0]["nodeIdentifier"] = "Other/testCase()"
                    summary = {"passedTests": sum(c["result"] == "Passed" for c in cases),
                               "failedTests": sum(c["result"] == "Failed" for c in cases),
                               "skippedTests": sum(c["result"] == "Skipped" for c in cases)}
                    return json.dumps(summary if kind == "summary" else {"testNodes": cases}).encode()

                environment = {"CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
                               "GITHUB_SHA": "a" * 40, "SIGIL_EXPECTED_SOURCE_SHA": ("c" if scenario == "wrong-source" else "a") * 40,
                               "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "SIGIL_SIDEBAR_ARTIFACTS": str(artifacts)}
                failure = None
                with patch.dict(os.environ, environment, clear=True), patch.object(driver, "ROOT", root), \
                        patch.object(subprocess, "Popen", Process), patch.object(subprocess, "check_output", output), \
                        contextlib.redirect_stdout(io.StringIO()):
                    try:
                        driver.main()
                    except (ValueError, OSError) as error:
                        failure = str(error)
                self.assertEqual(failure is None, scenario in ["pass-v1", "pass-v2"], failure)
                expected_errors = {
                    "wrong-source": "source-pinned GitHub Actions dispatch", "dirty-source": "exact clean reviewed source",
                    "wrong-target": "separate XCTest UI target", "escaped-app": "escaped fresh DerivedData",
                    "failed-case": "exactly one foreground", "skipped-case": "exactly one foreground",
                    "duplicate-case": "exactly one foreground", "wrong-case": "exactly one foreground",
                    "authorization-failure": "exactly one foreground", "changed-product": "product changed after execution",
                    "missing-receipt": "No such file", "wrong-receipt": "exact launched fixture",
                }
                if scenario in expected_errors:
                    self.assertIn(expected_errors[scenario], failure)
                if scenario in ["wrong-source", "dirty-source"]:
                    self.assertEqual(calls, [])
                    continue
                record = json.loads((artifacts / "foreground-source.json").read_text())
                if scenario in ["wrong-target", "escaped-app"]:
                    self.assertEqual(len(calls), 1)
                    self.assertTrue((artifacts / "foreground.xctestrun").is_file())
                    self.assertIn("productCandidates", record)
                    continue
                self.assertEqual(len(calls), 2)
                self.assertTrue((artifacts / "foreground.xcresult/generated-raw-result").is_file())
                self.assertTrue((artifacts / "foreground-test.log").is_file())
                self.assertEqual(record["stage"] == "validated-exact-one-foreground-pass", failure is None)
                if scenario == "parse-failure":
                    self.assertEqual(record["stage"], "reading-results")
                    self.assertEqual((artifacts / "foreground-summary.json").read_bytes(), b"generated malformed JSON")
                if scenario == "authorization-failure":
                    self.assertIn("authorization failure", (artifacts / "foreground-test.log").read_text())
                    self.assertEqual(record["testExit"], 65)

    def test_non_ci_context_never_starts_a_process(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(subprocess, "Popen") as process, \
                patch.object(subprocess, "check_output") as output:
            with self.assertRaisesRegex(ValueError, "source-pinned GitHub Actions dispatch"):
                driver.main()
            process.assert_not_called()
            output.assert_not_called()


if __name__ == "__main__":
    unittest.main()
