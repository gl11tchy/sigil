"""Generated data and an in-memory GitHub boundary; no network or real token."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys


def github_cli():
    """Strict CLI grammar and persistent generated responses, never an HTTP server."""
    state_path = Path(os.environ["SIGIL_GH_STATE"])
    state = json.loads(state_path.read_text())
    args = sys.argv[2:]
    if len(args) == 4 and args[:3] == ["api", "--hostname", "github.com"]:
        path = args[3]
        state["apiCalls"].append(path)
        prefix = "repos/fixture/sigil/"
        if not path.startswith(prefix):
            raise RuntimeError("Unexpected repository")
        path = path[len(prefix):]
        if path == "git/ref/heads/main":
            result = {"object": {"sha": "a" * 40}}
        elif path.startswith("releases?per_page=100&page="):
            page = int(path.split("=")[-1])
            result = state["items"][(page - 1) * 100:page * 100]
        elif path.startswith("git/matching-refs/tags/"):
            tag = path.removeprefix("git/matching-refs/tags/")
            sha = state["tags"].get(tag)
            result = [{"ref": "refs/tags/" + tag, "object": {"type": "commit", "sha": sha}}] if sha else []
        else:
            raise RuntimeError("Unexpected API operation")
        print(json.dumps(result))
    elif args[:2] == ["release", "create"]:
        assert args[-1] == "--latest" and len(args) == 13
        assert args[4:6] == ["--repo", "fixture/sigil"]
        assert args[6:8] == ["--target", "a" * 40]
        assert args[8:10] == ["--title", "Sigil aaaaaaa"]
        assert args[10] == "--notes-file"
        tag, archive = args[2], Path(args[3])
        assert archive == state_path.parent / "Sigil.zip"
        data = archive.read_bytes()
        notes = Path(args[11]).read_text()
        state["created"] += 1
        state["writes"].append("create:" + tag)
        state["tags"][tag] = "a" * 40
        state["items"].insert(0, dict(
            id=state["created"], tag_name=tag, name="Sigil aaaaaaa", body=notes,
            draft=False, prerelease=False, published_at="2026-10-27T00:00:00Z",
            assets=[dict(name="Sigil.zip", size=len(data), state="uploaded",
                         digest="sha256:" + hashlib.sha256(data).hexdigest())]))
        print("https://github.com/fixture/sigil/releases/tag/" + tag)
    else:
        raise RuntimeError("Unexpected GitHub mutation")
    state_path.write_text(json.dumps(state))


if sys.argv[1] == "--github":
    github_cli()
    sys.exit(0)

helper, directory, scenario = sys.argv[1:]
root = Path(directory)
spec = importlib.util.spec_from_file_location("ci_release", helper)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
env = {
    "GITHUB_REPOSITORY": "fixture/sigil", "GITHUB_SHA": "a" * 40,
    "GITHUB_RUN_ID": "77", "GITHUB_RUN_NUMBER": "12", "GITHUB_RUN_ATTEMPT": "1",
    "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/main",
    "GITHUB_OUTPUT": str(root / "outputs"), "EXPECTED_ARTIFACT_ID": "1234",
}
archive = root / "Sigil.zip"
archive.write_bytes(b"generated opaque ZIP bytes; no application")


def record():
    metadata = module.record(root, env)
    env.update(EXPECTED_ZIP_SHA256=metadata["sha256"], EXPECTED_ZIP_BYTES=str(metadata["size"]),
               EXPECTED_VERIFY_ATTEMPT=str(metadata["attempt"]))


class FakeGitHub:
    def __init__(self):
        self.items = []
        self.tags = {}
        self.writes = []
        self.created = 0
        self.last_notes = ""

    def main_sha(self):
        return "b" * 40 if scenario == "stale-main" else env["GITHUB_SHA"]

    def releases(self):
        if scenario == "read-failure":
            raise module.ReleaseError("generated GitHub read failure")
        return json.loads(json.dumps(self.items))

    def tag_sha(self, tag):
        return self.tags.get(tag)

    def create(self, tag, path, title, notes, sha):
        self.created += 1
        self.writes.append("create:" + tag)
        self.last_notes = notes
        data = Path(path).read_bytes()
        item = {
            "id": self.created, "tag_name": tag, "name": title, "body": notes,
            "draft": False, "prerelease": False, "published_at": "2026-10-27T00:00:00Z",
            "assets": [{"name": "Sigil.zip", "size": len(data), "state": "uploaded",
                        "digest": "sha256:" + hashlib.sha256(data).hexdigest()}],
        }
        self.items.insert(0, item)
        self.tags[tag] = sha
        if scenario == "uncertain-complete":
            raise module.ReleaseError("generated uncertain create after publication")
        if scenario == "uncertain-partial":
            item.update(draft=True, published_at=None, assets=[])
            raise module.ReleaseError("generated uncertain create after draft")
        if scenario == "newer-after-create":
            self.items.insert(0, {"tag_name": "build-12.10"})
            self.tags["build-12.10"] = sha

    def delete(self, tag):
        self.writes.append("delete:" + tag)
        self.items = [item for item in self.items if item["tag_name"] != tag]
        self.tags.pop(tag, None)


github = FakeGitHub()
ok = False
error = None
tag = None
preserved_state = None
try:
    record()
    if scenario == "transport":
        state = dict(items=[], tags={}, created=0, writes=[], apiCalls=[])
        state_path = Path(os.environ["SIGIL_GH_STATE"])
        state_path.write_text(json.dumps(state))
        result = module.publish(root, env)
        env["GITHUB_RUN_ATTEMPT"] = "2"
        again = module.publish(root, env)
        assert again["tag"] == result["tag"]
        state = json.loads(state_path.read_text())
        print(json.dumps(dict(ok=True, error=None, tag=again["tag"], **{
            key: state[key] for key in ["created", "writes", "apiCalls"]})))
        sys.exit(0)
    older_producers = {"older-producer-rerun", "older-existing-rerun",
                       "numeric-newer-attempt", "newer-run-release"}
    seeded = {"rerun", "release-only-rerun", "verification-rerun", "edited-notes",
              "wrong-asset-digest", "missing-asset-digest", "draft-collision"}
    if scenario in seeded | older_producers:
        module.publish(root, env, github)
        github.writes.clear()
    if scenario in {"release-only-rerun", "verification-rerun"}:
        env["GITHUB_RUN_ATTEMPT"] = "2"
    if scenario == "verification-rerun":
        record()
    if scenario == "tampered-zip":
        archive.write_bytes(b"substituted bytes")
    if scenario == "wrong-output-hash":
        env["EXPECTED_ZIP_SHA256"] = "b" * 64
    if scenario == "wrong-output-size":
        env["EXPECTED_ZIP_BYTES"] = "1"
    for name, key, value in [
        ("wrong-source", "sha", "b" * 40), ("wrong-run", "run_id", 99),
        ("wrong-repository", "repository", "another/sigil"), ("future-attempt", "attempt", 3),
    ]:
        if scenario == name:
            manifest = json.loads((root / "release.json").read_text())
            manifest[key] = value
            (root / "release.json").write_text(json.dumps(manifest))
            if name == "future-attempt":
                env["EXPECTED_VERIFY_ATTEMPT"] = "3"
    if scenario == "malformed-manifest":
        (root / "release.json").write_text("{")
    if scenario == "manual-event":
        env["GITHUB_EVENT_NAME"] = "workflow_dispatch"
    if scenario == "pull-request-event":
        env["GITHUB_EVENT_NAME"] = "pull_request"
    if scenario == "wrong-ref":
        env["GITHUB_REF"] = "refs/heads/unreviewed"
    if scenario == "edited-notes":
        github.items[0]["body"] += "\nchanged provenance"
    if scenario == "wrong-asset-digest":
        github.items[0]["assets"][0]["digest"] = "sha256:" + "b" * 64
    if scenario == "missing-asset-digest":
        github.items[0]["assets"][0].pop("digest")
    if scenario == "draft-collision":
        github.items[0]["draft"] = True
    if scenario == "tag-collision":
        github.tags["build-12.1"] = "b" * 40
    if scenario in older_producers:
        old_env, old_manifest, old_bytes = dict(env), (root / "release.json").read_bytes(), archive.read_bytes()
        old_release = json.loads(json.dumps(github.items[0]))
        env["GITHUB_RUN_ATTEMPT"] = "10" if scenario == "numeric-newer-attempt" else "2"
        if scenario == "newer-run-release":
            env.update(GITHUB_RUN_NUMBER="13", GITHUB_RUN_ID="78", GITHUB_RUN_ATTEMPT="1")
        env["EXPECTED_ARTIFACT_ID"] = "1235"
        archive.write_bytes(b"generated newer ZIP bytes; no application")
        record()
        module.publish(root, env, github)
        if scenario == "older-existing-rerun":
            github.items.append(old_release)
            github.tags["build-12.1"] = old_env["GITHUB_SHA"]
        env.update(old_env)
        env["GITHUB_RUN_ATTEMPT"] = "11"
        archive.write_bytes(old_bytes)
        (root / "release.json").write_bytes(old_manifest)
        github.writes.clear()
        preserved_state = json.dumps(dict(items=github.items, tags=github.tags), sort_keys=True)
    if scenario == "prune":
        github.items.extend({"tag_name": tag} for tag in ["build-11.1", "latest", "manual-owner-release"])
    result = module.publish(root, env, github)
    tag = result["tag"]
    if scenario == "verification-rerun":
        env["GITHUB_RUN_ATTEMPT"] = "3"
        result = module.publish(root, env, github)
        assert result["tag"] == tag
    ok = True
except (module.ReleaseError, ValueError, OSError) as failure:
    error = str(failure)
print(json.dumps(dict(ok=ok, error=error, tag=tag, created=github.created, writes=github.writes,
                      notes=github.last_notes, remaining=[item["tag_name"] for item in github.items],
                      preserved=preserved_state == json.dumps(dict(items=github.items, tags=github.tags),
                                                              sort_keys=True))))
