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

SOURCE = "c607818beaf26c5e267932abee6e381786c2e1bf"
BASELINE = "7cb09b9720c4c0ccea6e86b7b5c089dafbaababd"
SOURCES = {"baseline": BASELINE, "candidate": SOURCE}
TREES = {BASELINE: "0f4cbdc85da40761e8a32906a1472c8d215e44e8",
         SOURCE: "2e9206d43dcef10831d90d038e9ed1b886deb622"}
REPAIR_SHA256 = "279bbf2ac07c4e63bc98cfc7df07d67ab58fc9aeac60d60b17bbd228a61029a1"
BRANCH = "refs/heads/diagnostic/rea-1194-prefix-candidate-20261027"
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
OVERLAY = {path for path in ADDED if path.startswith("Sidereal/")}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def refuse_bypasses(environment):
    require(all(name not in environment for name in ("SIDEREAL_PERF_BASELINE", "SIDEREAL_TEST_ORIGIN")),
            "Bypass/external-origin environment refused, including empty values")


def node_report(text):
    counts = {}
    for name in ("tests", "pass", "fail", "cancelled", "skipped", "todo"):
        values = re.findall(r"^# " + name + r" ([0-9]+)\s*$", text, re.MULTILINE)
        require(len(values) == 1, "Missing/ambiguous focused Node count: " + name)
        counts[name] = int(values[0])
    require(counts["tests"] > 0, "Zero focused Node tests")
    for title in ("REA-1194 exact prefixes handle long middle edits, truncation and prepend",
                  "REA-1194 prefix boundaries match an independent scalar UTF16 oracle"):
        require(len(re.findall(r"^# Subtest: " + re.escape(title) + r"\r?$", text, re.MULTILINE)) == 1,
                "Missing/duplicate candidate regression: " + title)
    passed = counts["pass"] == counts["tests"] and all(
        counts[name] == 0 for name in ("fail", "cancelled", "skipped", "todo"))
    return {"counts": counts, "passed": passed}


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


def validate(report, phase, head, source_file, source=SOURCE):
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
        require(identity.get("source") == source and identity.get("diagnostic") == head,
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


def child_environment(runtime, phase, root, head, source=SOURCE):
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
           "SIGIL_RENDER_SOURCE_SHA": source, "SIGIL_RENDER_DIAGNOSTIC_SHA": head}
    Path(env["TMPDIR"]).mkdir()
    for name in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "KIMI_CLI_HOME"):
        path = home / name.lower()
        path.mkdir()
        env[name] = str(path)
    (home / "npmrc").write_text("")
    (home / "global-npmrc").write_text("")
    return env  # No inherited tokens, debug switches, test origin or baseline bypass.


def source_identity(directory, source, overlay):
    git = lambda *args: subprocess.check_output(["git", *args], cwd=directory, text=True, timeout=15).strip()
    require(git("rev-parse", "HEAD") == source and git("rev-parse", "HEAD^{tree}") == TREES[source],
            "Wrong staged source/tree")
    require(not git("diff", "HEAD", "--"), "Tracked staged source changed")
    expected = {"?? " + path for path in OVERLAY}
    require(set(git("status", "--porcelain", "--untracked-files=all").splitlines()) == expected,
            "Unexpected staged source additions")
    require(set(overlay) == OVERLAY, "Wrong harness overlay inventory")
    for name, digest in overlay.items():
        path = directory / name
        require(path.is_file() and not path.is_symlink()
                and hashlib.sha256(path.read_bytes()).hexdigest() == digest, "Staged harness changed: " + name)


def stage_source(repo, runtime, evidence, setup, label):
    source = SOURCES[label]
    directory = runtime / ("source-" + label)
    require(command(["git", "worktree", "add", "--detach", str(directory), source], repo, setup,
                    evidence / (label + "-checkout.log"), 60) == 0, "Source checkout failed: " + label)
    overlay = {}
    for name in sorted(OVERLAY):
        original, target = repo / name, directory / name
        require(original.is_file() and not original.is_symlink() and not target.exists(), "Unsafe harness overlay")
        target.parent.mkdir(parents=True, exist_ok=True)
        require(target.parent.resolve() == target.parent, "Symlink in overlay parent")
        target.write_bytes(original.read_bytes())
        overlay[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    source_identity(directory, source, overlay)
    return directory, {"source": source, "tree": TREES[source], "directory": str(directory), "overlay": overlay}


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
    result = {"schema": 2, "source": SOURCE, "baseline": BASELINE, "run": run, "attempt": attempt,
              "mergeAcceptance": False, "sources": {}, "complete": False,
              "comparisonOrder": list(SOURCES),
              "profiling": {"executed": False, "reason": "Paired clean comparison only; existing attribution retained"}}
    repo = Path(__file__).resolve().parent.parent
    git = lambda *args: subprocess.check_output(["git", *args], cwd=repo, text=True, timeout=15).strip()
    try:
        require(os.environ.get("GITHUB_REPOSITORY") == "gl11tchy/sigil"
                and os.environ.get("GITHUB_EVENT_NAME") == "push"
                and os.environ.get("GITHUB_REF") == BRANCH, "Wrong repository/event/ref")
        refuse_bypasses(os.environ)
        require(os.environ.get("ImageVersion") == "20261021.0445.8"
                and os.environ.get("RUNNER_OS") == "macOS"
                and os.environ.get("RUNNER_ARCH") == "ARM64", "Wrong observed image")
        head = git("rev-parse", "HEAD")
        require(head == os.environ["SIGIL_EXPECTED_SHA"] == os.environ["GITHUB_SHA"], "Wrong checkout SHA")
        require(not git("status", "--porcelain", "--untracked-files=all"), "Dirty diagnostic source")
        subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head], cwd=repo, check=True, timeout=15)
        for line in git("diff", "--name-status", "--no-renames", SOURCE, head).splitlines():
            require(line.startswith("A\t") and line[2:] in ADDED, "Existing source changed: " + line)
        require(git("rev-parse", SOURCE + "^") == BASELINE, "Candidate is not the pinned baseline child")
        repair = subprocess.check_output(["git", "diff", BASELINE, SOURCE], cwd=repo, timeout=15)
        require(hashlib.sha256(repair).hexdigest() == REPAIR_SHA256, "Candidate repair differs from reviewed patch")
        result.update(head=head, tree=git("rev-parse", "HEAD^{tree}"),
                      sourceTree=git("rev-parse", SOURCE + "^{tree}"),
                      image=os.environ["ImageVersion"], node="v22.23.3",
                      xcode="26.6/17F113", browser=BROWSER)
        setup = child_environment(runtime, "setup", evidence, head)
        require(subprocess.check_output(["node", "--version"], env=setup, text=True).strip() == "v22.23.3",
                "Wrong actual Node")
        require(command([sys.executable, "Scripts/tests/test_hosted_render_diagnostic.py"], repo, setup,
                        evidence / "parser.log", 30) == 0, "Parser checks failed")
        directories, environments = {}, {}
        for label, source in SOURCES.items():
            directory, identity = stage_source(repo, runtime, evidence, setup, label)
            directories[label] = directory
            result["sources"][label] = identity
            env = child_environment(runtime, "setup-" + label, evidence, head, source)
            environments[label] = env
            require(command(["npm", "ci", "--ignore-scripts"], directory / "Sidereal", env,
                            evidence / (label + "-npm-ci.log"), 120) == 0, "npm-ci failed: " + label)
            for package in ("@playwright/test", "playwright", "playwright-core"):
                package_file = directory / "Sidereal/node_modules" / package / "package.json"
                require(json.loads(package_file.read_text())["version"] == "1.63.0", "Wrong Playwright")
            source_identity(directory, source, identity["overlay"])
        candidate = directories["candidate"]
        shared = (candidate / "Sidereal/public/output.mjs").read_bytes()
        require(shared == (candidate / "iOS/Sigil/Resources/readable-output.js").read_bytes(), "iOS mirror differs")
        result["iosMirror"] = {"matched": True, "sha256": hashlib.sha256(shared).hexdigest()}
        node_files = ["test/output.test.mjs", "test/app.test.mjs", "test/web-search-poll.test.mjs"]
        node_log = evidence / "focused-node.log"
        code = command(["node", "--test", "--test-concurrency=1", "--test-reporter=tap", *node_files],
                       candidate / "Sidereal", environments["candidate"], node_log, 120)
        require(node_log.stat().st_size <= 8 * 1024 * 1024, "Focused Node log exceeded size bound")
        result["focusedNode"] = {**node_report(node_log.read_text()), "exit": code,
                                 "files": node_files, "concurrency": 1}
        require(code == (0 if result["focusedNode"]["passed"] else 1), "Focused Node exit/report mismatch")
        require(result["focusedNode"]["passed"], "Focused Node correctness checks failed")
        source_identity(candidate, SOURCE, result["sources"]["candidate"]["overlay"])
        require(command(["node", "node_modules/playwright/cli.js", "install", "chromium"],
                        candidate / "Sidereal", environments["candidate"], evidence / "browser-install.log", 180) == 0,
                "browser-install failed")
        source_identity(candidate, SOURCE, result["sources"]["candidate"]["overlay"])
        # Fixed baseline then candidate: three clean cases each, regardless of gate failures.
        for label, source in SOURCES.items():
            staged = directories[label]
            directory = evidence / label
            directory.mkdir()
            source_identity(staged, source, result["sources"][label]["overlay"])
            env = child_environment(runtime, "clean-" + label, directory, head, source)
            env["SIGIL_RENDER_PHASE"] = "clean"
            args = ["node", "node_modules/playwright/cli.js", "test",
                    "test/diagnostics/hosted-render.spec.mjs", "--config=hosted-render-diagnostic.config.mjs",
                    "--project=chromium", "--grep=" + TITLE + "$", "--workers=1",
                    "--repeat-each=3", "--retries=0"]
            code = command(args, staged / "Sidereal", env, directory / "raw.log", 450)
            result["sources"][label]["clean"] = {"valid": False, "exit": code,
                                                  "rawReport": label + "/cases.json"}
            # Source/harness drift stops the pair, retaining the raw outcome.
            source_identity(staged, source, result["sources"][label]["overlay"])
            try:
                report_path = directory / "cases.json"
                require(report_path.is_file() and report_path.stat().st_size < 1024 * 1024, "Missing/oversized report")
                checked = validate(json.loads(report_path.read_text()), "clean", head,
                                   staged / "Sidereal/test/browser/web-find.spec.mjs", source)
                require(code == (0 if checked["passed"] else 1), "Exit/report mismatch")
                result["sources"][label]["clean"] = {**checked, "exit": code}
            except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
                result["sources"][label]["clean"] = {"valid": False, "exit": code, "error": str(error),
                                                      "rawReport": label + "/cases.json"}
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
    return 0 if result["complete"] and all(result["sources"][label]["clean"].get("passed")
                                         for label in SOURCES) else 1


if __name__ == "__main__":
    sys.exit(main())
