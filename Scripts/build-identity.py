#!/usr/bin/env python3
"""Stamp source identity and publish only a matching, immutable build artifact."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile


VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
BUILD = re.compile(r"[1-9][0-9]*(?:\.[0-9]+){0,2}")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
PRUNABLE = re.compile(r"(?:latest|build-[0-9]+\.[0-9]+)")


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
    checkouts = root / ".build" / "checkouts"
    if checkouts.is_dir():
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


def gh(*args, missing_ok=False):
    result = subprocess.run(["gh", *args], text=True, capture_output=True, check=False)
    if result.returncode:
        # Authentication, permission and server failures must never become
        # permission to create a release. Only an explicit API 404 is absent.
        if missing_ok and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or "GitHub CLI failed")
    return result.stdout


def verify_tag(repo, tag, commit):
    ref = gh("api", f"repos/{repo}/git/ref/tags/{tag}", missing_ok=True)
    if ref is None:
        return False
    obj = json.loads(ref)["object"]
    if obj.get("type") != "commit" or obj.get("sha") != commit:
        raise ValueError("build tag belongs to a different source commit")
    return True


def verify_existing(repo, identity, release, archive):
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("existing build release is not a published final release")
    if release.get("tag_name") != identity["tag"] or release.get("name") != release_title(identity):
        raise ValueError("existing build release metadata differs")
    if (release.get("body") or "").strip() != release_notes(identity):
        raise ValueError("existing build release provenance notes differ")
    if not verify_tag(repo, identity["tag"], identity["commit"]):
        raise ValueError("existing release has no source tag")
    assets = [asset for asset in release.get("assets", []) if asset.get("name") == "Sigil.zip"]
    if len(assets) != 1 or assets[0].get("size") != Path(archive).stat().st_size:
        raise ValueError("existing build release has a different or missing ZIP")
    with tempfile.TemporaryDirectory(prefix="sigil-release-identity-") as directory:
        gh("release", "download", identity["tag"], "--repo", repo,
           "--pattern", "Sigil.zip", "--dir", directory)
        uploaded = archive_identity(Path(directory) / "Sigil.zip")
        if uploaded != identity:
            raise ValueError("build tag collision: uploaded ZIP differs; nothing overwritten")


def release_title(identity):
    return f"Sigil {identity['version']} ({identity['build']}, {identity['commit'][:7]})"


def release_notes(identity):
    return (f"Built from main (`{identity['commit']}`). Build `{identity['build']}`. "
            f"ZIP SHA-256 `{identity['sha256']}`. Unzip and replace /Applications/Sigil.app, "
            "or from a clone: `Scripts/install.sh`.")


def find_release(repo, tag):
    # The by-tag REST endpoint omits drafts. Authenticated paginated listings
    # include them, so an interrupted upload cannot cause another create.
    pages = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    matches = [release for page in pages for release in page if release.get("tag_name") == tag]
    if len(matches) > 1:
        raise ValueError("multiple releases collide with this build tag")
    return matches[0] if matches else None


def publish(archive, env):
    identity = archive_identity(archive)
    repo, commit, build = env["GITHUB_REPOSITORY"], env["GITHUB_SHA"], env["SIGIL_BUILD"]
    verify_archive(identity, commit, build)
    # Preserve the existing build-N.attempt tag/pruning namespace.
    if not re.fullmatch(r"[1-9][0-9]*\.[1-9][0-9]*", build):
        raise ValueError("published builds require a numeric run.attempt identity")
    tag = identity["tag"]
    existing = find_release(repo, tag)
    if existing is not None:
        verify_existing(repo, identity, existing, archive)
        # A rerun of an older build must not change Latest or prune newer builds.
        return {**identity, "result": "already published; identical source and ZIP"}
    verify_tag(repo, tag, commit)  # Reject a colliding orphan tag before creation.
    gh("release", "create", tag, str(archive), "--repo", repo, "--target", commit,
       "--title", release_title(identity), "--notes", release_notes(identity), "--latest")
    # Read the uploaded ZIP and source tag before pruning anything.
    release = json.loads(gh("api", f"repos/{repo}/releases/tags/{tag}"))
    verify_existing(repo, identity, release, archive)
    prune(repo, tag)
    return {**identity, "result": "published and verified"}


def verify_archive(identity, commit, build):
    if not COMMIT.fullmatch(identity["commit"]) or identity["commit"] != commit:
        raise ValueError("dirty, unknown or mismatched source cannot be published as an exact release")
    if identity["build"] != build:
        raise ValueError("ZIP build differs from the CI build identity")


def prune(repo, tag):
    # Same limit, allowlist and warning behavior as the existing workflow.
    try:
        releases = json.loads(gh("release", "list", "--repo", repo, "--limit", "100", "--json", "tagName"))
    except RuntimeError:
        print("::warning::could not list releases to prune", file=sys.stderr)
        return
    for release in releases:
        old = release["tagName"]
        if old == tag or not PRUNABLE.fullmatch(old):
            continue
        try:
            gh("release", "delete", old, "--repo", repo, "--yes", "--cleanup-tag")
        except RuntimeError:
            # Drafts may have no tag to clean up after the release is gone.
            try:
                gh("release", "view", old, "--repo", repo)
            except RuntimeError:
                continue
            print(f"::warning::could not delete release {old}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["source", "archive", "publish"])
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
            identity = archive_identity(args.path) if args.action == "archive" else publish(args.path, os.environ)
            if args.expected_commit:
                verify_archive(identity, args.expected_commit, args.expected_build)
            print(json.dumps(identity, sort_keys=True))
    except (ValueError, KeyError, OSError, RuntimeError, zipfile.BadZipFile) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
