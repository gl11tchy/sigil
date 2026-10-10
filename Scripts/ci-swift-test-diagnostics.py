#!/usr/bin/env python3
"""Temporary PR145 CI instrumentation; run the unchanged verification gate."""
import ctypes
from dataclasses import asdict, dataclass
import json
import os
from pathlib import Path
import re
import resource
import selectors
import subprocess
import sys
import time

STALL_SECONDS = 180
SAMPLE_SECONDS = 5
SAMPLE_GAP_SECONDS = 10
SAMPLER_TIMEOUT_SECONDS = 10
PROGRESS_LIMIT = 64 * 1024
SAMPLE_LIMIT = 1024 * 1024
MARKER = b"Test submittingTheAlreadyStoredPathDoesNotReapply() started."
EVENT = re.compile(rb"(?:Test |Suite |Test run ).*(?:started\.|passed|failed|recorded an issue)")


@dataclass(frozen=True)
class Identity:
    pid: int
    ppid: int
    birth: tuple
    executable: str


class BSDInfo(ctypes.Structure):
    # PROC_PIDTBSDINFO, from the macOS SDK's sys/proc_info.h.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved",
    )] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in ("nfiles", "pgid", "jobc", "tdev", "tpgid")
    ] + [("nice", ctypes.c_int32), ("birth_sec", ctypes.c_uint64), ("birth_usec", ctypes.c_uint64)]


class OwnedProcesses:
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_listchildpids.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listchildpids.restype = ctypes.c_int
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int

    def identity(self, pid, expected_parent):
        info = BSDInfo()
        size = ctypes.sizeof(info)
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
            raise RuntimeError("owned process identity unavailable")
        if info.pid != pid or info.ppid != expected_parent:
            raise RuntimeError("owned process parent changed")
        path = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(pid, path, len(path)) <= 0:
            raise RuntimeError("owned executable identity unavailable")
        return Identity(pid, info.ppid, (info.birth_sec, info.birth_usec), os.fsdecode(path.value))

    def children(self, parent):
        # Enumerate only this owned parent's children, never the host process table.
        buffer = (ctypes.c_int * 64)()
        count = self.lib.proc_listchildpids(parent, buffer, ctypes.sizeof(buffer))
        if count < 0 or count >= len(buffer):
            raise RuntimeError("owned child enumeration unavailable or exceeds bound")
        return list(buffer[:count])


def revalidate(chain, processes):
    for identity in chain:
        if processes.identity(identity.pid, identity.ppid) != identity:
            raise RuntimeError("owned process birth or executable changed")


def find_test(root, processes):
    pending, matches, visited = [(root,)], [], set()
    while pending:
        chain = pending.pop()
        revalidate(chain, processes)
        parent = chain[-1]
        if parent.pid in visited or len(visited) >= 128 or len(chain) > 16:
            raise RuntimeError("owned process tree exceeds bound")
        visited.add(parent.pid)
        for pid in processes.children(parent.pid):
            child = processes.identity(pid, parent.pid)
            descendant = chain + (child,)
            if Path(child.executable).name == "swiftpm-testing":
                matches.append(descendant)
            else:
                pending.append(descendant)
    if len(matches) != 1:
        raise RuntimeError("expected exactly one owned swiftpm-testing process")
    revalidate(matches[0], processes)
    return matches[0]


class Progress:
    def __init__(self):
        self.partial = b""
        self.tail = b""
        self.armed = False
        self.last_event = None

    def feed(self, data, now):
        lines = (self.partial + data).split(b"\n")
        self.partial = lines.pop()[-PROGRESS_LIMIT:]
        for line in lines:
            if EVENT.search(line):
                self.tail = (self.tail + line + b"\n")[-PROGRESS_LIMIT:]
                self.last_event = now
                if MARKER in line:
                    self.armed = True

    def stalled(self, now, seconds=STALL_SECONDS):
        return self.armed and now - self.last_event >= seconds


def sample_file_limit():
    # Applies only to the sampler's files, not Verify or its tests.
    resource.setrlimit(resource.RLIMIT_FSIZE, (SAMPLE_LIMIT, SAMPLE_LIMIT))


def stop_sampler(sampler):
    if sampler is not None and sampler.poll() is None:
        sampler.terminate()
        try:
            sampler.wait(timeout=2)
        except subprocess.TimeoutExpired:
            sampler.kill()
            sampler.wait(timeout=2)


def run_verify(command, evidence, processes, output, sample_popen=subprocess.Popen,
               stall_seconds=STALL_SECONDS, gap_seconds=SAMPLE_GAP_SECONDS,
               sampler_timeout=SAMPLER_TIMEOUT_SECONDS):
    progress = Progress()
    receipt = {"outcome": "watching", "samples": [], "sample_file_limit_bytes": SAMPLE_LIMIT,
               "progress_limit_bytes": PROGRESS_LIMIT, "sample_gap_seconds": gap_seconds,
               "sampler_timeout_seconds": sampler_timeout}
    sampler = None
    attempted = False
    chain = None
    due = None
    exited_at = None
    selector = selectors.DefaultSelector()

    def save():
        try:
            (evidence / "progress-tail.log").write_bytes(progress.tail)
            (evidence / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        except OSError:
            # A diagnostic disk/permission failure must not fail or restart Verify.
            pass

    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    receipt["verify_pid"] = child.pid
    selector.register(child.stdout, selectors.EVENT_READ)
    save()
    try:
        while selector.get_map() or child.poll() is None:
            for key, _ in selector.select(timeout=0.1):
                data = os.read(key.fd, 8192)
                if not data:
                    selector.unregister(key.fileobj)
                    continue
                output.write(data)
                output.flush()
                progress.feed(data, time.monotonic())
                save()
            now = time.monotonic()
            # Sampling never determines Verify's exit code or terminates its process.
            if child.poll() is not None:
                if exited_at is None:
                    exited_at = now
                stop_sampler(sampler)
                if sampler is not None:
                    receipt["samples"][-1].update(exit_status=sampler.returncode, stopped_on_verify_exit=True)
                    sample_log.close()
                    sampler = None
                    receipt["outcome"] = "verify-exited-during-sample"
                    save()
                # An orphan retaining stdout must not extend the original gate.
                if now - exited_at >= 1:
                    break
                continue
            try:
                if not attempted and progress.stalled(now, stall_seconds):
                    attempted = True
                    receipt["stall_seconds"] = round(now - progress.last_event, 3)
                    # This still-owned, unreaped child reserves its PID. Snapshot
                    # after launcher execs have settled, then pin the whole chain.
                    root = processes.identity(child.pid, os.getpid())
                    chain = find_test(root, processes)
                    receipt["test_ancestry"] = [asdict(item) for item in chain]
                    due = now
                if sampler is not None:
                    code = sampler.poll()
                    if code is None and now - sample_started >= sampler_timeout:
                        stop_sampler(sampler)
                        code = sampler.returncode
                        receipt["samples"][-1]["timed_out"] = True
                    if code is not None:
                        receipt["samples"][-1]["exit_status"] = code
                        report = evidence / f"sample-{len(receipt['samples'])}.txt"
                        receipt["samples"][-1]["report_at_file_limit"] = (
                            report.exists() and report.stat().st_size >= SAMPLE_LIMIT
                        )
                        sampler = None
                        sample_log.close()
                        due = now + gap_seconds if len(receipt["samples"]) == 1 else None
                        receipt["outcome"] = "pair-finished" if due is None else "between-samples"
                        save()
                if due is not None and now >= due:
                    revalidate(chain, processes)
                    number = len(receipt["samples"]) + 1
                    report = evidence / f"sample-{number}.txt"
                    sample_log = (evidence / f"sample-{number}-command.log").open("wb")
                    try:
                        sampler = sample_popen(
                            ["/usr/bin/sample", str(chain[-1].pid), str(SAMPLE_SECONDS), "10",
                             "-mayDie", "-file", str(report)], stdout=sample_log,
                            stderr=subprocess.STDOUT, preexec_fn=sample_file_limit,
                        )
                    except Exception:
                        sample_log.close()
                        raise
                    sample_started = time.monotonic()
                    receipt["samples"].append({"pid": chain[-1].pid, "duration_seconds": SAMPLE_SECONDS})
                    receipt["outcome"] = "sampling"
                    due = None
                    save()
            except Exception as error:
                attempted, due = True, None
                receipt["outcome"] = "diagnostic-unavailable"
                # Never serialize exceptions containing commands, environment or secrets.
                receipt["limitation"] = str(error) if isinstance(error, RuntimeError) else type(error).__name__
                save()
        status = child.wait()
        receipt["verify_exit_status"] = status
        receipt["marker_seen"] = progress.armed
        save()
        return status if status >= 0 else 128 - status
    finally:
        stop_sampler(sampler)
        if sampler is not None:
            sample_log.close()
        child.stdout.close()
        selector.close()


def main():
    root = Path(__file__).resolve().parent.parent
    environment = os.environ
    if not (sys.platform == "darwin" and environment.get("CI") == "true"
            and environment.get("GITHUB_ACTIONS") == "true"
            and environment.get("GITHUB_REPOSITORY") == "gl11tchy-team/sigil"
            and environment.get("GITHUB_EVENT_NAME") == "pull_request"
            and environment.get("GITHUB_REF") == "refs/pull/145/merge"
            and environment.get("SIGIL_SWIFT_DIAGNOSTICS") == "1"
            and Path(environment.get("GITHUB_WORKSPACE", "")).resolve() == root
            and Path.cwd().resolve() == root):
        raise SystemExit("This diagnostic is restricted to PR145's macOS CI verification.")
    run, attempt = environment.get("GITHUB_RUN_ID", ""), environment.get("GITHUB_RUN_ATTEMPT", "")
    temporary = Path(environment.get("RUNNER_TEMP", ""))
    if not (run.isdigit() and attempt.isdigit() and temporary.is_absolute() and temporary.is_dir()):
        raise SystemExit("Expected CI run identity and an existing runner temporary directory.")
    command = [str(root / "Scripts/verify.sh")]
    try:
        evidence = temporary / f"sigil-swift-diagnostics-{run}-{attempt}"
        evidence.mkdir(mode=0o700)
        processes = OwnedProcesses()
    except Exception as error:
        print(f"::warning::Swift diagnostic setup unavailable ({type(error).__name__}); running Verify.", flush=True)
        status = subprocess.call(command)
        return status if status >= 0 else 128 - status
    return run_verify(command, evidence, processes, sys.stdout.buffer)


if __name__ == "__main__":
    raise SystemExit(main())
