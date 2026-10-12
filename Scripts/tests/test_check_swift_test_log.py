import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("completion_guard", Path(__file__).parents[1] / "check-swift-test-log.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class CompletionGuardTests(unittest.TestCase):
    def test_normal_complete_run_passes(self):
        guard.validate("Executed 37 tests, with 0 failures\n✔ Test run with 1224 tests in 108 suites passed after 200 seconds.\n")

    def test_green_exit_with_recorded_issue_fails(self):
        with self.assertRaisesRegex(ValueError, "recorded failure"):
            guard.validate("✘ Test seam recorded an issue: wrong event\n✔ Test run with 1224 tests passed after 200 seconds.\n")

    def test_early_zero_exit_without_summary_fails(self):
        with self.assertRaisesRegex(ValueError, "completed"):
            guard.validate("Executed 37 tests, with 0 failures\n◇ Test cappedClick() started.\n")

    def test_failed_run_summary_fails(self):
        with self.assertRaisesRegex(ValueError, "recorded failure"):
            guard.validate("✘ Test run with 1224 tests failed after 200 seconds with 1 issue.\n")

    def test_duplicate_summary_fails(self):
        with self.assertRaisesRegex(ValueError, "found 2"):
            guard.validate("✔ Test run with 1 tests passed.\n✔ Test run with 1 tests passed.\n")

    def test_more_tests_after_summary_fails(self):
        with self.assertRaisesRegex(ValueError, "after its completion"):
            guard.validate("✔ Test run with 1 tests passed.\n◇ Test another() started.\n")

    def test_ansi_summary_passes(self):
        guard.validate("\x1b[32m✔ Test run with 1 tests passed.\x1b[0m\n")


if __name__ == "__main__":
    unittest.main()
