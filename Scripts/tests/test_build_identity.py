"""Synthetic Git/ZIP/CLI-boundary fixtures; no compiler, app or network is used."""

import importlib.util
import json
import os
from pathlib import Path
import plistlib
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
        head = self.git("rev-parse", "HEAD")
        for relative in ["checkouts", "universal/arm64/checkouts", "universal/x86_64/checkouts"]:
            with self.subTest(relative=relative):
                dependency = self.repo / ".build" / relative / "dependency"
                subprocess.run(["git", "clone", "-q", str(self.repo), str(dependency)], env=self.env, check=True)
                self.assertEqual(self.source()["commit"], head)
                (dependency / "source").write_text("edited dependency")
                self.assertEqual(self.git("status", "--porcelain"), "")
                self.assertEqual(self.source()["commit"], head + "-dirty")
                subprocess.run(["git", "-C", str(dependency), "restore", "source"], env=self.env, check=True)

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

    def test_duplicate_plist_and_invalid_metadata_are_rejected(self):
        with warnings.catch_warnings(), zipfile.ZipFile(self.archive, "a") as zipped:
            warnings.simplefilter("ignore", UserWarning)
            zipped.writestr("Sigil.app/Contents/Info.plist", b"other")
        with self.assertRaises(ValueError):
            identity.archive_identity(self.archive)
        zip_fixture(self.archive, build="not-a-number")
        with self.assertRaises(ValueError):
            identity.archive_identity(self.archive)

    def test_dirty_unknown_wrong_source_and_wrong_build_are_rejected(self):
        for commit, build in [(SHA + "-dirty", "548.1"), ("unknown", "548.1"),
                              ("b" * 40, "548.1"), (SHA, "549.1")]:
            zip_fixture(self.archive, commit=commit, build=build)
            with self.subTest(commit=commit, build=build), self.assertRaises(ValueError):
                identity.verify_archive(identity.archive_identity(self.archive), SHA, "548.1")

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


if __name__ == "__main__":
    unittest.main()
