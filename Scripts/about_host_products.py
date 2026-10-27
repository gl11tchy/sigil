"""Resolve the isolated macOS app-host products named by a generated xctestrun."""

from pathlib import Path
import re


def checked_product_path(path, derived):
    """Reject traversal and every symlink below the fresh DerivedData root."""
    path, derived = Path(path), Path(derived).absolute()
    if not path.is_absolute() or ".." in path.parts or not path.is_relative_to(derived):
        raise ValueError(f"Diagnostic product escaped fresh DerivedData: {path}")
    for component in (path, *path.parents):
        if component.is_symlink():
            raise ValueError(f"Diagnostic product contains a symlink: {component}")
        if component == derived:
            break
    if not path.resolve(strict=True).is_relative_to(derived.resolve(strict=True)):
        raise ValueError(f"Diagnostic product escaped fresh DerivedData: {path}")
    return path


def resolve_product_bundles(target, test_run, derived):
    # xcodebuild.xctestrun(5): TESTROOT is the xctestrun's directory; TESTHOST
    # is the host directory from TestHostPath. Platform tool hosts are outside
    # this diagnostic's fresh app-host boundary and remain unsupported.
    test_root = checked_product_path(test_run, derived).parent

    def expand(value, substitutions):
        if not isinstance(value, str) or not value:
            raise ValueError("Missing diagnostic product path")

        def replace(match):
            token = match.group()
            if token not in substitutions:
                raise ValueError(f"Unsupported diagnostic path placeholder: {token}")
            return str(substitutions[token])

        return checked_product_path(re.sub(r"__[A-Z][A-Z0-9_]*__", replace, value), derived)

    host = expand(target["TestHostPath"], {"__TESTROOT__": test_root})
    bundle = expand(target["TestBundlePath"], {"__TESTROOT__": test_root, "__TESTHOST__": host})
    expected = {"SigilSidebarFixtureHost.app": host, "SigilSidebarHostTests.xctest": bundle}
    for name, path in expected.items():
        if path.name != name or not path.is_dir():
            raise ValueError(f"Expected the generated diagnostic bundle {name}: {path}")
    return expected
