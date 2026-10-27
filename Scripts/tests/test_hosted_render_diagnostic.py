"""Pure generated-report checks; the hosted driver runs these before browser setup."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("render_diagnostic",
                                             Path(__file__).resolve().parents[1] / "hosted-render-diagnostic.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
HEAD = "b" * 40
FILE = Path("/generated/Sidereal/test/browser/web-find.spec.mjs")


def fixture(phase="clean"):
    records = []
    for repeat in range(3 if phase == "clean" else 1):
        records.append({
            "title": module.TITLE, "project": "chromium",
            "location": {"file": str(FILE), "line": 21, "column": 1},
            "repeat": repeat, "retry": 0, "expected": "passed", "status": "passed",
            "attachments": {
                "hosted-render-identity": {
                    "source": module.SOURCE, "diagnostic": HEAD, "browser": module.BROWSER,
                    "node": "v22.23.3", "phase": phase, "profiled": phase == "profile",
                    "acceptanceEligible": phase == "clean",
                    "protocol": {"product": "HeadlessChrome/" + module.BROWSER},
                },
                "400KB-direct-render-durations": {
                    "cpuRate": 4, "warmups": 5, "count": 20, "rawCharacters": 404620,
                    "formattedCharacters": 381981, "samples": [10] * 20,
                    "median": 10, "p95": 10, "maximum": 10,
                },
            },
        })
    return {"schema": 1, "phase": phase, "discovered": len(records), "status": "passed",
            "errors": [], "records": records}


class ReportValidation(unittest.TestCase):
    def test_bypass_environment_is_refused_even_when_empty(self):
        module.refuse_bypasses({})
        for name in ("SIDEREAL_PERF_BASELINE", "SIDEREAL_TEST_ORIGIN"):
            for value in ("", "0", "1"):
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    module.refuse_bypasses({name: value})

    def test_clean_and_profile_are_distinct(self):
        for phase in ("clean", "profile"):
            result = module.validate(fixture(phase), phase, HEAD, FILE)
            self.assertTrue(result["passed"])
            self.assertEqual(result["cleanTimingEvidence"], phase == "clean")

    def test_zero_extra_wrong_skipped_cancelled_retried_and_mixed_cases_fail(self):
        changes = [
            lambda r: r.update(records=[]),
            lambda r: r["records"].append(copy.deepcopy(r["records"][0])),
            lambda r: r["records"][0].update(title="different case"),
            lambda r: r["records"][0].update(status="skipped"),
            lambda r: r["records"][0].update(status="interrupted"),
            lambda r: r["records"][0].update(status="timedOut"),
            lambda r: r["records"][0].update(retry=1),
            lambda r: r["records"][0].update(repeat=1),
            lambda r: r["records"][0]["attachments"].clear(),
            lambda r: r["records"][0]["attachments"]["hosted-render-identity"].update(profiled=True),
            lambda r: r["records"][0]["attachments"]["hosted-render-identity"].update(source="c" * 40),
            lambda r: r["records"][0]["attachments"]["hosted-render-identity"].update(browser="unexpected"),
            lambda r: r["records"][0]["attachments"]["400KB-direct-render-durations"].update(samples=[]),
            lambda r: r["records"][0]["attachments"]["400KB-direct-render-durations"].update(p95=1),
        ]
        for change in changes:
            report = fixture()
            change(report)
            with self.subTest(change=change), self.assertRaises(ValueError):
                module.validate(report, "clean", HEAD, FILE)

    def test_failures_are_retained_and_gate_cannot_be_bypassed(self):
        report = fixture()
        timing = report["records"][0]["attachments"]["400KB-direct-render-durations"]
        timing.update(samples=[10] * 18 + [25.2, 55.3], p95=25.2, maximum=55.3)
        with self.assertRaises(ValueError):
            module.validate(report, "clean", HEAD, FILE)
        report["records"][0]["status"] = report["status"] = "failed"
        result = module.validate(report, "clean", HEAD, FILE)
        self.assertTrue(result["valid"])
        self.assertFalse(result["passed"])
        self.assertEqual(len(result["records"]), 3)


if __name__ == "__main__":
    unittest.main()
