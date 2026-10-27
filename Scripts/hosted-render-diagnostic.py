#!/usr/bin/env python3
"""One fixed hosted diagnostic; never full-CI or merge acceptance."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys

SOURCE = "7cb09b9720c4c0ccea6e86b7b5c089dafbaababd"
BRANCH = "refs/heads/diagnostic/rea-1194-hosted-render-20261027"
TITLE = "REA-1194 measures changed 400KB polls directly at 4x Chromium CPU"
BROWSER = "153.0.8010.12"
ADDED = {
    ".github/workflows/hosted-render-diagnostic.yml",
    "Scripts/hosted-render-diagnostic.py",
    "Scripts/tests/test_hosted_render_diagnostic.py",
    "Sidereal/hosted-render-diagnostic.config.mjs",
    "Sidereal/test/diagnostics/hosted-render.spec.mjs",
    "Sidereal/test/diagnostics/render-reporter.mjs",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def refuse_bypasses(environment):
    require(all(name not in environment for name in ("SIDEREAL_PERF_BASELINE", "SIDEREAL_TEST_ORIGIN")),
            "Bypass/external-origin environment refused, including empty values")


def metrics(value):
    require(isinstance(value, dict), "Missing timing attachment")
    for key, expected in {"cpuRate": 4, "warmups": 5, "count": 20,
                          "rawCharacters": 404620, "formattedCharacters": 381981}.items():
        require(type(value.get(key)) is int and value[key] == expected, "Wrong workload: " + key)
    samples = value.get("samples")
    require(isinstance(samples, list) and len(samples) == 20, "Wrong sample count")
    require(all(type(x) in (int, float) and math.isfinite(x) and 0 < x < 120000
                for x in samples), "Invalid timing sample")
    ordered = sorted(samples)
    for key, expected in {"median": statistics.median(samples), "p95": ordered[18],
                          "maximum": ordered[-1]}.items():
        actual = value.get(key)
        require(type(actual) in (int, float) and math.isfinite(actual)
                and abs(actual - expected) < 0.000001, "Incorrect statistic: " + key)
    return ordered[18] <= 25  # No tolerance or waiver on the actual gate.


def validate(report, phase, head, source_file):
    count = 3 if phase == "clean" else 1
    require(report.get("schema") == 1 and report.get("phase") == phase, "Wrong report identity")
    require(report.get("discovered") == count and not report.get("errors"), "Collection/global error")
    records = report.get("records", [])
    require(len(records) == count, "Zero, missing or extra cases")
    require(sorted(x.get("repeat", -1) for x in records) == list(range(count)), "Wrong repeats")
    passed = True
    for record in records:
        require(record.get("title") == TITLE and record.get("project") == "chromium", "Wrong case")
        require(record.get("location") == {"file": str(source_file), "line": 21, "column": 1},
                "Wrong original test location")
        require(record.get("retry") == 0 and record.get("expected") == "passed", "Retry/expected failure")
        require(record.get("status") in ("passed", "failed"), "Skipped, timed-out or interrupted case")
        attachments = record.get("attachments", {})
        identity = attachments.get("hosted-render-identity", {})
        require(identity.get("source") == SOURCE and identity.get("diagnostic") == head,
                "Wrong source identity")
        require(identity.get("browser") == BROWSER and identity.get("node") == "v22.23.3",
                "Wrong browser/Node")
        require(identity.get("phase") == phase and identity.get("profiled") is (phase == "profile")
                and identity.get("acceptanceEligible") is (phase == "clean"), "Mixed phase identity")
        require(identity.get("protocol", {}).get("product", "").endswith("/" + BROWSER),
                "Wrong observed browser product")
        gate = metrics(attachments.get("400KB-direct-render-durations"))
        require(record["status"] != "passed" or gate, "Threshold was bypassed")
        passed &= record["status"] == "passed" and gate
    require(report.get("status") == ("passed" if all(x["status"] == "passed" for x in records)
                                   else "failed"), "Wrong overall status")
    return {"valid": True, "passed": passed, "cleanTimingEvidence": phase == "clean" and passed,
            "records": records}


def command(args, cwd, env, log, timeout):
    with log.open("xb") as output:
        process = subprocess.Popen(args, cwd=cwd, env=env, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)  # Only this owned CI child group.
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            output.write(b"\nDiagnostic command timed out; no retry.\n")
            return 124


def profile_evidence(record, directory):
    entries = record.get("artifacts", [])
    require(sorted(x.get("name", "") for x in entries)
            == ["render-cpu-profile", "render-layout-gc-trace"], "Missing/duplicate profile artifacts")
    retained = []
    for entry in entries:
        path = Path(entry["path"])
        require(path.is_file() and not path.is_symlink()
                and path.resolve().is_relative_to(directory / "test-results"), "Profile outside generated results")
        maximum = 16 if entry["name"] == "render-cpu-profile" else 64
        require(0 < path.stat().st_size <= maximum * 1024 * 1024, "Profile size limit")
        content = json.loads(path.read_text())
        if entry["name"] == "render-cpu-profile":
            require(content.get("nodes") and content.get("samples")
                    and len(content["samples"]) == len(content.get("timeDeltas", [])), "Invalid CPU profile")
            observed = {"cpuSamples": len(content["samples"])}
        else:
            events = content.get("traceEvents")
            require(isinstance(events, list) and events, "Empty/invalid timeline")
            observed = {name: sum(x.get("name") == name for x in events)
                        for name in ("Layout", "UpdateLayoutTree", "MinorGC", "MajorGC")}
        retained.append({"name": entry["name"], "path": str(path.relative_to(directory)),
                         "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                         "observed": observed})
    return retained


def child_environment(runtime, phase, root, head):
    home = runtime / phase
    home.mkdir()
    fake = home / "bin"
    fake.mkdir()
    for name in ("codex", "claude", "grok", "kimi", "cursor-agent", "devin"):
        path = fake / name
        path.write_text("#!/bin/sh\necho 'Provider execution forbidden in synthetic fixture' >&2\nexit 91\n")
        path.chmod(0o700)
    env = {"PATH": str(fake) + os.pathsep + os.environ["PATH"], "HOME": str(home),
           "TMPDIR": str(home / "tmp"), "CI": "true", "TZ": "UTC", "LANG": "en_US.UTF-8",
           "PYTHONDONTWRITEBYTECODE": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "PLAYWRIGHT_BROWSERS_PATH": str(runtime / "browsers"),
           "npm_config_cache": str(runtime / "npm-cache"),
           "NPM_CONFIG_USERCONFIG": str(home / "npmrc"), "NPM_CONFIG_GLOBALCONFIG": str(home / "global-npmrc"),
           "SIGIL_RENDER_PHASE": phase, "SIGIL_RENDER_PHASE_DIR": str(root),
           "SIGIL_RENDER_SOURCE_SHA": SOURCE, "SIGIL_RENDER_DIAGNOSTIC_SHA": head}
    Path(env["TMPDIR"]).mkdir()
    for name in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "KIMI_CLI_HOME"):
        path = home / name.lower()
        path.mkdir()
        env[name] = str(path)
    (home / "npmrc").write_text("")
    (home / "global-npmrc").write_text("")
    return env  # No inherited tokens, debug switches, test origin or baseline bypass.


def main():
    require(os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("SIGIL_RUNNER_ENVIRONMENT") == "github-hosted", "Hosted CI only")
    temporary = Path(os.environ["RUNNER_TEMP"])
    require(temporary.resolve() == temporary and temporary.is_dir(), "Noncanonical runner temp")
    run, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    require(re.fullmatch(r"[1-9][0-9]*", run) and re.fullmatch(r"[1-9][0-9]*", attempt), "Bad run identity")
    root = temporary / ("sigil-render-" + run + "-" + attempt)
    require(os.environ["SIGIL_RENDER_ARTIFACTS"] == str(root), "Wrong artifact path")
    root.mkdir()  # Never reuse or remove evidence from an earlier attempt.
    evidence, runtime = root / "evidence", root / "runtime"
    evidence.mkdir()
    runtime.mkdir()
    result = {"schema": 1, "source": SOURCE, "run": run, "attempt": attempt,
              "mergeAcceptance": False, "phases": {}, "complete": False}
    repo = Path(__file__).resolve().parent.parent
    git = lambda *args: subprocess.check_output(["git", *args], cwd=repo, text=True, timeout=15).strip()
    try:
        require(os.environ.get("GITHUB_REPOSITORY") == "gl11tchy/sigil"
                and os.environ.get("GITHUB_EVENT_NAME") == "push"
                and os.environ.get("GITHUB_REF") == BRANCH, "Wrong repository/event/ref")
        refuse_bypasses(os.environ)
        require(os.environ.get("ImageVersion") == "20261013.0424.1"
                and os.environ.get("RUNNER_OS") == "macOS"
                and os.environ.get("RUNNER_ARCH") == "ARM64", "Wrong observed image")
        head = git("rev-parse", "HEAD")
        require(head == os.environ["SIGIL_EXPECTED_SHA"] == os.environ["GITHUB_SHA"], "Wrong checkout SHA")
        require(not git("status", "--porcelain", "--untracked-files=all"), "Dirty diagnostic source")
        subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head], cwd=repo, check=True, timeout=15)
        for line in git("diff", "--name-status", "--no-renames", SOURCE, head).splitlines():
            require(line.startswith("A\t") and line[2:] in ADDED, "Existing source changed: " + line)
        result.update(head=head, tree=git("rev-parse", "HEAD^{tree}"),
                      sourceTree=git("rev-parse", SOURCE + "^{tree}"),
                      image=os.environ["ImageVersion"], node="v22.23.3",
                      xcode="26.6/17F113", browser=BROWSER)
        setup = child_environment(runtime, "setup", evidence, head)
        require(subprocess.check_output(["node", "--version"], env=setup, text=True).strip() == "v22.23.3",
                "Wrong actual Node")
        steps = [
            ([sys.executable, "Scripts/tests/test_hosted_render_diagnostic.py"], repo, "parser", 30),
            (["npm", "ci", "--ignore-scripts"], repo / "Sidereal", "npm-ci", 120),
            (["node", "node_modules/playwright/cli.js", "install", "chromium"],
             repo / "Sidereal", "browser-install", 180),
        ]
        for args, cwd, label, timeout in steps:
            require(command(args, cwd, setup, evidence / (label + ".log"), timeout) == 0, label + " failed")
        for package in ("@playwright/test", "playwright", "playwright-core"):
            package_file = repo / "Sidereal/node_modules" / package / "package.json"
            require(json.loads(package_file.read_text())["version"] == "1.63.0", "Wrong Playwright")
        # Thirty seconds beyond Playwright's global bound permits report teardown.
        for phase, repeats, timeout in (("clean", 3, 450), ("profile", 1, 210)):
            directory = evidence / phase
            directory.mkdir()
            env = child_environment(runtime, phase, directory, head)
            args = ["node", "node_modules/playwright/cli.js", "test",
                    "test/diagnostics/hosted-render.spec.mjs", "--config=hosted-render-diagnostic.config.mjs",
                    "--project=chromium", "--grep=" + TITLE + "$", "--workers=1",
                    "--repeat-each=" + str(repeats), "--retries=0"]
            code = command(args, repo / "Sidereal", env, directory / "raw.log", timeout)
            try:
                report_path = directory / "cases.json"
                require(report_path.is_file() and report_path.stat().st_size < 1024 * 1024, "Missing/oversized report")
                checked = validate(json.loads(report_path.read_text()), phase, head,
                                   repo / "Sidereal/test/browser/web-find.spec.mjs")
                if phase == "profile":
                    checked["profileArtifacts"] = profile_evidence(checked["records"][0], directory)
                require(code == (0 if checked["passed"] else 1), "Exit/report mismatch")
                result["phases"][phase] = {**checked, "exit": code}
            except (ValueError, OSError, KeyError, TypeError) as error:
                result["phases"][phase] = {"valid": False, "exit": code, "error": str(error),
                                          "rawReport": phase + "/cases.json"}
        result["complete"] = True
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        result["error"] = str(error)
    (evidence / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    manifest = []
    for path in sorted(evidence.rglob("*")):
        require(not path.is_symlink(), "Symlink in generated evidence")
        if path.is_file():
            manifest.append({"path": str(path.relative_to(evidence)), "bytes": path.stat().st_size,
                             "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    (evidence / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({key: result.get(key) for key in ("source", "head", "complete", "error")}))
    return 0 if result["complete"] and all(result["phases"][phase].get("passed")
                                         for phase in ("clean", "profile")) else 1


if __name__ == "__main__":
    sys.exit(main())
