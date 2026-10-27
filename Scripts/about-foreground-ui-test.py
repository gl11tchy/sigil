"""CI-only, exact-source XCTest UI foreground proof. Never exercises About/Close."""

import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import tempfile
import uuid

from about_host_products import checked_product_path

ROOT = Path(__file__).resolve().parent.parent
EXPECTED = "AboutForegroundUITests/testIsolatedFixtureLaunchIsForeground()"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(summary, tree, status):
    def cases(nodes):
        for node in nodes:
            if node.get("nodeType") == "Test Case":
                yield node
            yield from cases(node.get("children", []))

    nodes = list(cases(tree.get("testNodes", [])))
    if (status != 0 or len(nodes) != 1 or nodes[0].get("nodeIdentifier") != EXPECTED
            or nodes[0].get("result") != "Passed"
            or tuple(summary.get(key) for key in ("passedTests", "failedTests", "skippedTests")) != (1, 0, 0)):
        raise ValueError("Expected exactly one foreground UI test pass, without retries or skips")


def require_source(expected):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()

    if git("rev-parse", "HEAD") != expected or git("status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Requires the exact clean reviewed source")
    return git("rev-parse", "HEAD^{tree}")


def run(command, environment, timeout, log):
    with log.open("wb") as output:
        process = subprocess.Popen(command, env=environment, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise ValueError(f"Owned diagnostic command exceeded {timeout}s; see {log.name}")
    if status:
        print(log.read_text(errors="replace")[-16000:])
    return status


def main():
    expected = os.environ.get("SIGIL_EXPECTED_SOURCE_SHA", "")
    if (os.environ.get("CI") != "true" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or not re.fullmatch(r"[0-9a-f]{40}", expected) or os.environ.get("GITHUB_SHA") != expected):
        raise ValueError("Foreground diagnostics require a source-pinned GitHub Actions dispatch")
    source_tree = require_source(expected)
    artifacts = Path(os.environ["SIGIL_SIDEBAR_ARTIFACTS"])
    if not artifacts.is_absolute() or artifacts.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError("Diagnostic artifacts must be outside the checkout")
    artifacts.mkdir(parents=True, exist_ok=False)
    record = {"sourceSHA": expected, "sourceTree": source_tree, "runID": os.environ["GITHUB_RUN_ID"],
              "attempt": os.environ["GITHUB_RUN_ATTEMPT"], "nonce": uuid.uuid4().hex,
              "selector": "SigilAboutUITests/" + EXPECTED.removesuffix("()"),
              "scope": "XCUIApplication foreground launch only; About/Close untested", "stage": "source-verified",
              "fixtureSHA256": digest(ROOT / "Tests/AboutUI/AboutForegroundUITests.swift")}

    def save():
        (artifacts / "foreground-source.json").write_text(json.dumps(record, indent=2) + "\n")

    save()
    try:
        with tempfile.TemporaryDirectory(prefix="sigil-about-xcui-") as temporary:
            work = Path(temporary)
            home, derived = work / "home", work / "DerivedData"
            for name in ("tmp", ".codex", ".claude", ".grok", "cache", "config", "bin"):
                (home / name).mkdir(parents=True, exist_ok=True)
            for name, version in (("grok", "1.0.40"), ("codex", "0.157.1"), ("claude", "2.1.283")):
                executable = home / "bin" / name
                executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{version}"\n')
                executable.chmod(0o700)
            shell = home / "bin/sigil-fixture-shell"
            shell.write_text("#!/bin/sh\nexit 0\n")
            shell.chmod(0o700)
            isolated = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "CODEX_HOME": str(home / ".codex"),
                        "CLAUDE_CONFIG_DIR": str(home / ".claude"), "GROK_HOME": str(home / ".grok"),
                        "XDG_CACHE_HOME": str(home / "cache"), "XDG_CONFIG_HOME": str(home / "config"),
                        "TMPDIR": str(home / "tmp") + "/", "SHELL": str(shell),
                        "PATH": f'{home / "bin"}:/usr/bin:/bin:/usr/sbin:/sbin'}
            environment = {**os.environ, **isolated}
            status = run(["xcodebuild", "-project", str(ROOT / "Tests/SidebarHost/SigilSidebarHost.xcodeproj"),
                          "-scheme", "SigilAboutUI", "-destination", f"platform=macOS,arch={platform.machine()}",
                          "-derivedDataPath", str(derived), "-disableAutomaticPackageResolution", "-jobs", "2",
                          "build-for-testing", "-quiet"], environment, 900, artifacts / "foreground-build.log")
            if status:
                raise ValueError(f"UI fixture build exited {status}; see foreground-build.log")
            products = checked_product_path(derived / "Build/Products", derived)
            test_runs = list(products.glob("*.xctestrun"))
            record.update(stage="products-discovered", productCandidates=sorted(
                str((Path(parent) / name).relative_to(derived))
                for parent, names, _ in os.walk(products, followlinks=False) for name in names
                if name.endswith((".app", ".xctest"))), xctestrunCandidates=[str(p) for p in test_runs])
            save()
            if len(test_runs) != 1:
                raise ValueError(f"Expected one generated UI xctestrun, got {len(test_runs)}")
            test_run = checked_product_path(test_runs[0], derived)
            (artifacts / "foreground.xctestrun").write_bytes(test_run.read_bytes())
            parameters = plistlib.loads(test_run.read_bytes())
            version = parameters["__xctestrun_metadata__"]["FormatVersion"]
            if version == 1:
                targets = [(name, value) for name, value in parameters.items() if name != "__xctestrun_metadata__"]
            elif version == 2:
                targets = [(t["BlueprintName"], t) for c in parameters["TestConfigurations"] for t in c["TestTargets"]]
            else:
                raise ValueError(f"Unsupported xctestrun format {version}")
            if len(targets) != 1 or targets[0][0] != "SigilAboutUITests":
                raise ValueError("Expected only the separate XCTest UI target")
            target = targets[0][1]
            record.update(rawPaths={key: target.get(key) for key in ("TestHostPath", "TestBundlePath", "UITargetAppPath")})
            save()

            def resolve(raw, substitutions):
                if not isinstance(raw, str) or not raw:
                    raise ValueError("Missing UI product path")
                for token, value in substitutions.items():
                    raw = raw.replace(token, str(value))
                if "__" in raw:
                    raise ValueError(f"Unsupported UI product placeholder: {raw}")
                return checked_product_path(Path(raw), derived)

            runner = resolve(target["TestHostPath"], {"__TESTROOT__": test_run.parent})
            bundles = {"SigilAboutUITests-Runner.app": runner,
                       "SigilAboutUITests.xctest": resolve(target["TestBundlePath"],
                           {"__TESTROOT__": test_run.parent, "__TESTHOST__": runner}),
                       "SigilSidebarFixtureHost.app": resolve(target["UITargetAppPath"], {"__TESTROOT__": test_run.parent})}
            record.update(resolvedPaths={name: str(path) for name, path in bundles.items()})
            save()
            identities = {}
            for name, bundle in bundles.items():
                if bundle.name != name or not bundle.is_dir():
                    raise ValueError(f"Unexpected UI product: {bundle}")
                info_path = checked_product_path(bundle / "Contents/Info.plist", derived)
                info = plistlib.loads(info_path.read_bytes())
                executable = info["CFBundleExecutable"]
                if not isinstance(executable, str) or executable in ("", ".", "..") or Path(executable).name != executable:
                    raise ValueError("Invalid UI product executable")
                binary = checked_product_path(bundle / "Contents/MacOS" / executable, derived)
                if not binary.is_file():
                    raise ValueError("UI product executable is not a regular file")
                identities[name] = {"path": str(binary.relative_to(derived)), "sha256": digest(binary)}
                if name == "SigilSidebarFixtureHost.app":
                    if info.get("CFBundleIdentifier") != "com.gl11tchy.sigil.sidebar-fixture-host":
                        raise ValueError("Wrong application identity")
                    (artifacts / "foreground-host-Info.plist").write_bytes(info_path.read_bytes())
            app = bundles["SigilSidebarFixtureHost.app"]
            target.setdefault("EnvironmentVariables", {}).update({**isolated, "CI": "true", "GITHUB_ACTIONS": "true",
                "GITHUB_SHA": expected, "SIGIL_EXPECTED_SOURCE_SHA": expected, "SIGIL_UI_DERIVED_DATA": str(derived),
                "SIGIL_UI_HOST_PATH": str(app), "SIGIL_UI_NONCE": record["nonce"],
                "SIGIL_UI_RESULT_PATH": str(artifacts / "foreground-state.json")})
            test_run.write_bytes(plistlib.dumps(parameters))
            (artifacts / "foreground.xctestrun").write_bytes(test_run.read_bytes())
            record.update(stage="built-source-pinned", products=identities, xctestrunSHA256=digest(test_run))
            save()
            require_source(expected)
            result = artifacts / "foreground.xcresult"
            status = run(["xcodebuild", "-xctestrun", str(test_run), "-destination", f"platform=macOS,arch={platform.machine()}",
                          "-only-testing:" + record["selector"], "-parallel-testing-enabled", "NO",
                          "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
                          "-resultBundlePath", str(result), "test-without-building", "-quiet"],
                         environment, 240, artifacts / "foreground-test.log")
            record.update(stage="test-executed", testExit=status, resultBundle=result.name)
            save()

            def extract(kind):
                path = artifacts / f"foreground-{kind}.json"
                with (artifacts / f"foreground-{kind}.log").open("wb") as errors:
                    try:
                        data = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", kind,
                            "--path", str(result)], env=environment, timeout=30, stderr=errors)
                    except subprocess.CalledProcessError as error:
                        path.write_bytes(error.output or b"")
                        raise
                path.write_bytes(data)
                return json.loads(data)

            record["stage"] = "reading-results"
            save()
            summary, tree = extract("summary"), extract("tests")
            record["testCounts"] = {key: summary.get(key) for key in ("passedTests", "failedTests", "skippedTests")}
            save()
            require_source(expected)
            for product in identities.values():
                if digest(checked_product_path(derived / product["path"], derived)) != product["sha256"]:
                    raise ValueError("A UI diagnostic product changed after execution")
            validate(summary, tree, status)
            receipt = artifacts / "foreground-state.json"
            if receipt.is_symlink() or receipt.stat().st_size > 65536:
                raise ValueError("Invalid foreground state receipt")
            state = json.loads(receipt.read_text())
            if (state.get("sourceSHA") != expected or state.get("nonce") != record["nonce"]
                    or state.get("hostPath") != str(app.resolve()) or state.get("foreground") is not True
                    or state.get("bundleID") != "com.gl11tchy.sigil.sidebar-fixture-host"):
                raise ValueError("Foreground receipt does not match the exact launched fixture")
            record.update(stage="validated-exact-one-foreground-pass", receiptSHA256=digest(receipt))
            save()
            print("One XCTest UI foreground launch passed; About/Close remain untested.")
    except Exception as error:
        record.update(outcome="failed", error=str(error))
        save()
        raise


if __name__ == "__main__":
    main()
