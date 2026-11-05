#!/usr/bin/env python3
"""Read bundle and source identity for the single CI release publisher."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import zipfile


VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
BUILD = re.compile(r"[1-9][0-9]*(?:\.[0-9]+){0,2}")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], text=True, stderr=subprocess.DEVNULL
    ).strip()


def sources_dirty(root):
    if git(root, "status", "--porcelain", "--untracked-files=normal"):
        return True
    # SwiftPM compiles ignored source files and edited dependency checkouts.
    # Match install-latest's input boundary; generated .build products stay out.
    ignored = git(root, "status", "--porcelain", "--ignored=matching", "--", "Sources", "Tests", "Resources")
    if any(not line.rstrip('"').endswith("/.DS_Store") for line in ignored.splitlines()):
        return True
    checkout_roots = [root / ".build" / "checkouts", *sorted((root / ".build" / "universal").glob("*/checkouts"))]
    for checkouts in checkout_roots:
        if not checkouts.is_dir():
            continue
        for checkout in checkouts.iterdir():
            if checkout.is_dir() and (checkout / ".git").exists():
                if git(checkout, "status", "--porcelain", "--untracked-files=normal"):
                    return True
    return False


def source_identity(root, env):
    root = Path(root).resolve()
    commit, count = "unknown", "1"
    try:
        if Path(git(root, "rev-parse", "--show-toplevel")).resolve() == root:
            head = git(root, "rev-parse", "--verify", "HEAD")
            if COMMIT.fullmatch(head):
                dirty = sources_dirty(root)
                commit = head + ("-dirty" if dirty else "")
                # A shallow count is not the repository's build count. Local
                # source-only builds use 1; CI supplies its run.attempt identity.
                if git(root, "rev-parse", "--is-shallow-repository") == "false":
                    count = git(root, "rev-list", "--count", "HEAD")
    except (OSError, subprocess.CalledProcessError):
        commit = "unknown"
    version, build = env.get("SIGIL_VERSION") or "1.0.0", env.get("SIGIL_BUILD") or count
    if not VERSION.fullmatch(version):
        raise ValueError("SIGIL_VERSION must contain three numbers, for example 1.0.0")
    if not BUILD.fullmatch(build):
        raise ValueError("SIGIL_BUILD must be a positive number with at most three parts")
    return {"version": version, "build": build, "commit": commit}


def archive_identity(archive):
    archive = Path(archive)
    with zipfile.ZipFile(archive) as zipped:
        key = "Sigil.app/Contents/Info.plist"
        if zipped.namelist().count(key) != 1 or zipped.getinfo(key).file_size > 1024 * 1024:
            raise ValueError("ZIP must contain one bounded Sigil.app Info.plist")
        info = plistlib.loads(zipped.read(key))
    if not isinstance(info, dict):
        raise ValueError("ZIP Info.plist must be a dictionary")
    identity = {
        "version": info.get("CFBundleShortVersionString"),
        "build": info.get("CFBundleVersion"),
        "commit": info.get("SigilCommit"),
    }
    if not isinstance(identity["version"], str) or not VERSION.fullmatch(identity["version"]):
        raise ValueError("ZIP has an invalid version")
    if not isinstance(identity["build"], str) or not BUILD.fullmatch(identity["build"]):
        raise ValueError("ZIP has an invalid build")
    if not isinstance(identity["commit"], str):
        raise ValueError("ZIP is missing SigilCommit")
    identity["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    identity["tag"] = "build-" + identity["build"]
    return identity


def verify_archive(identity, commit, build):
    if not COMMIT.fullmatch(identity["commit"]) or identity["commit"] != commit:
        raise ValueError("dirty, unknown or mismatched source cannot be published as an exact release")
    if identity["build"] != build:
        raise ValueError("ZIP build differs from the CI build identity")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["source", "archive"])
    parser.add_argument("path", type=Path)
    parser.add_argument("--expected-commit")
    parser.add_argument("--expected-build")
    args = parser.parse_args()
    if args.expected_commit or args.expected_build:
        if args.action != "archive" or not (args.expected_commit and args.expected_build):
            parser.error("archive verification requires both --expected-commit and --expected-build")
    try:
        if args.action == "source":
            identity = source_identity(args.path, os.environ)
            print(identity["version"], identity["build"], identity["commit"])
        else:
            identity = archive_identity(args.path)
            if args.expected_commit:
                verify_archive(identity, args.expected_commit, args.expected_build)
            print(json.dumps(identity, sort_keys=True))
    except (ValueError, KeyError, OSError, RuntimeError, zipfile.BadZipFile) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
