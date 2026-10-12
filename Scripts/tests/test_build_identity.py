"""Synthetic Git/ZIP/CLI-boundary fixtures; no compiler, app or network is used."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "build-identity.py"
SPEC = importlib.util.spec_from_file_location("build_identity", SCRIPT)
identity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identity)
SHA = "a" * 40


def zip_fixture(path, commit=SHA, build="548.1", payload=b"a"):
    with zipfile.ZipFile(path, "w") as zipped:
        zipped.writestr("Sigil.app/Contents/Info.plist", plistlib.dumps({
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": build,
            "SigilCommit": commit,
        }))
        zipped.writestr("Sigil.app/Contents/MacOS/Sigil", payload)
    return path


class FakeGitHub:
    def __init__(self, archive, existing=False, tagged=SHA):
        self.archive = archive
        self.calls = []
        self.tagged = tagged if existing else None
        info = identity.archive_identity(archive)
        self.release = self.metadata(info) if existing else None
        self.tags = [info["tag"], "build-547.1", "latest", "v1.0.0", "build-547", "build-preview"]

    def metadata(self, info):
        return {"tag_name": info["tag"], "name": identity.release_title(info),
                "body": identity.release_notes(info),
                "draft": False, "prerelease": False,
                "assets": [{"name": "Sigil.zip", "size": self.archive.stat().st_size}]}

    def __call__(self, *args, missing_ok=False):
        self.calls.append(args)
        if args[0] == "api":
            if "--paginate" in args:
                return json.dumps([[], [self.release] if self.release else []])
            if "/releases/tags/" in args[1]:
                return json.dumps(self.release) if self.release and not self.release["draft"] else None
            if "/git/ref/tags/" in args[1]:
                return json.dumps({"object": {"type": "commit", "sha": self.tagged}}) if self.tagged else None
        if args[:2] == ("release", "create"):
            self.archive = Path(args[3])
            self.tagged = args[args.index("--target") + 1]
            self.release = self.metadata(identity.archive_identity(self.archive))
            return "created"
        if args[:2] == ("release", "download"):
            shutil.copyfile(self.archive, Path(args[args.index("--dir") + 1]) / "Sigil.zip")
            return ""
        if args[:2] == ("release", "list"):
            return json.dumps([{"tagName": tag} for tag in self.tags])
        if args[:2] == ("release", "delete"):
            self.tags.remove(args[2])
            return ""
        raise AssertionError(f"unexpected fake GitHub action {args}")

    @property
    def mutations(self):
        return [call for call in self.calls if call[:2] in {
            ("release", "create"), ("release", "delete"), ("release", "edit"), ("release", "upload")
        }]


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sigil-build-identity-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {**os.environ, "HOME": str(self.home), "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.file = self.repo / "source"
        self.file.write_text("one")
        self.git("add", "source")
        self.git("commit", "-qm", "one")
        self.file.write_text("two")
        self.git("commit", "-qam", "two")
        self.head = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], env=self.env,
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def source(self, root=None, env=None):
        with patch.dict(os.environ, self.env, clear=True):
            return identity.source_identity(root or self.repo, env or {})

    def test_clean_full_commit_and_local_count(self):
        self.assertEqual(self.source(), {"version": "1.0.0", "build": "2", "commit": self.head})

    def test_dirty_tracked_and_untracked_sources_are_marked(self):
        self.file.write_text("edited")
        self.assertEqual(self.source()["commit"], self.head + "-dirty")
        self.file.write_text("two")
        (self.repo / "new-source").write_text("untracked")
        self.assertEqual(self.source()["commit"], self.head + "-dirty")

    def test_outside_git_and_nested_tarball_use_unknown(self):
        outside = self.root / "tarball"
        outside.mkdir()
        self.assertEqual(self.source(outside), {"version": "1.0.0", "build": "1", "commit": "unknown"})
        nested = self.repo / "tarball"
        nested.mkdir()
        self.assertEqual(self.source(nested)["commit"], "unknown")

    def test_shallow_history_keeps_commit_and_explicit_ci_identity(self):
        shallow = self.root / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth=1", self.repo.as_uri(), str(shallow)],
                       env=self.env, check=True)
        self.assertEqual(self.source(shallow)["build"], "1")
        self.assertEqual(self.source(shallow, {"SIGIL_BUILD": "548.2"}),
                         {"version": "1.0.0", "build": "548.2", "commit": self.head})

    def test_equal_count_different_commits_have_distinct_source_identity(self):
        first = self.source()
        self.git("checkout", "--orphan", "other")
        self.git("commit", "-qm", "other one")
        self.file.write_text("other")
        self.git("commit", "-qam", "other two")
        second = self.source()
        self.assertEqual(first["build"], second["build"])
        self.assertNotEqual(first["commit"], second["commit"])

    def test_ignored_build_outputs_do_not_mark_source_dirty(self):
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "ignore generated products")
        (self.repo / ".build").mkdir()
        (self.repo / ".build" / "binary").write_text("generated")
        self.assertEqual(self.source()["commit"], self.git("rev-parse", "HEAD"))

    def test_invalid_build_or_version_is_rejected(self):
        for env in [{"SIGIL_BUILD": "0"}, {"SIGIL_BUILD": "abc"}, {"SIGIL_BUILD": "1.2.3.4"},
                    {"SIGIL_VERSION": "1"}, {"SIGIL_VERSION": "1.0.0-dirty"}]:
            with self.subTest(env=env), self.assertRaises(ValueError):
                self.source(env=env)

    def test_edited_ignored_dependency_checkout_marks_root_dirty(self):
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "ignore generated products")
        dependency = self.repo / ".build" / "checkouts" / "dependency"
        subprocess.run(["git", "clone", "-q", str(self.repo), str(dependency)], env=self.env, check=True)
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.source()["commit"], head)
        (dependency / "source").write_text("edited dependency")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.source()["commit"], head + "-dirty")

    def test_ignored_compiled_source_marks_dirty_but_finder_metadata_does_not(self):
        (self.repo / ".gitignore").write_text("Sources/Generated.swift\n.DS_Store\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "ignore generated source")
        source = self.repo / "Sources"
        source.mkdir()
        (source / ".DS_Store").write_text("finder")
        head = self.git("rev-parse", "HEAD")
        self.assertEqual(self.source()["commit"], head)
        (source / "Generated.swift").write_text("compiled source")
        self.assertEqual(self.source()["commit"], head + "-dirty")


class ReleaseIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sigil-release-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = zip_fixture(self.root / "Sigil.zip")
        self.env = {"GITHUB_REPOSITORY": "fixture/sigil", "GITHUB_SHA": SHA, "SIGIL_BUILD": "548.1"}

    def test_final_zip_identity_drives_release_metadata(self):
        info = identity.archive_identity(self.archive)
        self.assertEqual(info["tag"], "build-548.1")
        self.assertEqual(info["commit"], SHA)
        self.assertEqual(identity.release_title(info), "Sigil 1.0.0 (548.1, aaaaaaa)")

    def test_duplicate_plist_and_invalid_metadata_are_rejected(self):
        with warnings.catch_warnings(), zipfile.ZipFile(self.archive, "a") as zipped:
            warnings.simplefilter("ignore", UserWarning)
            zipped.writestr("Sigil.app/Contents/Info.plist", b"other")
        with self.assertRaises(ValueError):
            identity.archive_identity(self.archive)
        zip_fixture(self.archive, build="not-a-number")
        with self.assertRaises(ValueError):
            identity.archive_identity(self.archive)

    def test_dirty_unknown_wrong_source_and_wrong_build_never_publish(self):
        for commit, build in [(SHA + "-dirty", "548.1"), ("unknown", "548.1"),
                              ("b" * 40, "548.1"), (SHA, "549.1")]:
            zip_fixture(self.archive, commit=commit, build=build)
            with self.subTest(commit=commit, build=build), patch.object(identity, "gh") as gh:
                with self.assertRaises(ValueError):
                    identity.publish(self.archive, self.env)
                gh.assert_not_called()

    def test_archive_cli_checks_expected_source_and_build(self):
        env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        args = ["python3", str(SCRIPT), "archive", str(self.archive),
                "--expected-commit", SHA, "--expected-build", "548.1"]
        good = subprocess.run(args, env=env, capture_output=True, text=True)
        self.assertEqual(good.returncode, 0, good.stderr)
        self.assertEqual(json.loads(good.stdout)["tag"], "build-548.1")
        bad = subprocess.run([*args[:-1], "549.1"], env=env, capture_output=True, text=True)
        self.assertNotEqual(bad.returncode, 0)
        self.assertIn("ZIP build differs", bad.stderr)

    def test_prune_warns_if_release_remains_after_delete_failure(self):
        calls = []
        def fake(*args, **kwargs):
            calls.append(args)
            if args[:2] == ("release", "list"):
                return json.dumps([{"tagName": "build-547.1"}])
            if args[:2] == ("release", "delete"):
                raise RuntimeError("tag cleanup failed")
            return "release remains"
        with patch.object(identity, "gh", fake), patch("sys.stderr") as stderr:
            identity.prune("fixture/sigil", "build-548.1")
            self.assertIn("could not delete release build-547.1", "".join(str(c) for c in stderr.write.call_args_list))
        self.assertEqual(calls[-1][:2], ("release", "view"))

    def test_fresh_publish_verifies_upload_before_existing_prune_allowlist(self):
        fake = FakeGitHub(self.archive)
        with patch.object(identity, "gh", fake):
            result = identity.publish(self.archive, self.env)
        self.assertEqual(result["result"], "published and verified")
        self.assertEqual([call[2] for call in fake.calls if call[:2] == ("release", "delete")],
                         ["build-547.1", "latest"])
        download = next(i for i, call in enumerate(fake.calls) if call[:2] == ("release", "download"))
        deletion = next(i for i, call in enumerate(fake.calls) if call[:2] == ("release", "delete"))
        self.assertLess(download, deletion)

    def test_identical_rerun_does_not_publish_edit_or_prune(self):
        fake = FakeGitHub(self.archive, existing=True)
        with patch.object(identity, "gh", fake):
            result = identity.publish(self.archive, self.env)
        self.assertEqual(result["result"], "already published; identical source and ZIP")
        self.assertEqual(fake.mutations, [])

    def test_same_commit_and_build_but_different_zip_cannot_overwrite(self):
        other = zip_fixture(self.root / "different.zip", payload=b"b")
        fake = FakeGitHub(other, existing=True)
        # Even claimed notes cannot substitute for downloading the actual ZIP.
        fake.release["body"] = identity.release_notes(identity.archive_identity(self.archive))
        with patch.object(identity, "gh", fake), self.assertRaisesRegex(ValueError, "uploaded ZIP differs"):
            identity.publish(self.archive, self.env)
        self.assertEqual(fake.mutations, [])

    def test_same_build_different_source_tag_cannot_overwrite(self):
        fake = FakeGitHub(self.archive, existing=True, tagged="b" * 40)
        with patch.object(identity, "gh", fake), self.assertRaisesRegex(ValueError, "different source"):
            identity.publish(self.archive, self.env)
        self.assertEqual(fake.mutations, [])

    def test_edited_provenance_notes_cannot_pass_as_identical(self):
        fake = FakeGitHub(self.archive, existing=True)
        fake.release["body"] = "Built from a different source and digest"
        with patch.object(identity, "gh", fake), self.assertRaisesRegex(ValueError, "provenance notes differ"):
            identity.publish(self.archive, self.env)
        self.assertEqual(fake.mutations, [])

    def test_orphan_tag_collision_stops_before_publication(self):
        fake = FakeGitHub(self.archive)
        fake.tagged = "b" * 40
        with patch.object(identity, "gh", fake), self.assertRaises(ValueError):
            identity.publish(self.archive, self.env)
        self.assertEqual(fake.mutations, [])

    def test_existing_draft_is_not_overwritten_or_pruned(self):
        fake = FakeGitHub(self.archive, existing=True)
        fake.release["draft"] = True
        with patch.object(identity, "gh", fake), self.assertRaises(ValueError):
            identity.publish(self.archive, self.env)
        self.assertEqual(fake.mutations, [])
        self.assertTrue(any("--paginate" in call for call in fake.calls))

    def test_permission_error_stops_before_any_mutation(self):
        with patch.object(identity, "gh", side_effect=RuntimeError("HTTP 403 denied")) as gh:
            with self.assertRaises(RuntimeError):
                identity.publish(self.archive, self.env)
            self.assertEqual(gh.call_count, 1)

    def test_cli_only_treats_explicit_api_404_as_absent(self):
        for error, absent in [("gh: Not Found (HTTP 404)", True), ("gh: denied (HTTP 403)", False),
                              ("gh: offline", False)]:
            result = subprocess.CompletedProcess([], 1, "", error)
            with self.subTest(error=error), patch.object(subprocess, "run", return_value=result):
                if absent:
                    self.assertIsNone(identity.gh("api", "fixture", missing_ok=True))
                else:
                    with self.assertRaises(RuntimeError):
                        identity.gh("api", "fixture", missing_ok=True)


if __name__ == "__main__":
    unittest.main()
