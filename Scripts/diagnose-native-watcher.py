#!/usr/bin/env python3
"""Temporary REA-1216 diagnostic; never run outside this branch's CI VM."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time


def stop_owned(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main():
    if not (
        os.environ.get("CI") == "true"
        and os.environ.get("GITHUB_ACTIONS") == "true"
        and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
        and os.environ.get("GITHUB_REPOSITORY") == "gl11tchy-team/sigil"
        and os.environ.get("GITHUB_REF_NAME") == "fix/rea-1216-verified-codex-binding"
    ):
        raise SystemExit("This diagnostic is restricted to PR142's manual CI job.")
    binary = Path(sys.argv[1]).resolve()
    binary.relative_to(Path(os.environ["GITHUB_WORKSPACE"]).resolve() / ".build")
    if binary.name != "SigilPackageTests" or not binary.is_file():
        raise SystemExit("Expected the CI-built SigilPackageTests executable.")
    run_temp = Path(os.environ["RUNNER_TEMP"])
    evidence = run_temp / (
        "sigil-native-watcher-" + os.environ["GITHUB_RUN_ID"]
        + "-" + os.environ["GITHUB_RUN_ATTEMPT"]
    )
    evidence.mkdir()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    child = sampler = reader = None
    boundary = threading.Event()
    advanced = threading.Event()
    receipt = {"head": os.environ["GITHUB_SHA"], "outcome": "starting"}
    home = tempfile.TemporaryDirectory(prefix="sigil-stack-home-", dir=run_temp)
    try:
        temporary = Path(home.name)
        (temporary / "tmp").mkdir()
        environment = dict(os.environ, HOME=home.name, TMPDIR=str(temporary / "tmp"))
        # SwiftPM's macOS Swift Testing host loads this bundle in its own PID.
        swift = Path(subprocess.check_output(
            ["/usr/bin/xcrun", "--find", "swift"], text=True, timeout=5,
        ).strip()).resolve()
        helper = swift.parents[1] / "libexec/swift/pm/swiftpm-testing-helper"
        if not helper.is_file() or not os.access(helper, os.X_OK):
            receipt["outcome"] = "missing-test-host"
            raise SystemExit("Expected the selected toolchain's Swift Testing helper.")
        platform = Path(subprocess.check_output(
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-platform-path"],
            text=True, timeout=5,
        ).strip())
        libraries = [platform / "Developer/usr/lib"]
        testing_override = swift.parents[1] / "lib/swift/macosx/testing"
        if testing_override.is_dir():
            libraries.insert(0, testing_override)
        for key, paths in (
            ("DYLD_FRAMEWORK_PATH", [platform / "Developer/Library/Frameworks",
                                     platform / "Developer/Library/PrivateFrameworks"]),
            ("DYLD_LIBRARY_PATH", libraries),
        ):
            environment[key] = ":".join(filter(None, [environment.get(key)] + list(map(str, paths))))
        child = subprocess.Popen(
            [str(helper), "--test-bundle-path", str(binary),
             "--testing-library", "swift-testing", "--no-parallel",
             "--filter", r"^SigilKitTests\.(MacFindTerminalControllerTests/anEmptyQueryClearsWithoutReadingTheRows\(\)/|NativeSessionWatcherTests/)"],
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        receipt["test_pid"] = child.pid

        def drain():
            with (evidence / "test.log").open("wb", buffering=0) as output:
                for line in child.stdout:
                    output.write(line)
                    if b"test defer: cleanup returned" in line:
                        boundary.set()
                    if boundary.is_set() and (
                        (b"Test case passing" in line and b".codex" in line)
                        or (b"Test existingNativeFoldersDiscoverAppendsAndNewTranscripts" in line
                            and b"passed" in line)
                        or b"adjacent index:" in line
                    ):
                        advanced.set()

        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        deadline = time.monotonic() + 90
        boundary_at = None
        while time.monotonic() < deadline:
            if child.poll() is not None:
                reader.join(timeout=2)
                receipt["outcome"] = "focused-process-exited"
                return child.returncode if child.returncode else (0 if boundary.is_set() else 2)
            if boundary.is_set() and boundary_at is None:
                boundary_at = time.monotonic()
            if boundary_at is not None and not advanced.is_set() and time.monotonic() - boundary_at >= 10:
                # Do not poll/wait/reap the test child until the sampler exits.
                # A child that exits remains a zombie, reserving this exact PID.
                with (evidence / "sample-command.log").open("wb") as output:
                    sampler = subprocess.Popen(
                        ["/usr/bin/sample", str(child.pid), "5", "10", "-mayDie",
                         "-file", str(evidence / "stacks.txt")],
                        stdout=output, stderr=subprocess.STDOUT,
                    )
                    try:
                        sampler.wait(timeout=min(10, max(0.1, deadline - time.monotonic())))
                    except subprocess.TimeoutExpired:
                        stop_owned(sampler)
                        receipt["outcome"] = "sampler-timeout"
                        return 2
                receipt["sample_exit"] = sampler.returncode
                receipt["outcome"] = "captured" if sampler.returncode == 0 else "sampling-failed"
                if advanced.is_set():
                    receipt["outcome"] = "boundary-advanced-during-capture"
                # Sampling denial/failure is recorded; no sudo, retry or fallback.
                return 124 if sampler.returncode == 0 else 2
            time.sleep(0.1)
        receipt["outcome"] = "outside-boundary-deadline" if advanced.is_set() else "process-deadline"
        return 124
    except (OSError, subprocess.SubprocessError) as error:
        receipt["outcome"] = "launcher-failed" if child is None else "diagnostic-error"
        receipt["error"] = str(error)
        return 2
    except KeyboardInterrupt:
        receipt["outcome"] = "interrupted"
        return 130
    finally:
        # Stop the owned sampler before reaping the sampled child.
        stop_owned(sampler)
        stop_owned(child)
        if reader is not None:
            reader.join(timeout=2)
        receipt["boundary_seen"] = boundary.is_set()
        receipt["boundary_advanced"] = advanced.is_set()
        receipt["test_exit"] = None if child is None else child.returncode
        home.cleanup()
        (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt))


if __name__ == "__main__":
    raise SystemExit(main())
