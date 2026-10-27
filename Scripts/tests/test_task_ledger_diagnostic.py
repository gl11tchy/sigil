import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, mock_open, patch

spec = importlib.util.spec_from_file_location("ledger_diagnostic", Path(__file__).parents[1] / "task_ledger_diagnostic.py")
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def passing_log():
    return ("Executed 0 tests, with 0 failures (0 unexpected) in 0 seconds\n"
            f"◇ Suite {driver.SUITE} started.\n◇ Test {driver.CASE} started.\n"
            + "".join(f"SIGIL_LEDGER_ROUND_COMPLETED {n}\n" for n in range(8))
            + f"✔ Test {driver.CASE} passed after 0.1 seconds.\n"
            f"✔ Suite {driver.SUITE} passed after 0.1 seconds.\n"
            "✔ Test run with 1 test in 1 suite passed after 0.1 seconds.\n")


class LedgerDiagnosticTests(unittest.TestCase):
    def test_exact_case_and_eight_rounds_pass(self):
        self.assertEqual(driver.validate(passing_log(), 0)["rounds"], 8)

    def test_legacy_plural_summary_and_ansi_pass(self):
        text = passing_log().replace("1 test in 1 suite", "1 tests in 1 suites")
        self.assertEqual(driver.validate("\x1b[32m" + text + "\x1b[0m", 0)["passed"], 1)

    def test_reject_nonzero_cancelled_and_timeout_status(self):
        for status in (1, -15, 124):
            with self.subTest(status=status), self.assertRaises(ValueError):
                driver.validate(passing_log(), status)

    def test_reject_zero_missing_duplicate_or_wrong_count_summary(self):
        for text in ("", passing_log().replace("1 test in", "0 tests in"),
                     passing_log().replace("1 test in", "2 tests in"), passing_log() * 2,
                     passing_log().replace("✔ Test run with", "missing summary with")):
            with self.subTest(text=text[-80:]), self.assertRaises(ValueError):
                driver.validate(text, 0)

    def test_reject_skip_cancel_issue_and_lock_observation_on_green_exit(self):
        for marker in ("skipped", "cancelled", "canceled", "timed out", "recorded an issue",
                       'SIGIL_LEDGER_LOCK_DIAGNOSTIC {"lockOpenErrno":"2"}',
                       "SIGIL_LEDGER_LOCK_DIAGNOSTIC_ENCODING_FAILED", "✘ failure"):
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                driver.validate(passing_log() + marker, 0)

    def test_reject_wrong_or_extra_test_suite_and_parameterized_case(self):
        for text in (passing_log().replace(driver.CASE, "other()"),
                     passing_log().replace(driver.SUITE, "OtherSuite"),
                     passing_log() + "◇ Test other() started.\n",
                     passing_log() + "◇ Suite OtherSuite started.\n",
                     passing_log() + "◇ Test case passing 1 argument started.\n",
                     passing_log().replace("Executed 0 tests", "Executed 1 test")):
            with self.subTest(text=text[-80:]), self.assertRaises(ValueError):
                driver.validate(text, 0)

    def test_reject_missing_duplicate_reordered_and_late_rounds(self):
        for text in (passing_log().replace("SIGIL_LEDGER_ROUND_COMPLETED 7\n", ""),
                     passing_log() + "SIGIL_LEDGER_ROUND_COMPLETED 7\n",
                     passing_log() + "SIGIL_LEDGER_ROUND_COMPLETED malformed\n",
                     passing_log().replace("COMPLETED 0", "COMPLETED 9"),
                     "SIGIL_LEDGER_ROUND_COMPLETED 0\n" + passing_log().replace(
                         "SIGIL_LEDGER_ROUND_COMPLETED 0\n", "")):
            with self.subTest(text=text[-80:]), self.assertRaises(ValueError):
                driver.validate(text, 0)

    def test_reject_reordered_lifecycle(self):
        text = passing_log().replace(f"◇ Test {driver.CASE} started.\n", "")
        with self.assertRaises(ValueError):
            driver.validate(text + f"◇ Test {driver.CASE} started.\n", 0)

    def test_context_requires_exact_manual_ref_repo_and_sha(self):
        env = {"CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch",
               "SIGIL_TASK_LEDGER_DIAGNOSTIC": "true",
               "GITHUB_REPOSITORY": "gl11tchy/sigil", "GITHUB_REF": driver.REF,
               "SIGIL_EXPECTED_SOURCE_SHA": "a" * 40, "GITHUB_SHA": "a" * 40}
        self.assertEqual(driver.require_context(env), "a" * 40)
        for key, value in (("CI", "false"), ("GITHUB_ACTIONS", "false"),
                           ("SIGIL_TASK_LEDGER_DIAGNOSTIC", "false"),
                           ("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_REF", "refs/heads/main"),
                           ("GITHUB_REPOSITORY", "other/repo"), ("GITHUB_SHA", "b" * 40),
                           ("SIGIL_EXPECTED_SOURCE_SHA", "main")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                driver.require_context({**env, key: value})

    def test_source_rejects_dirty_or_wrong_checkout(self):
        with patch.object(driver, "git", side_effect=["a" * 40, "", "b" * 40]):
            self.assertEqual(driver.require_source("a" * 40), "b" * 40)
        for results in (["c" * 40], ["a" * 40, " M tracked"], ["a" * 40, "?? untracked"]):
            with patch.object(driver, "git", side_effect=results), self.assertRaises(ValueError):
                driver.require_source("a" * 40)

    def test_command_selects_only_existing_case_from_fresh_build(self):
        build, test = driver.commands(Path("/synthetic/build"))
        self.assertIn("--build-tests", build)
        self.assertIn("--skip-build", test)
        self.assertIn("--no-parallel", test)
        self.assertEqual(test[-2:], ["--filter", driver.FILTER])
        self.assertEqual(build[build.index("--scratch-path") + 1], "/synthetic/build")
        self.assertEqual(test[test.index("--scratch-path") + 1], "/synthetic/build")

    def test_timeout_only_signals_the_child_group_and_returns_failure(self):
        child = MagicMock(pid=123)
        child.wait.side_effect = [subprocess.TimeoutExpired("mock", 1), 0]
        with patch.object(Path, "open", mock_open()), patch.object(driver.subprocess, "Popen", return_value=child), \
                patch.object(driver.os, "killpg") as kill:
            self.assertEqual(driver.run(["mock"], {}, 1, Path("/mock/log")), {"status": 124, "timedOut": True})
            kill.assert_called_once_with(123, driver.signal.SIGTERM)

    def test_mocked_pipeline_retains_failure_and_never_runs_test_after_failed_build(self):
        for failure in ("mocked", "build", "test", None):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="ledger-driver-") as folder:
                root = Path(folder).resolve()
                artifacts = root / "sigil-ledger-1-1"
                env = {"RUNNER_TEMP": str(root), "GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1",
                       "SIGIL_LEDGER_ARTIFACTS": str(artifacts), "SIGIL_EXPECTED_SOURCE_SHA": "a" * 40}
                binary = artifacts / "work/build/mock-product"
                calls = []

                def invoke(command, environment, timeout, log):
                    phase = log.stem
                    calls.append(phase)
                    if phase == "build":
                        binary.parent.mkdir(parents=True, exist_ok=True)
                        binary.write_bytes(b"mock, never executed")
                    self.assertNotIn("GH_TOKEN", environment)
                    self.assertTrue(Path(environment["HOME"]).is_relative_to(artifacts))
                    text = passing_log() if phase == "test" else "mocked phase output\n"
                    if phase == failure:
                        text += 'SIGIL_LEDGER_LOCK_DIAGNOSTIC {"lockOpenErrno":"2"}\n'
                    log.write_text(text)
                    return {"status": int(phase == failure), "timedOut": False}

                with patch.dict(driver.os.environ, env, clear=True), \
                        patch.object(driver, "require_context", return_value="a" * 40), \
                        patch.object(driver, "require_source", return_value="b" * 40), \
                        patch.object(driver.sys, "platform", "darwin"), \
                        patch.object(driver, "product", return_value=binary), \
                        patch.object(driver, "run", side_effect=invoke):
                    status = driver.main()
                receipt = json.loads((artifacts / "receipt.json").read_text())
                self.assertEqual(status, int(failure is not None))
                self.assertEqual(calls, {"mocked": ["mocked"], "build": ["mocked", "build"]}.get(
                    failure, ["mocked", "build", "test"]))
                if failure:
                    self.assertEqual(receipt["outcome"], "failed-or-unverified")
                    self.assertIn("SIGIL_LEDGER_LOCK_DIAGNOSTIC", (artifacts / f"{failure}.log").read_text())
                else:
                    self.assertEqual(receipt["counts"]["passed"], 1)
                    self.assertEqual(receipt["counts"]["rounds"], 8)

    def test_artifact_write_error_is_not_retried_or_redirected(self):
        with tempfile.TemporaryDirectory(prefix="ledger-write-") as folder:
            root = Path(folder).resolve()
            env = {"RUNNER_TEMP": str(root), "GITHUB_RUN_ID": "1", "GITHUB_RUN_ATTEMPT": "1",
                   "SIGIL_LEDGER_ARTIFACTS": str(root / "sigil-ledger-1-1")}
            with patch.dict(driver.os.environ, env, clear=True), \
                    patch.object(Path, "write_text", side_effect=PermissionError("mocked write denial")) as write:
                with self.assertRaises(PermissionError):
                    driver.main()
                self.assertEqual(write.call_count, 1)


if __name__ == "__main__":
    unittest.main()
