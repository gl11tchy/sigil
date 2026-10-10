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
from unittest.mock import Mock, patch

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


class StartupTests(unittest.TestCase):
    def test_complete_root_only_unique_leaf_and_ambiguous_tree(self):
        graph = Graph()
        self.assertEqual([x.pid for x in diagnostic.startup_target(graph.identities[10], graph)], [10, 11, 12])
        graph.identities[13] = diagnostic.Identity(13, 10, (4, 0), "/owned/compiler")
        self.assertIsNone(diagnostic.startup_target(graph.identities[10], graph))
        graph.identities = {10: graph.identities[10]}
        self.assertEqual(diagnostic.startup_target(graph.identities[10], graph), (graph.identities[10],))

    def test_missing_reparented_reused_and_oversized_identity_are_refused(self):
        for failure in ("reparented", "reused", "denied", "wide", "deep"):
            with self.subTest(failure=failure):
                graph = Graph()
                root = graph.identities[10]
                if failure == "reparented":
                    graph.identities[11] = diagnostic.Identity(11, 99, (2, 0), "/owned/swift")
                    graph.children = lambda pid: [11] if pid == 10 else []
                elif failure == "reused":
                    graph.identities[10] = diagnostic.Identity(10, 1, (99, 0), root.executable)
                elif failure == "denied":
                    graph.children = Mock(side_effect=PermissionError("synthetic"))
                elif failure == "wide":
                    graph.children = lambda _: list(range(64))
                else:
                    graph.identities = {i: diagnostic.Identity(i, i - 1, (i, 0), "/owned/child") for i in range(1, 19)}
                    root = graph.identities[1]
                with self.assertRaises((RuntimeError, PermissionError)):
                    diagnostic.startup_target(root, graph)

    def collect(self, directory, graph, timeout=False, mutate=False):
        calls = []
        def launch(command, **kwargs):
            calls.append(command)
            Path(command[-1]).write_text("generated synthetic stack")
            sampler = Mock(returncode=None if timeout else 7)
            sampler.poll.side_effect = lambda: sampler.returncode
            if timeout:
                def wait(**kwargs):
                    if sampler.returncode is None:
                        raise subprocess.TimeoutExpired("synthetic", .01)
                    return sampler.returncode
                sampler.wait.side_effect = wait
                sampler.terminate.side_effect = lambda: setattr(sampler, "returncode", -15)
            else:
                sampler.wait.return_value = 7
            if mutate:
                graph.identities[10] = diagnostic.Identity(10, 1, (99, 0), "/owned/reused")
            return sampler
        with patch.object(os, "getpgid", return_value=10), patch.object(os, "getsid", return_value=10):
            result = diagnostic.collect_startup(Path(directory), 10, 1, [1, 2], graph, launch,
                                                gap_seconds=0, sampler_timeout=.01)
        return result, calls

    def test_root_then_unique_leaf_and_sampler_timeout(self):
        for timeout in (False, True):
            with self.subTest(timeout=timeout), tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
                result, calls = self.collect(directory, Graph(), timeout=timeout)
                self.assertEqual([c[1] for c in calls], ["10", "12"])
                self.assertEqual(result["outcome"], "finished")
                self.assertTrue(all(x["identity_revalidated"] for x in result["samples"]))
                if timeout:
                    self.assertTrue(all(x["timed_out"] for x in result["samples"]))

    def test_ambiguous_descendants_never_substitute_a_second_target(self):
        graph = Graph()
        graph.identities[13] = diagnostic.Identity(13, 10, (4, 0), "/owned/compiler")
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            result, calls = self.collect(directory, graph)
            self.assertEqual(len(calls), 1)
            self.assertEqual(result["outcome"], "partial-ambiguous")
            self.assertEqual(result["second_target"], "ambiguous")

    def test_reused_root_invalidates_and_removes_only_generated_report(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            result, calls = self.collect(directory, Graph(), mutate=True)
            self.assertEqual(len(calls), 1)
            self.assertEqual(result["outcome"], "diagnostic-unavailable")
            self.assertFalse(Path(directory, "sample-1.txt").exists())

    def test_quota_settlement_returns_only_proven_unused_slots(self):
        quota = diagnostic.SampleQuota()
        self.assertEqual([quota.take(), quota.take(), quota.take()], [1, 2, None])
        quota.settle([1, 2], 1)
        self.assertEqual(quota.take(), 2)
        self.assertIsNone(quota.take())
        quota.settle([1], 0)  # A stale reservation cannot refund another phase's slot.
        self.assertIsNone(quota.take())

    def test_collector_timeout_event_cancellation_and_no_reaping(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            worker = Mock(pid=50)
            worker.poll.side_effect = AssertionError("must not reap an active collector")
            worker.wait.return_value = -9
            launch = Mock(return_value=worker)
            capture = diagnostic.FocusedStartup(Path(directory), diagnostic.SampleQuota(), launch)
            root = Mock(pid=10)
            progress = diagnostic.Progress()
            with patch.object(diagnostic.time, "monotonic", return_value=45), \
                    patch.object(diagnostic, "unreaped_exit", return_value=None), \
                    patch.object(os, "getpgid", return_value=50), patch.object(os, "killpg") as kill:
                capture.tick(root, progress, 0, 45, 90)
                capture.tick(root, progress, 0, 75, 90)
                self.assertEqual(capture.receipt["outcome"], "collector-timeout")
                capture.cancel("test-event-observed", 75)
                capture.tick(root, progress, 0, 77, 90)
                self.assertEqual([c.args for c in kill.call_args_list], [(50, diagnostic.signal.SIGTERM), (50, diagnostic.signal.SIGKILL)])
                capture.close()
            worker.poll.assert_not_called()

    def test_event_before_checkpoint_and_insufficient_slack_do_not_launch(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            launch = Mock()
            progress = diagnostic.Progress()
            progress.feed(b"Test run started.\n", 1)
            capture = diagnostic.FocusedStartup(Path(directory), diagnostic.SampleQuota(), launch)
            capture.tick(Mock(pid=10), progress, 0, 45, 90)
            self.assertEqual(capture.receipt["outcome"], "test-event-observed")
            capture = diagnostic.FocusedStartup(Path(directory), diagnostic.SampleQuota(), launch)
            capture.tick(Mock(pid=10), diagnostic.Progress(), 0, 80, 90)
            self.assertEqual(capture.receipt["outcome"], "insufficient-budget")
            launch.assert_not_called()

    def test_first_event_cancels_active_collector_in_focused_loop(self):
        clock, turns, signals = [0], [0], []
        root = Mock(pid=10)
        root.wait.return_value = 23
        root.poll.side_effect = AssertionError("root must remain unreaped")
        worker = Mock(pid=50)
        worker.wait.return_value = -9
        launch = Mock(return_value=worker)
        selector = Mock()
        key = Mock(fd=123)
        selector.get_map.side_effect = lambda: {123: key} if turns[0] < 4 else {}
        def select(**_):
            turns[0] += 1
            clock[0] = (45, 50, 52, 53)[min(turns[0] - 1, 3)]
            return [(key, None)] if turns[0] == 2 else []
        selector.select.side_effect = select
        def exited(child):
            if child is root:
                return object() if turns[0] >= 4 else None
            return object() if turns[0] >= 4 else None
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            capture = diagnostic.FocusedStartup(Path(directory), diagnostic.SampleQuota(), launch)
            with patch.object(subprocess, "Popen", return_value=root), \
                    patch.object(diagnostic.selectors, "DefaultSelector", return_value=selector), \
                    patch.object(diagnostic, "unreaped_exit", side_effect=exited), \
                    patch.object(diagnostic.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(os, "read", return_value=b"Test first() started.\n"), \
                    patch.object(os, "getpgid", return_value=50), \
                    patch.object(os, "killpg", side_effect=lambda pid, sig: signals.append((pid, sig, clock[0]))):
                status, progress, receipt = diagnostic.run_focused_phase(["synthetic"], 90, io.BytesIO(), capture)
            self.assertEqual(status, 23)
            self.assertEqual(progress.last_event, 50)
            self.assertFalse(receipt["timed_out"])
            self.assertEqual(receipt["startup_diagnostic"]["stop_reason"], "test-event-observed")
            self.assertEqual(signals, [(50, diagnostic.signal.SIGTERM, 50), (50, diagnostic.signal.SIGKILL, 52)])
            launch.assert_called_once()
            root.poll.assert_not_called()

    def test_focused_deadline_precedes_collector_cleanup(self):
        clock, kills = [0], []
        def now():
            value = clock[0]
            clock[0] += 15
            return value
        worker = Mock(pid=50, returncode=None)
        worker.wait.return_value = -9
        root = Mock(pid=10, returncode=None)
        root.wait.side_effect = lambda **_: setattr(root, "returncode", -15) or -15
        selector = Mock()
        selector.get_map.return_value = {}
        selector.select.return_value = []
        def kill(pid, sig):
            kills.append((pid, sig, clock[0] - 15))
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            capture = diagnostic.FocusedStartup(Path(directory), diagnostic.SampleQuota(), Mock(return_value=worker))
            with patch.object(diagnostic.time, "monotonic", side_effect=now), \
                    patch.object(diagnostic, "unreaped_exit", side_effect=lambda child: None if child.returncode is None else object()), \
                    patch.object(subprocess, "Popen", return_value=root), \
                    patch.object(diagnostic.selectors, "DefaultSelector", return_value=selector), \
                    patch.object(os, "getpgid", side_effect=lambda pid: pid), patch.object(os, "killpg", side_effect=kill):
                status, _, receipt = diagnostic.run_focused_phase(
                    ["synthetic"], 90, io.BytesIO(), capture)
            target_kills = [x for x in kills if x[0] != 50]
            self.assertEqual(status, 124)
            self.assertTrue(receipt["timed_out"])
            self.assertEqual(target_kills[0][1:], (diagnostic.signal.SIGTERM, 90))
            self.assertLess(kills.index(target_kills[0]), next(i for i, x in enumerate(kills) if x[1] == diagnostic.signal.SIGKILL))

    def test_root_exit_is_observed_and_collector_closes_before_reaping(self):
        order = []
        child = Mock(pid=10)
        child.poll.side_effect = AssertionError("root PID must remain reserved")
        child.wait.side_effect = lambda **_: order.append("root-reaped") or 23
        selector = Mock()
        selector.get_map.return_value = {}
        selector.select.return_value = []
        capture = Mock(disabled=False)
        capture.receipt = {}
        capture.close.side_effect = lambda: order.append("collector-closed")
        with patch.object(subprocess, "Popen", return_value=child), \
                patch.object(diagnostic.selectors, "DefaultSelector", return_value=selector), \
                patch.object(diagnostic, "unreaped_exit", return_value=object()), \
                patch.object(diagnostic.time, "monotonic", side_effect=[0, 1, 3, 4]):
            status, _, _ = diagnostic.run_focused_phase(["synthetic"], 90, io.BytesIO(), capture)
        self.assertEqual(status, 23)
        self.assertLess(order.index("collector-closed"), order.index("root-reaped"))
        child.poll.assert_not_called()
        capture.cancel.assert_called_with("focused-exit", 1)

    def test_settlement_preserves_valid_root_and_shared_second_file_number(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            p = Path(directory)
            quota = diagnostic.SampleQuota()
            capture = diagnostic.FocusedStartup(p, quota)
            numbers = [quota.take(), quota.take()]
            capture.receipt["reserved_numbers"] = numbers
            (p / "sample-1.txt").write_text("validated generated root stack")
            (p / "sample-2.txt").write_text("unvalidated generated partial stack")
            diagnostic.save_startup(p, {"outcome": "partial-ambiguous", "reserved_numbers": numbers,
                                       "samples": [{"number": 1, "identity_revalidated": True}]})
            capture.settle()
            self.assertTrue((p / "sample-1.txt").exists())
            self.assertFalse((p / "sample-2.txt").exists())
            self.assertEqual(quota.take(), 2)
            self.assertIsNone(quota.take())

    def test_denied_or_unknown_collection_retains_quota_without_retry(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            quota = diagnostic.SampleQuota()
            capture = diagnostic.FocusedStartup(Path(directory), quota)
            numbers = [quota.take(), quota.take()]
            capture.receipt["reserved_numbers"] = numbers
            diagnostic.save_startup(Path(directory), {"outcome": "diagnostic-unavailable",
                "reserved_numbers": numbers, "samples": [], "limitation": "PermissionError"})
            capture.settle()
            self.assertIsNone(quota.take())
            self.assertEqual(capture.receipt["limitation"], "PermissionError")

    def test_worker_rejects_outside_ci_before_any_process_access(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(diagnostic, "OwnedProcesses") as process:
            with self.assertRaises(SystemExit):
                diagnostic.startup_main(["10", "1", "1", "2"])
            process.assert_not_called()

    def test_worker_rejects_wrong_parent_ref_and_quota(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            for focused, arguments in ((False, ["10", "1", "1"]),
                                        (True, ["10", "0", "1"]),
                                        (True, ["0", str(os.getppid()), "1"]),
                                        (True, ["10", str(os.getppid()), "3"])):
                with self.subTest(focused=focused, args=arguments), \
                        patch.object(diagnostic, "context", return_value=(Path(directory), Path(directory), focused)), \
                        patch.object(diagnostic, "OwnedProcesses") as process:
                    with self.assertRaises(SystemExit):
                        diagnostic.startup_main(arguments)
                    process.assert_not_called()

    def test_child_status_uses_exact_pid_and_wnowait(self):
        child = Mock(pid=10)
        with patch.object(os, "waitid", return_value=None) as wait:
            self.assertIsNone(diagnostic.unreaped_exit(child))
            wait.assert_called_once_with(os.P_PID, 10, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        child.poll.assert_not_called()

    def test_collector_cleanup_does_not_extend_term_to_kill_grace(self):
        clock, calls, signals = [0], [], []
        child = Mock(pid=10)
        def wait(timeout=None):
            calls.append(timeout)
            if len(calls) == 1:
                clock[0] += timeout
                raise subprocess.TimeoutExpired("synthetic", timeout)
            return -9
        child.wait.side_effect = wait
        selector = Mock()
        selector.get_map.return_value = {}
        selector.select.side_effect = lambda **_: clock.__setitem__(0, 90) or []
        capture = Mock(disabled=False)
        capture.receipt = {}
        capture.close.side_effect = lambda: clock.__setitem__(0, clock[0] + 2)
        with patch.object(subprocess, "Popen", return_value=child), \
                patch.object(diagnostic.selectors, "DefaultSelector", return_value=selector), \
                patch.object(diagnostic, "unreaped_exit", return_value=None), \
                patch.object(diagnostic.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(os, "getpgid", return_value=10), \
                patch.object(os, "killpg", side_effect=lambda pid, sig: signals.append((pid, sig, clock[0]))):
            status, _, _ = diagnostic.run_focused_phase(["synthetic"], 90, io.BytesIO(), capture)
        self.assertEqual(status, 124)
        self.assertEqual(calls[:2], [3, 5])
        self.assertEqual(signals, [(10, diagnostic.signal.SIGTERM, 90), (10, diagnostic.signal.SIGKILL, 95)])

    def test_metadata_cap_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            p = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "metadata exceeds"):
                diagnostic.save_startup(p, {"generated": "x" * diagnostic.PROGRESS_LIMIT})
            target = p / "owned-target"
            target.write_text("keep this generated fixture")
            (p / "focused-startup-receipt.json").symlink_to(target)
            with self.assertRaises(OSError):
                diagnostic.save_startup(p, {"samples": []})
            self.assertEqual(target.read_text(), "keep this generated fixture")

    def test_denied_capture_never_retries_or_samples_another_pid(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            launch = Mock(side_effect=PermissionError("synthetic"))
            with patch.object(os, "getpgid", return_value=10), patch.object(os, "getsid", return_value=10):
                result = diagnostic.collect_startup(Path(directory), 10, 1, [1, 2], Graph(), launch)
            self.assertEqual(launch.call_count, 1)
            self.assertEqual(result["outcome"], "diagnostic-unavailable")
            self.assertEqual(result["limitation"], "PermissionError")

    def test_wrong_focused_session_refuses_capture(self):
        with tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
            launch = Mock()
            with patch.object(os, "getpgid", return_value=99), patch.object(os, "getsid", return_value=10):
                result = diagnostic.collect_startup(Path(directory), 10, 1, [1, 2], Graph(), launch)
            launch.assert_not_called()
            self.assertEqual(result["outcome"], "diagnostic-unavailable")

    def test_full_gate_uses_only_remaining_quota_without_overwriting_startup(self):
        class SyntheticGraph:
            root = None
            def identity(self, pid, ppid):
                self.root = self.root or pid
                return diagnostic.Identity(pid, ppid, (1, 0),
                    "/owned/verify" if pid == self.root else "/owned/swiftpm-testing-helper")
            def children(self, pid):
                return [self.root + 1] if pid == self.root else []
        for used in (0, 1, 2):
            with self.subTest(used=used), tempfile.TemporaryDirectory(prefix="sigil-startup-unit-") as directory:
                p = Path(directory)
                quota = diagnostic.SampleQuota()
                for _ in range(used):
                    number = quota.take()
                    (p / f"sample-{number}.txt").write_text("earlier validated startup stack")
                calls = []
                def launch(command, **kwargs):
                    calls.append(command)
                    Path(command[-1]).write_text("generated full-gate stack")
                    sampler = Mock(returncode=7)
                    sampler.poll.return_value = 7
                    return sampler
                program = f"import time; print({diagnostic.MARKER.decode()!r},flush=True); time.sleep(.7); raise SystemExit(23)"
                status = diagnostic.run_verify([sys.executable, "-u", "-c", program],
                    p, SyntheticGraph(), io.BytesIO(), launch,
                    stall_seconds=.01, gap_seconds=.01, sampler_timeout=.01, quota=quota)
                self.assertEqual(status, 23)
                self.assertEqual(len(calls), 2 - used)
                self.assertEqual([Path(x[-1]).name for x in calls],
                                 [f"sample-{i}.txt" for i in range(used + 1, 3)])
                for number in range(1, used + 1):
                    self.assertEqual((p / f"sample-{number}.txt").read_text(), "earlier validated startup stack")


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
                "print('Test brokenNewVersionMetadataStillReportsAReadProblem() passed after .3 seconds.',flush=True); "
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
                             (["swift", "test", "--skip-build", "--verbose", "--no-parallel", "--filter",
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
