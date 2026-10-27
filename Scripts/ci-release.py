#!/usr/bin/env python3
"""Transfer a verified ZIP between CI jobs; publish only a matching main artifact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

MAX_ZIP_BYTES = 200 * 1024 * 1024
OLD_BUILD = re.compile(r"(latest|build-[0-9]+\.[0-9]+)")


class ReleaseError(Exception):
    pass


def positive(value):
    if not re.fullmatch(r"[1-9][0-9]*", str(value)):
        raise ReleaseError("Missing or invalid positive CI identifier")
    return int(value)


def context(env):
    repository = env.get("GITHUB_REPOSITORY", "")
    sha = env.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ReleaseError("Invalid repository")
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", sha):
        raise ReleaseError("Invalid source SHA")
    return dict(repository=repository, sha=sha, run_id=positive(env.get("GITHUB_RUN_ID")),
                run_number=positive(env.get("GITHUB_RUN_NUMBER")),
                attempt=positive(env.get("GITHUB_RUN_ATTEMPT")),
                event=env.get("GITHUB_EVENT_NAME"), ref=env.get("GITHUB_REF"))


def zip_identity(path):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_ZIP_BYTES:
        raise ReleaseError("Verified Sigil.zip must be a bounded regular file")
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return dict(sha256=digest.hexdigest(), size=path.stat().st_size)


def record(directory, env):
    metadata = dict(schema=1, **context(env), **zip_identity(directory / "Sigil.zip"))
    (directory / "release.json").write_text(json.dumps(metadata, sort_keys=True) + "\n")
    with Path(env["GITHUB_OUTPUT"]).open("a") as output:
        output.write("zip_sha256=" + metadata["sha256"] + "\n")
        output.write("zip_bytes=" + str(metadata["size"]) + "\n")
        output.write("verify_attempt=" + str(metadata["attempt"]) + "\n")
    print("Recorded verified ZIP " + metadata["sha256"], file=sys.stderr)
    return metadata


class GitHub:
    """Only the release step receives GH_TOKEN; no credential is written to disk."""
    def __init__(self, repository):
        if not os.environ.get("GH_TOKEN"):
            raise ReleaseError("Release token is unavailable")
        self.repository = repository
        self.deadline = time.monotonic() + 300

    def command(self, args):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise ReleaseError("Release operation exceeded its time bound")
        try:
            result = subprocess.run(
                ["gh", *args], capture_output=True, text=True, timeout=min(45, remaining),
                env={**os.environ, "GH_HOST": "github.com", "GH_REPO": self.repository,
                     "GH_PROMPT_DISABLED": "1"})
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ReleaseError("GitHub command did not confirm completion") from error
        if result.returncode:
            raise ReleaseError("GitHub command failed: " + result.stderr.strip()[:2000])
        if len(result.stdout) > 8 * 1024 * 1024:
            raise ReleaseError("GitHub response exceeded its size bound")
        return result.stdout

    def api(self, path):
        try:
            return json.loads(self.command(["api", "--hostname", "github.com", path]))
        except ValueError as error:
            raise ReleaseError("GitHub returned invalid JSON") from error

    def main_sha(self):
        result = self.api("repos/" + self.repository + "/git/ref/heads/main")
        return result.get("object", {}).get("sha")

    def releases(self):
        # Authenticated listings include drafts; a published-only tag lookup does not.
        releases = []
        for page in range(1, 11):
            result = self.api("repos/" + self.repository + "/releases?per_page=100&page=" + str(page))
            if not isinstance(result, list):
                raise ReleaseError("Invalid release listing")
            releases.extend(result)
            if len(result) < 100:
                return releases
        raise ReleaseError("Release listing is incomplete; refusing an ambiguous create")

    def tag_sha(self, tag):
        result = self.api("repos/" + self.repository + "/git/matching-refs/tags/" + tag)
        if not isinstance(result, list):
            raise ReleaseError("Invalid tag listing")
        matches = [item for item in result if item.get("ref") == "refs/tags/" + tag]
        if not matches:
            return None
        if len(matches) != 1 or matches[0].get("object", {}).get("type") != "commit":
            raise ReleaseError("Unexpected release tag")
        return matches[0]["object"]["sha"]

    def create(self, tag, archive, title, notes, sha):
        with tempfile.TemporaryDirectory(prefix="sigil-release-notes-") as temporary:
            note_file = Path(temporary) / "notes.txt"
            note_file.write_text(notes)
            self.command(["release", "create", tag, str(archive), "--repo", self.repository,
                          "--target", sha, "--title", title, "--notes-file", str(note_file), "--latest"])

    def delete(self, tag):
        self.command(["release", "delete", tag, "--repo", self.repository, "--yes", "--cleanup-tag"])


def matching_release(items, tag):
    matches = [item for item in items if item.get("tag_name") == tag]
    if len(matches) > 1:
        raise ReleaseError("Ambiguous release collision")
    return matches[0] if matches else None


def validate_release(release, tag, title, notes, metadata, github):
    if not release or release.get("draft") is not False or release.get("prerelease") is not False:
        raise ReleaseError("Missing, draft or incomplete release; preserving it without automatic repair")
    if not release.get("published_at") or release.get("name") != title or release.get("body") != notes:
        raise ReleaseError("Existing release metadata does not match the verified artifact")
    assets = release.get("assets")
    if not isinstance(assets, list) or len(assets) != 1:
        raise ReleaseError("Release does not contain exactly the verified ZIP")
    asset = assets[0]
    if (asset.get("name") != "Sigil.zip" or asset.get("state") != "uploaded"
            or asset.get("size") != metadata["size"]
            or asset.get("digest") != "sha256:" + metadata["sha256"]):
        raise ReleaseError("Published ZIP digest/size is missing or does not match")
    if github.tag_sha(tag) != metadata["sha"]:
        raise ReleaseError("Published tag does not match the verified source")


def publish(directory, env, github=None):
    current = context(env)
    if current["event"] != "push" or current["ref"] != "refs/heads/main":
        raise ReleaseError("Publication is restricted to a push on main")
    manifest = directory / "release.json"
    if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_size > 8192:
        raise ReleaseError("Missing or oversized release manifest")
    try:
        metadata = json.loads(manifest.read_text())
    except (ValueError, UnicodeError) as error:
        raise ReleaseError("Malformed release manifest") from error
    if not isinstance(metadata, dict) or type(metadata.get("schema")) is not int or metadata["schema"] != 1:
        raise ReleaseError("Unsupported release manifest")
    for key in ["repository", "sha", "run_id", "run_number", "event", "ref"]:
        if type(metadata.get(key)) is not type(current[key]) or metadata[key] != current[key]:
            raise ReleaseError("Artifact does not belong to this verified run/source: " + key)
    attempt = positive(env.get("EXPECTED_VERIFY_ATTEMPT"))
    if type(metadata.get("attempt")) is not int or metadata["attempt"] != attempt or attempt > current["attempt"]:
        raise ReleaseError("Artifact verification attempt does not match")
    positive(env.get("EXPECTED_ARTIFACT_ID"))
    identity = zip_identity(directory / "Sigil.zip")
    if not re.fullmatch(r"[0-9a-f]{64}", env.get("EXPECTED_ZIP_SHA256", "")):
        raise ReleaseError("Missing verification-job ZIP digest")
    if (metadata.get("sha256") != identity["sha256"] or metadata.get("size") != identity["size"]
            or identity["sha256"] != env["EXPECTED_ZIP_SHA256"]
            or identity["size"] != positive(env.get("EXPECTED_ZIP_BYTES"))):
        raise ReleaseError("Downloaded ZIP differs from the verification job")
    github = github or GitHub(current["repository"])
    if github.main_sha() != current["sha"]:
        raise ReleaseError("Main advanced; refusing stale publication")
    # A release-only rerun must retain the producing job's tag, not make a new one.
    tag = "build-" + str(current["run_number"]) + "." + str(attempt)
    title = "Sigil " + current["sha"][:7]
    tick = chr(96)
    notes = ("Built from main (" + tick + current["sha"] + tick
             + "). Unzip and replace /Applications/Sigil.app, or from a clone: "
             + tick + "Scripts/install.sh" + tick + ".\n\nVerified CI run: https://github.com/"
             + current["repository"] + "/actions/runs/" + str(current["run_id"])
             + "\nVerified artifact ID: " + env["EXPECTED_ARTIFACT_ID"]
             + "\nSource ZIP SHA256: " + identity["sha256"])
    items = github.releases()
    existing = matching_release(items, tag)
    if existing:
        validate_release(existing, tag, title, notes, metadata, github)
    else:
        if github.tag_sha(tag) is not None:
            raise ReleaseError("Tag exists without a matching release; preserving the collision")
        create_error = None
        try:
            github.create(tag, directory / "Sigil.zip", title, notes, current["sha"])
        except ReleaseError as error:
            create_error = error
        # Creation is not atomic. Read back an uncertain result; never issue a second create.
        try:
            items = github.releases()
            validate_release(matching_release(items, tag), tag, title, notes, metadata, github)
        except ReleaseError as error:
            if create_error:
                raise ReleaseError("Publication outcome uncertain; no retry attempted: " + str(error)) from create_error
            raise
    # Preserve the existing old-build cleanup policy, only after a proven publication.
    for item in items[:100]:
        old = item.get("tag_name", "")
        if old != tag and OLD_BUILD.fullmatch(old):
            try:
                github.delete(old)
            except ReleaseError:
                print("::warning::could not prune old build " + old, file=sys.stderr)
    print("Verified release " + tag + " ZIP SHA256 " + identity["sha256"], file=sys.stderr)
    return dict(tag=tag, sha256=identity["sha256"], existing=existing is not None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["record", "publish"])
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        (record if args.operation == "record" else publish)(args.directory, os.environ)
    except (ReleaseError, OSError, ValueError) as error:
        print("release: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
