import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "about_host_products", Path(__file__).resolve().parents[1] / "about_host_products.py")
products = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(products)


class AboutHostProductPathsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sigil-about-paths-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.derived = self.root / "DerivedData"
        self.test_root = self.derived / "Build/Products"
        self.host = self.test_root / "Debug/SigilSidebarFixtureHost.app"
        self.bundle = self.host / "Contents/PlugIns/SigilSidebarHostTests.xctest"
        self.bundle.mkdir(parents=True)
        self.test_run = self.test_root / "fixture.xctestrun"
        self.test_run.write_text("generated non-executable fixture")
        self.target = {
            "TestHostPath": "__TESTROOT__/Debug/SigilSidebarFixtureHost.app",
            "TestBundlePath": "__TESTHOST__/Contents/PlugIns/SigilSidebarHostTests.xctest",
        }

    def resolve(self, **changes):
        return products.resolve_product_bundles({**self.target, **changes}, self.test_run, self.derived)

    def test_nested_mac_app_host_bundle_uses_testhost_placeholder(self):
        # The macOS hosted target embeds its xctest below the app's Contents/PlugIns.
        # The former one-level glob cannot find this generated layout.
        info = self.bundle / "Contents/Info.plist"
        info.parent.mkdir()
        info.write_text("generated nested product metadata")
        self.assertEqual(list(self.test_root.glob("*/SigilSidebarHostTests.xctest/Contents/Info.plist")), [])
        resolved = self.resolve()
        self.assertEqual(resolved, {
            "SigilSidebarFixtureHost.app": self.host,
            "SigilSidebarHostTests.xctest": self.bundle,
        })

    def test_testroot_and_absolute_bundle_paths_are_supported(self):
        standalone = self.test_root / "Debug/SigilSidebarHostTests.xctest"
        standalone.mkdir()
        for raw in ("__TESTROOT__/Debug/SigilSidebarHostTests.xctest", str(standalone)):
            with self.subTest(raw=raw):
                self.assertEqual(self.resolve(TestBundlePath=raw)["SigilSidebarHostTests.xctest"], standalone)

    def test_external_traversal_relative_and_unknown_paths_are_rejected(self):
        for raw in (str(self.root / "outside.xctest"),
                    "__TESTROOT__/../Products/Debug/SigilSidebarHostTests.xctest",
                    "Debug/SigilSidebarHostTests.xctest", "__UNKNOWN__/SigilSidebarHostTests.xctest"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                self.resolve(TestBundlePath=raw)
        # A platform xctest tool cannot replace the fresh app host in this diagnostic.
        with self.assertRaisesRegex(ValueError, "Unsupported diagnostic path placeholder"):
            self.resolve(TestHostPath="__PLATFORMS__/MacOSX.platform/Developer/Library/Xcode/Agents/xctest")

    def test_symlink_bundle_and_symlink_ancestor_are_rejected(self):
        link = self.test_root / "Linked"
        link.symlink_to(self.host, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.resolve(TestBundlePath="__TESTROOT__/Linked/Contents/PlugIns/SigilSidebarHostTests.xctest")
        self.bundle.rmdir()
        other = self.root / "other"
        other.mkdir()
        self.bundle.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.resolve()

    def test_symlink_executable_and_xctestrun_are_rejected(self):
        executable = self.host / "Contents/MacOS/SigilSidebarFixtureHost"
        executable.parent.mkdir(parents=True)
        outside = self.root / "generated-binary"
        outside.write_text("not executable")
        executable.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            products.checked_product_path(executable, self.derived)
        self.test_run.unlink()
        self.test_run.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.resolve()

    def test_missing_and_wrong_named_bundles_are_rejected(self):
        with self.assertRaises(FileNotFoundError):
            self.resolve(TestBundlePath="__TESTHOST__/Contents/PlugIns/Missing.xctest")
        wrong = self.host / "Contents/PlugIns/Other.xctest"
        wrong.mkdir()
        with self.assertRaisesRegex(ValueError, "Expected the generated diagnostic bundle"):
            self.resolve(TestBundlePath=str(wrong))


if __name__ == "__main__":
    unittest.main()
