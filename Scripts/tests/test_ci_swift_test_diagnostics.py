"""Synthetic subprocess and identity regressions; no Swift tests or app windows."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "ci_swift_diagnostics", Path(__file__).resolve().parents[1] / "ci-swift-test-diagnostics.py"
)
diagnostic = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = diagnostic
SPEC.loader.exec_module(diagnostic)


class Graph:
    def __init__(self):
        self.identities = {
            10: diagnostic.Identity(10, 1, (1, 0), "/owned/verify"),
            11: diagnostic.Identity(11, 10, (2, 0), "/owned/swift"),
            12: diagnostic.Identity(12, 11, (3, 0), "/owned/swiftpm-testing-helper"),
        }

    def identity(self, pid, ppid):
        result = self.identities[pid]
        if result.ppid != ppid:
            raise RuntimeError("owned process parent changed")
        return result

    def children(self, parent):
        return [item.pid for item in self.identities.values() if item.ppid == parent]


class DiagnosticsTests(unittest.TestCase):
    def test_three_minutes_requires_marker_and_resets_on_test_progress(self):
        progress = diagnostic.Progress()
        progress.feed(b"Test earlier() started.\n", 0)
        self.assertFalse(progress.stalled(1000))
        progress.feed(diagnostic.MARKER[:20], 10)
        progress.feed(diagnostic.MARKER[20:] + b"\n", 10)
        self.assertFalse(progress.stalled(189.999))
        self.assertTrue(progress.stalled(190))
        progress.feed(b"non-test output\n", 190)
        self.assertTrue(progress.stalled(190))
        progress.feed(b"Test following() passed after 0.001 seconds.\n", 191)
        self.assertFalse(progress.stalled(370.999))
        self.assertTrue(progress.stalled(371))

    def test_progress_and_partial_lines_are_bounded(self):
        progress = diagnostic.Progress()
        progress.feed(b"x" * (diagnostic.PROGRESS_LIMIT * 3), 0)
        self.assertEqual(len(progress.partial), diagnostic.PROGRESS_LIMIT)
        progress.feed(b"\n" + b"Test following() passed\n" * 10000, 1)
        self.assertLessEqual(len(progress.tail), diagnostic.PROGRESS_LIMIT)

    def test_unique_owned_test_and_birth_identity(self):
        graph = Graph()
        chain = diagnostic.find_test(graph.identities[10], graph)
        self.assertEqual([item.pid for item in chain], [10, 11, 12])
        graph.identities[12] = diagnostic.Identity(12, 11, (99, 0), "/owned/swiftpm-testing-helper")
        with self.assertRaisesRegex(RuntimeError, "birth"):
            diagnostic.revalidate(chain, graph)

    def test_foreign_pid_and_ambiguous_owned_targets_are_refused(self):
        graph = Graph()
        original_children = graph.children
        graph.identities[99] = diagnostic.Identity(99, 88, (1, 0), "/foreign/swiftpm-testing-helper")
        graph.children = lambda parent: [99] if parent == 10 else original_children(parent)
        with self.assertRaisesRegex(RuntimeError, "parent"):
            diagnostic.find_test(graph.identities[10], graph)
        graph.children = original_children
        graph.identities[13] = diagnostic.Identity(13, 10, (4, 0), "/owned/swiftpm-testing-helper")
        with self.assertRaisesRegex(RuntimeError, "exactly one owned swiftpm-testing-helper process; found 2$"):
            diagnostic.find_test(graph.identities[10], graph)

    def test_absent_short_name_and_xctest_targets_are_refused(self):
        for basename in (None, "swiftpm-testing", "swiftpm-xctest-helper"):
            with self.subTest(basename=basename):
                graph = Graph()
                if basename is None:
                    del graph.identities[12]
                else:
                    graph.identities[12] = diagnostic.Identity(12, 11, (3, 0), f"/owned/{basename}")
                with self.assertRaisesRegex(RuntimeError, "exactly one owned swiftpm-testing-helper process; found 0$"):
                    diagnostic.find_test(graph.identities[10], graph)

    def test_xctest_helper_does_not_make_owned_test_ambiguous(self):
        graph = Graph()
        graph.identities[13] = diagnostic.Identity(13, 10, (4, 0), "/owned/swiftpm-xctest-helper")
        chain = diagnostic.find_test(graph.identities[10], graph)
        self.assertEqual([item.pid for item in chain], [10, 11, 12])

    def test_outside_ci_cannot_launch_verification(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(subprocess, "Popen") as launch:
            with self.assertRaises(SystemExit):
                diagnostic.main()
            launch.assert_not_called()

    def test_sampler_file_size_has_a_kernel_bound(self):
        with tempfile.TemporaryDirectory(prefix="sigil-ci-diagnostic-limit-") as directory:
            report = Path(directory) / "synthetic-sample.txt"
            program = f"open({str(report)!r}, 'wb').write(b'x' * {diagnostic.SAMPLE_LIMIT + 1000})"
            subprocess.run([sys.executable, "-c", program],
                           preexec_fn=diagnostic.sample_file_limit,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertEqual(report.stat().st_size, diagnostic.SAMPLE_LIMIT)

    def test_inherited_pipe_cannot_hold_verify_result_open(self):
        with tempfile.TemporaryDirectory(prefix="sigil-ci-diagnostic-pipe-") as directory:
            program = "import subprocess; subprocess.Popen(['/bin/sleep', '2']); raise SystemExit(12)"
            start = time.monotonic()
            status = diagnostic.run_verify([sys.executable, "-c", program],
                                           Path(directory), Graph(), io.BytesIO())
            self.assertEqual(status, 12)
            self.assertLess(time.monotonic() - start, 1.7)

    @unittest.skipUnless(sys.platform == "darwin", "macOS owned child API")
    def test_libproc_enumerates_only_own_children(self):
        processes = diagnostic.OwnedProcesses()
        children = [subprocess.Popen(["/bin/sleep", "2"]) for _ in range(3)]
        try:
            actual = processes.children(os.getpid())
            for child in children:
                self.assertIn(child.pid, actual)
                identity = processes.identity(child.pid, os.getpid())
                self.assertEqual(identity.ppid, os.getpid())
                self.assertEqual(Path(identity.executable).name, "sleep")
        finally:
            for child in children:
                child.terminate()
                child.wait()

    @unittest.skipUnless(sys.platform == "darwin", "macOS owned child API")
    def test_owned_pair_preserves_failure_even_when_sampler_fails_or_times_out(self):
        with tempfile.TemporaryDirectory(prefix="sigil-ci-diagnostic-test-") as directory:
            fixture = Path(directory)
            worker = fixture / "swiftpm-testing-helper"
            source = fixture / "synthetic-worker.c"
            source.write_text("#include <unistd.h>\nint main(void) { usleep(700000); return 0; }\n")
            subprocess.run(["/usr/bin/xcrun", "clang", str(source), "-o", str(worker)],
                           check=True, capture_output=True)
            program = (
                "import subprocess,sys; "
                f"child=subprocess.Popen([{str(worker)!r}]); "
                f"print({diagnostic.MARKER.decode()!r},flush=True); "
                "child.wait(); sys.exit(23)"
            )
            for outcome in ["failure", "timeout", "unavailable"]:
                with self.subTest(sampler=outcome):
                    evidence = fixture / outcome
                    evidence.mkdir()
                    calls = []

                    def fake_sampler(command, **kwargs):
                        calls.append(command)
                        # Generated sampler only; never invoke /usr/bin/sample locally.
                        if outcome == "unavailable":
                            raise PermissionError("synthetic denial")
                        fake = "import time; time.sleep(2)" if outcome == "timeout" else (
                            f"from pathlib import Path; Path({command[-1]!r}).write_text('synthetic stack'); "
                            "raise SystemExit(7)"
                        )
                        return subprocess.Popen([sys.executable, "-c", fake], **kwargs)

                    output = io.BytesIO()
                    status = diagnostic.run_verify(
                        [sys.executable, "-u", "-c", program], evidence,
                        diagnostic.OwnedProcesses(), output, sample_popen=fake_sampler,
                        stall_seconds=0.1, gap_seconds=0.01, sampler_timeout=0.1,
                    )
                    receipt = json.loads((evidence / "receipt.json").read_text())
                    self.assertEqual(status, 23)
                    self.assertEqual(len(calls), 1 if outcome == "unavailable" else 2, receipt)
                    self.assertEqual(calls[0][2:5], ["5", "10", "-mayDie"])
                    self.assertEqual(output.getvalue(), diagnostic.MARKER + b"\n")
                    self.assertEqual(receipt["verify_exit_status"], 23)
                    self.assertEqual(receipt["test_ancestry"][-1]["executable"], str(worker.resolve()))
                    if outcome == "failure":
                        self.assertEqual(calls[0][1], calls[1][1])
                        self.assertEqual([item["exit_status"] for item in receipt["samples"]], [7, 7])
                    elif outcome == "timeout":
                        self.assertTrue(all(item["timed_out"] for item in receipt["samples"]))
                    else:
                        self.assertEqual(receipt["limitation"], "PermissionError")

    @unittest.skipUnless(sys.platform == "darwin", "macOS owned child API")
    def test_unavailable_artifact_directory_keeps_verify_status(self):
        with tempfile.TemporaryDirectory(prefix="sigil-ci-diagnostic-test-") as directory:
            # Intentionally absent directory proves diagnostic write failure is nonfatal.
            status = diagnostic.run_verify(
                [sys.executable, "-c", "print('synthetic'); raise SystemExit(0)"],
                Path(directory) / "absent", diagnostic.OwnedProcesses(), io.BytesIO(),
            )
            self.assertEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
