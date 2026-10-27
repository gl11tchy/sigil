"""CI-only single-case ledger observation; never substitutes for normal verification."""

import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CASE = "simultaneousIndependentInstancesKeepEveryTask()"
SUITE = "TaskLedgerStoreTests"
FILTER = r"^SigilKitTests\.TaskLedgerStoreTests/simultaneousIndependentInstancesKeepEveryTask(\(\))?$"
REF = "refs/heads/diagnostic/rea-1176-lock-bootstrap-20261027"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def validate(text, status):
    text = ANSI.sub("", text)
    if status != 0 or re.search(
        r"recorded an issue|✘|\b(skipped|cancelled|canceled|timed out)\b|SIGIL_LEDGER_LOCK_DIAGNOSTIC", text, re.I
    ):
        raise ValueError("Diagnostic failed, skipped, cancelled, or emitted a lock failure")
    events = (
        (r"^◇ Suite (.+) started\.$", SUITE),
        (r"^◇ Test (?!run\b)(.+) started\.$", CASE),
        (r"^✔ Test (?!run\b)(.+) passed after .+\.$", CASE),
        (r"^✔ Suite (.+) passed after .+\.$", SUITE),
    )
    positions = []
    for pattern, expected in events:
        matches = list(re.finditer(pattern, text, re.M))
        if len(matches) != 1 or matches[0][1] != expected:
            raise ValueError("Expected exactly the selected suite and case, once")
        positions.append(matches[0].start())
    summaries = list(re.finditer(
        r"^✔ Test run with (\d+) tests?(?: in (\d+) suites?)? passed after .+\.$", text, re.M
    ))
    if len(summaries) != 1 or summaries[0][1] != "1" or summaries[0][2] not in (None, "1"):
        raise ValueError("Expected one completed one-test summary")
    positions.append(summaries[0].start())
    if positions != sorted(positions):
        raise ValueError("Incomplete or reordered test events")
    rounds = list(re.finditer(r"^SIGIL_LEDGER_ROUND_COMPLETED (.*)$", text, re.M))
    if ([m[1] for m in rounds] != [str(n) for n in range(8)]
            or not all(positions[1] < m.start() < positions[2] for m in rounds)):
        raise ValueError("All eight rounds must complete once inside the selected test")
    if re.search(r"^.*Test case\b", text, re.M):
        raise ValueError("Unexpected parameterized case")
    if any(int(count) or int(failed) for count, failed in re.findall(
        r"Executed (\d+) tests?, with (\d+) failures", text
    )):
        raise ValueError("Unexpected XCTest execution")
    return {"case": CASE, "passed": 1, "failed": 0, "skipped": 0, "cancelled": 0, "rounds": 8}


def require_context(env):
    expected = env.get("SIGIL_EXPECTED_SOURCE_SHA", "")
    if (env.get("CI") != "true" or env.get("GITHUB_ACTIONS") != "true"
            or env.get("SIGIL_TASK_LEDGER_DIAGNOSTIC") != "true"
            or env.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or env.get("GITHUB_REPOSITORY") != "gl11tchy/sigil" or env.get("GITHUB_REF") != REF
            or not re.fullmatch(r"[0-9a-f]{40}", expected) or env.get("GITHUB_SHA") != expected):
        raise ValueError("Requires the source-pinned private diagnostic dispatch")
    return expected


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def require_source(expected):
    if git("rev-parse", "HEAD") != expected or git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Requires exact clean reviewed source")
    return git("rev-parse", "HEAD^{tree}")


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def commands(scratch):
    common = ["/usr/bin/xcrun", "swift", "--package-path", str(ROOT), "--scratch-path", str(scratch)]
    # Swift subcommands precede their shared options.
    return (common[:2] + ["build"] + common[2:] + ["--build-tests", "--jobs", "2"],
            common[:2] + ["test"] + common[2:] + ["--skip-build", "--no-parallel", "--filter", FILTER])


def run(command, environment, timeout, log):
    with log.open("wb") as output:
        child = subprocess.Popen(command, env=environment, stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return {"status": child.wait(timeout=timeout), "timedOut": False}
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=5)
            return {"status": 124, "timedOut": True}


def product(scratch):
    found = [p for p in scratch.rglob("SigilPackageTests") if p.is_file()]
    if len(found) != 1:
        raise ValueError("Expected one fresh SwiftPM test executable")
    path = found[0]
    if (path.parts[-4:] != ("SigilPackageTests.xctest", "Contents", "MacOS", "SigilPackageTests")
            or any(p.is_symlink() for p in (path, *path.parents) if p.is_relative_to(scratch))):
        raise ValueError("Unexpected or symlinked test product")
    return path


def main():
    env = os.environ
    # No fallback destination or write retry if artifact setup itself fails.
    temporary = Path(env["RUNNER_TEMP"])
    run_id, attempt = env["GITHUB_RUN_ID"], env["GITHUB_RUN_ATTEMPT"]
    if not temporary.is_absolute() or not all(re.fullmatch(r"[1-9][0-9]*", x) for x in (run_id, attempt)):
        raise ValueError("Invalid runner artifact identity")
    artifacts = temporary.resolve() / f"sigil-ledger-{run_id}-{attempt}"
    requested = Path(env["SIGIL_LEDGER_ARTIFACTS"])
    if not requested.is_absolute() or requested.resolve() != artifacts or artifacts.is_relative_to(ROOT):
        raise ValueError("Artifacts must be the fresh scoped runner destination")
    artifacts.mkdir(mode=0o700, exist_ok=False)
    receipt = {"runID": run_id, "attempt": attempt, "stage": "preflight", "outcome": "unknown",
               "scope": "One two-writer test; not full-suite root-cause or release-readiness proof"}

    def save():
        (artifacts / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")

    save()
    try:
        expected = require_context(env)
        if sys.platform != "darwin":
            raise ValueError("Requires the approved macOS CI VM")
        receipt.update(sourceSHA=expected, sourceTree=require_source(expected), selector=FILTER)
        work, home = artifacts / "work", artifacts / "work/home"
        for name in ("tmp", "bin", ".grok", ".codex", ".claude", "cache", "config"):
            (home / name).mkdir(parents=True, mode=0o700)
        for name in ("zsh", "grok", "codex", "claude"):
            fake = home / "bin" / name
            fake.write_text("#!/bin/sh\nexit 99\n")
            fake.chmod(0o700)
        isolated = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": str(home / "tmp") + "/",
                    "GROK_HOME": str(home / ".grok"), "CODEX_HOME": str(home / ".codex"),
                    "CLAUDE_CONFIG_DIR": str(home / ".claude"), "SHELL": str(home / "bin/zsh"),
                    "XDG_CACHE_HOME": str(home / "cache"), "XDG_CONFIG_HOME": str(home / "config"),
                    "PATH": f'{home / "bin"}:/usr/bin:/bin:/usr/sbin:/sbin', "LANG": "en_US.UTF-8",
                    "CLANG_MODULE_CACHE_PATH": str(work / "clang-cache"),
                    "SWIFTPM_MODULECACHE_OVERRIDE": str(work / "swift-cache")}
        if env.get("DEVELOPER_DIR"):
            isolated["DEVELOPER_DIR"] = env["DEVELOPER_DIR"]
        scratch = work / "build"
        build, test = commands(scratch)
        receipt["phases"] = []
        mocked = [sys.executable, "-B", "-m", "unittest", "discover", "-s", str(ROOT / "Scripts/tests"),
                  "-p", "test_task_ledger_diagnostic.py", "-v"]
        for phase, command, timeout in (("mocked", mocked, 60), ("build", build, 900), ("test", test, 90)):
            receipt["stage"] = phase
            save()
            result = run(command, isolated, timeout, artifacts / f"{phase}.log")
            receipt["phases"].append({"phase": phase, "command": command, **result})
            save()
            require_source(expected)
            if result["timedOut"]:
                raise ValueError("Owned diagnostic command timed out")
            if phase == "mocked":
                if result["status"] != 0:
                    raise ValueError("Mocked validator checks failed; native build was not started")
                continue
            if phase == "build":
                if result["status"] != 0:
                    raise ValueError("Build failed or timed out; test was not started")
                binary = product(scratch)
                receipt["product"] = {"path": str(binary.relative_to(scratch)), "sha256": digest(binary)}
            else:
                if digest(binary) != receipt["product"]["sha256"]:
                    raise ValueError("Test product changed during execution")
                log = artifacts / "test.log"
                if log.stat().st_size > 8 * 1024 * 1024:
                    raise ValueError("Test output exceeds bounded parser input")
                receipt["counts"] = validate(log.read_text(errors="strict"), result["status"])
        receipt["outcome"] = "passed-focused-only"
    except (ValueError, subprocess.SubprocessError) as error:
        receipt.update(outcome="failed-or-unverified", reason=str(error))
        save()
        return 1
    save()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
