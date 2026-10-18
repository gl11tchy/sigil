"""Export PR183's existing CI debug smoke bundle for isolated review, never install it."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys


def command(*args):
    return subprocess.check_output(args, text=True, timeout=60).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if os.environ.get("CI") != "true" or os.environ.get("GITHUB_REF") != "refs/pull/183/merge":
        raise SystemExit("This export is restricted to PR183 CI; it never builds or launches an app.")
    source, output = (Path(value).resolve() for value in sys.argv[1:])
    if output.exists() or not output.is_relative_to(Path(os.environ["RUNNER_TEMP"]).resolve()):
        raise SystemExit("Expected a fresh output directory under RUNNER_TEMP.")
    if source.name != "Sigil.app" or not (source / "Contents/MacOS/Sigil").is_file():
        raise SystemExit("Expected the existing verified DEBUG smoke bundle.")
    head = os.environ["SIGIL_SEARCH_PR_HEAD"]
    checkout = command("git", "rev-parse", "HEAD")
    parents = command("git", "show", "-s", "--format=%P", "HEAD").split()
    if head not in parents:
        raise SystemExit("The PR head must be a parent of the checked merge commit.")
    output.mkdir()
    app = output / "SigilREA1258.app"
    shutil.copytree(source, app, symlinks=True)
    executable = app / "Contents/MacOS/SigilREA1258"
    (app / "Contents/MacOS/Sigil").rename(executable)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info.update({
        "CFBundleName": "SigilREA1258", "CFBundleDisplayName": "Sigil REA-1258 Workbench",
        "CFBundleExecutable": "SigilREA1258", "CFBundleIdentifier": "com.gl11tchy.sigil.workbench.rea1258",
    })
    info_path.write_bytes(plistlib.dumps(info))
    command("codesign", "--force", "--deep", "--sign", "-", str(app))
    command("codesign", "--verify", "--deep", "--strict", str(app))
    manifest = []
    for path in sorted(app.rglob("*")):
        entry = {"path": str(path.relative_to(app)), "mode": stat.S_IMODE(path.lstat().st_mode)}
        if path.is_symlink():
            entry["symlink"] = os.readlink(path)
        elif path.is_file():
            entry["sha256"] = digest(path)
        else:
            continue
        manifest.append(entry)
    archive = output / "SigilREA1258.zip"
    command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    provenance = {
        "purpose": "Private isolated DEBUG review artifact; not installed or runtime-accepted",
        "repository": os.environ["GITHUB_REPOSITORY"], "runID": os.environ["GITHUB_RUN_ID"],
        "runAttempt": os.environ["GITHUB_RUN_ATTEMPT"], "prHead": head, "checkout": checkout,
        "checkoutParents": parents, "tree": command("git", "rev-parse", "HEAD^{tree}"),
        "configuration": "debug", "bundleID": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
        "architecture": command("lipo", "-archs", str(executable)),
        "archiveSHA256": digest(archive), "executableSHA256": digest(executable),
        "mcpSHA256": digest(app / "Contents/MacOS/sigil-mcp"), "manifest": manifest,
        "runtimeAcceptance": "Pending AX interaction and exact window-ID captures with generated homes only",
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    # Upload only the archive plus provenance, avoiding duplicate bundle contents.
    shutil.move(str(app), str(output.parent / (output.name + "-bundle")))
    print(f"Isolated workbench exported: {archive}; source={checkout}; head={head}")


if __name__ == "__main__":
    main()
