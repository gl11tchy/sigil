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
    def test_watcher_scope_disarms_after_the_suite_finishes(self):
        for ending in diagnostic.WATCHER_DONE:
            with self.subTest(ending=ending):
                progress = diagnostic.Progress(diagnostic.WATCHER_MARKER, diagnostic.WATCHER_DONE)
                progress.feed(diagnostic.MARKER + b"\n", 0)
                self.assertFalse(progress.stalled(1000))
                progress.feed(diagnostic.WATCHER_MARKER + b"\n", 10)
                self.assertTrue(progress.stalled(190))
                progress.feed(ending + b" after 1 second.\n", 191)
                self.assertFalse(progress.stalled(1000))
                self.assertTrue(progress.marker_seen)

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


class FocusedTests(unittest.TestCase):
    def test_suite_completion_cancels_sampling_without_stopping_verify(self):
        class SyntheticGraph:
            root = None

            def identity(self, pid, ppid):
                self.root = self.root or pid
                executable = "/owned/verify" if pid == self.root else "/owned/swiftpm-testing-helper"
                return diagnostic.Identity(pid, ppid, (1, 0), executable)

            def children(self, pid):
                return [self.root + 1] if pid == self.root else []

        with tempfile.TemporaryDirectory(prefix="sigil-ci-suite-unit-") as directory:
            program = (
                "import time; "
                f"print({diagnostic.WATCHER_MARKER.decode()!r},flush=True); time.sleep(.3); "
                "print('Suite NativeSessionWatcherTests passed after .3 seconds.',flush=True); "
                "print('Test later() started.',flush=True); time.sleep(.25); raise SystemExit(23)"
            )
            calls = []

            def fake_sampler(command, **kwargs):
                calls.append(command)
                # Generated Python child; never invoke sample or query libproc locally.
                return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(2)"], **kwargs)

            status = diagnostic.run_verify(
                [sys.executable, "-u", "-c", program], Path(directory), SyntheticGraph(), io.BytesIO(),
                sample_popen=fake_sampler, stall_seconds=.01, gap_seconds=.01,
                marker=diagnostic.WATCHER_MARKER, stop_markers=diagnostic.WATCHER_DONE,
            )
            receipt = json.loads((Path(directory) / "receipt.json").read_text())
            self.assertEqual(status, 23)
            self.assertEqual(len(calls), 1)
            self.assertTrue(receipt["samples"][0]["stopped_on_suite_exit"])
            self.assertTrue(receipt["marker_seen"])

    def progress(self, count=14, completed=True, parameters=True):
        progress = diagnostic.Progress(marker=diagnostic.FOCUSED_SUITE + b" started.")
        progress.feed(diagnostic.FOCUSED_SUITE + b" started.\n", 0)
        if completed:
            progress.feed(diagnostic.FOCUSED_SUITE + b" passed after 1 second.\n", 1)
        if parameters:
            progress.feed(b"Test aReusedOrReparentedDescendantInvalidatesTheWholeObservation(reparented:) with 2 test cases passed\n", 1)
            progress.feed(b"Test missingOrDeniedKernelEvidenceNeverFallsBackToGuessing(boundary:) with 3 test cases passed\n", 1)
        progress.feed(f"Test run with {count} tests in 1 suite passed after 1 second.\n".encode(), 1)
        return progress

    def test_missing_partial_and_wrong_case_counts_cannot_pass(self):
        self.assertTrue(diagnostic.focused_passed(self.progress()))
        self.assertFalse(diagnostic.focused_passed(diagnostic.Progress()))
        self.assertFalse(diagnostic.focused_passed(self.progress(completed=False)))
        self.assertFalse(diagnostic.focused_passed(self.progress(parameters=False)))
        for count in (0, 1, 13, 15, 17):
            self.assertFalse(diagnostic.focused_passed(self.progress(count=count)))

    def test_compile_then_exact_suite_are_bounded_and_recorded(self):
        phase = {"timed_out": False, "elapsed_seconds": 1, "command_exit_status": 0}
        with tempfile.TemporaryDirectory(prefix="sigil-focused-unit-") as directory:
            with patch.object(diagnostic, "run_focused_phase", side_effect=[
                (0, diagnostic.Progress(), dict(phase)), (0, self.progress(), dict(phase)),
            ]) as run, patch("sys.stdout", io.StringIO()):
                self.assertEqual(diagnostic.run_focused(Path(directory), io.BytesIO()), 0)
            self.assertEqual(run.call_args_list[0].args[:2],
                             (["swift", "build", "--build-tests", "--jobs", "2"], 300))
            self.assertEqual(run.call_args_list[1].args[:2],
                             (["swift", "test", "--skip-build", "--no-parallel", "--filter",
                               r"^SigilKitTests\.ProcessOpenFilesTests/"], 90))
            receipt = json.loads((Path(directory) / "focused-receipt.json").read_text())
            self.assertEqual(receipt["outcome"], "passed")
            self.assertTrue(receipt["phases"][1]["all_expected_tests_passed"])

    def test_compile_failure_or_timeout_does_not_start_tests(self):
        for status in (23, 124):
            with self.subTest(status=status), tempfile.TemporaryDirectory(prefix="sigil-focused-unit-") as directory:
                with patch.object(diagnostic, "run_focused_phase", return_value=(
                    status, diagnostic.Progress(), {"timed_out": status == 124},
                )) as run, patch("sys.stdout", io.StringIO()):
                    self.assertEqual(diagnostic.run_focused(Path(directory), io.BytesIO()), status)
                self.assertEqual(run.call_count, 1)

    def test_a_successful_empty_selection_is_still_a_failure(self):
        with tempfile.TemporaryDirectory(prefix="sigil-focused-unit-") as directory:
            with patch.object(diagnostic, "run_focused_phase", return_value=(
                0, diagnostic.Progress(), {},
            )), patch("sys.stdout", io.StringIO()):
                self.assertEqual(diagnostic.run_focused(Path(directory), io.BytesIO()), 1)

    def test_timeout_applies_only_to_a_fresh_synthetic_phase_session(self):
        status, _, receipt = diagnostic.run_focused_phase(
            [sys.executable, "-c", "import time; time.sleep(2)"], 0.05, io.BytesIO())
        self.assertEqual(status, 124)
        self.assertTrue(receipt["timed_out"])

    def test_nonzero_phase_exit_is_preserved(self):
        status, _, receipt = diagnostic.run_focused_phase(
            [sys.executable, "-c", "raise SystemExit(23)"], 2, io.BytesIO())
        self.assertEqual(status, 23)
        self.assertFalse(receipt["timed_out"])

    def test_only_pr142_runs_focused_before_the_full_gate(self):
        root = Path(diagnostic.__file__).resolve().parent.parent
        for pr, focused_status in ((142, 0), (142, 23), (145, 0), (141, 0)):
            with self.subTest(pr=pr, status=focused_status), tempfile.TemporaryDirectory(prefix="sigil-ci-unit-") as directory:
                environment = {
                    "CI": "true", "GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "gl11tchy-team/sigil",
                    "GITHUB_EVENT_NAME": "pull_request", "GITHUB_REF": f"refs/pull/{pr}/merge",
                    "SIGIL_SWIFT_DIAGNOSTICS": "1", "GITHUB_WORKSPACE": str(root),
                    "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1", "RUNNER_TEMP": directory,
                }
                order = []
                with patch.dict(os.environ, environment, clear=True), patch.object(sys, "platform", "darwin"), \
                        patch.object(Path, "cwd", return_value=root), \
                        patch.object(diagnostic, "OwnedProcesses") as processes, \
                        patch.object(diagnostic, "run_focused", side_effect=lambda *_: order.append("focused") or focused_status) as focused, \
                        patch.object(diagnostic, "run_verify", side_effect=lambda *_, **__: order.append("verify") or 31) as verify, \
                        patch.object(subprocess, "Popen") as launch:
                    if pr == 141:
                        with self.assertRaises(SystemExit):
                            diagnostic.main()
                    else:
                        self.assertEqual(diagnostic.main(), focused_status if pr == 142 and focused_status else 31)
                    launch.assert_not_called()
                    if pr == 141 or pr == 142 and focused_status:
                        processes.assert_not_called()
                        verify.assert_not_called()
                    if pr == 142:
                        self.assertEqual(order, ["focused"] if focused_status else ["focused", "verify"])
                    elif pr == 145:
                        focused.assert_not_called()
                        self.assertEqual(order, ["verify"])
                    if verify.called:
                        self.assertEqual(verify.call_args.args[0], [str(root / "Scripts/verify.sh")])
                        self.assertEqual(verify.call_args.kwargs["marker"],
                                         diagnostic.WATCHER_MARKER if pr == 142 else diagnostic.MARKER)
                        self.assertEqual(verify.call_args.kwargs["stop_markers"],
                                         diagnostic.WATCHER_DONE if pr == 142 else ())


if __name__ == "__main__":
    unittest.main()
