import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("about_host_results", Path(__file__).resolve().parents[1] / "about_host_results.py")
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class AboutHostResultsTests(unittest.TestCase):
    def test_only_exact_single_pass_is_accepted(self):
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": validator.EXPECTED, "result": "Passed"}]}
        summary = {"passedTests": 1, "failedTests": 0, "skippedTests": 0}
        self.assertIn("passed", validator.validate(summary, tree, 0))
        for field, value in [("nodeIdentifier", "Other/fixture()"), ("result", "Skipped"), ("result", "Failed")]:
            bad = {"testNodes": [{**tree["testNodes"][0], field: value}]}
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validator.validate(summary, bad, 0)
        for status, count in [(1, 1), (0, 0), (0, 2)]:
            with self.subTest(status=status, count=count), self.assertRaises(ValueError):
                validator.validate(summary, {"testNodes": tree["testNodes"] * count}, status)
        with self.assertRaises(ValueError):
            validator.validate({**summary, "skippedTests": 1}, tree, 0)


if __name__ == "__main__":
    unittest.main()
