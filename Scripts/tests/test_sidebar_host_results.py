import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("host_results", Path(__file__).parents[1] / "sidebar_host_results.py")
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def fixture(pointer="Passed", other="Passed"):
    nodes = [{"nodeType": "Test Case", "nodeIdentifier": name, "result": pointer} for name in host.POINTER_TESTS]
    nodes += [{"nodeType": "Test Case", "nodeIdentifier": name, "result": other} for name in host.OTHER_TESTS]
    return {"testNodes": [{"nodeType": "Test Suite", "children": nodes}]}


class HostedResultTests(unittest.TestCase):
    def test_eight_real_passes(self):
        self.assertIn("eight fixtures passed", host.validate(
            {"passedTests": 8, "failedTests": 0, "skippedTests": 0}, fixture(), 0))

    def test_only_the_four_pointer_skips_are_accepted_and_reported(self):
        result = host.validate({"passedTests": 4, "failedTests": 0, "skippedTests": 4}, fixture("Skipped"), 0)
        self.assertIn("four REA-1350 pointer fixtures skipped", result)
        self.assertIn("manual verification remains pending", result)

    def test_unrelated_skips_cannot_satisfy_matching_counts(self):
        tree = fixture("Skipped", "Skipped")
        for node in tree["testNodes"][0]["children"][:2]:
            node["result"] = "Passed"
        with self.assertRaisesRegex(ValueError, "unrelated"):
            host.validate({"passedTests": 4, "failedTests": 0, "skippedTests": 4}, tree, 0)

    def test_partial_or_duplicate_results_fail(self):
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                tree = fixture()
                nodes = tree["testNodes"][0]["children"]
                if duplicate:
                    nodes[-1] = nodes[0]
                else:
                    nodes.pop()
                with self.assertRaises(ValueError):
                    host.validate({"passedTests": 8, "failedTests": 0, "skippedTests": 0}, tree, 0)

    def test_failed_command_or_behavior_never_passes(self):
        with self.assertRaises(ValueError):
            host.validate({"passedTests": 8, "failedTests": 0, "skippedTests": 0}, fixture(), 1)
        with self.assertRaises(ValueError):
            host.validate({"passedTests": 2, "failedTests": 4, "skippedTests": 0}, fixture("Failed"), 0)


if __name__ == "__main__":
    unittest.main()
