#!/usr/bin/env bash
# Build locally with --build-only. Window-opening hosted tests execute only in CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-test}"
if [[ "$MODE" != --build-only && "$MODE" != test && "$MODE" != --about-only ]]; then
  echo "Usage: $0 [--build-only|--about-only]" >&2
  exit 2
fi
if [[ "$MODE" != --build-only && "${CI:-}" != true ]]; then
  echo "Sidebar app-hosted tests require CI; use --build-only locally." >&2
  exit 2
fi

python3 - "$ROOT" "$MODE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
build_only = sys.argv[2] == '--build-only'
about_only = sys.argv[2] == '--about-only'
sys.path.insert(0, str(root / 'Scripts'))
from sidebar_host_results import validate
from about_host_results import validate as validate_about
from about_host_products import checked_product_path, resolve_product_bundles

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def source_sha():
    return subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()

def require_clean_source(expected):
    if source_sha() != expected or subprocess.check_output([
        'git', '-C', str(root), 'status', '--porcelain', '--untracked-files=all'
    ], text=True).strip():
        raise SystemExit('About diagnostics require the exact clean reviewed source.')

if about_only:
    expected = os.environ.get('SIGIL_EXPECTED_SOURCE_SHA', '')
    if (os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('GITHUB_EVENT_NAME') != 'workflow_dispatch'
            or not re.fullmatch(r'[0-9a-f]{40}', expected)
            or os.environ.get('GITHUB_SHA') != expected):
        raise SystemExit('About diagnostics require a source-pinned GitHub Actions run.')
    require_clean_source(expected)
    artifacts = Path(os.environ['SIGIL_SIDEBAR_ARTIFACTS'])
    if not artifacts.is_absolute() or artifacts.resolve().is_relative_to(root.resolve()):
        raise SystemExit('About diagnostic evidence must be outside the source checkout.')
    artifacts.mkdir(parents=True, exist_ok=False)
    diagnostic_log = artifacts / 'about-activation.log'
    provenance = {
        'sourceSHA': expected,
        'sourceTree': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD^{tree}'], text=True).strip(),
        'runID': os.environ['GITHUB_RUN_ID'], 'attempt': os.environ['GITHUB_RUN_ATTEMPT'],
        'selector': 'SigilSidebarHostTests/AboutBuildIdentityHostTests',
        'fixtureSHA256': digest(root / 'Tests/SigilAppTests/AboutBuildIdentityHostTests.swift'),
        'stage': 'source-verified',
    }
    (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')

def run(command, environment, timeout, require_success=True):
    process = subprocess.Popen(command, env=environment, start_new_session=True)
    try:
        status = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise SystemExit(f'Sidebar host command exceeded its {timeout}s bound.')
    if status and require_success:
        raise SystemExit(status)
    return status

with tempfile.TemporaryDirectory(prefix='sigil-sidebar-host-') as temporary:
    work = Path(temporary)
    home = work / 'home'
    for folder in ('tmp', '.codex', '.claude', '.grok', 'cache', 'config', 'bin'):
        (home / folder).mkdir(parents=True, exist_ok=True)
    for provider, version in (('grok', '1.0.40'), ('codex', '0.157.1'), ('claude', '2.1.283')):
        executable = home / 'bin' / provider
        executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{version}"\n')
        executable.chmod(0o700)
    shell = home / 'bin' / 'sigil-fixture-shell'
    shell.write_text('#!/bin/sh\nexit 0\n')
    shell.chmod(0o700)
    isolated = {
        'HOME': str(home), 'CFFIXED_USER_HOME': str(home),
        'CODEX_HOME': str(home / '.codex'), 'CLAUDE_CONFIG_DIR': str(home / '.claude'),
        'GROK_HOME': str(home / '.grok'), 'TMPDIR': str(home / 'tmp') + '/',
        'XDG_CACHE_HOME': str(home / 'cache'), 'XDG_CONFIG_HOME': str(home / 'config'),
        'PATH': f'{home / "bin"}:/usr/bin:/bin:/usr/sbin:/sbin', 'SHELL': str(shell),
    }
    if about_only:
        diagnostic_input = home / 'about-activation.log'
        isolated['SIGIL_ABOUT_DIAGNOSTIC_LOG'] = str(diagnostic_input)
    environment = os.environ.copy()
    environment.update(isolated)
    derived = work / 'DerivedData'
    run([
        'xcodebuild', '-project', str(root / 'Tests/SidebarHost/SigilSidebarHost.xcodeproj'),
        '-scheme', 'SigilSidebarHost', '-destination', f'platform=macOS,arch={platform.machine()}',
        '-derivedDataPath', str(derived), '-disableAutomaticPackageResolution', '-jobs', '2',
        'build-for-testing', '-quiet',
    ], environment, 900)
    products = derived / 'Build/Products'
    test_runs = list(products.glob('*.xctestrun'))
    if about_only:
        checked_product_path(products, derived)
        candidates = []
        for parent, directories, _ in os.walk(products, followlinks=False):
            candidates.extend(str((Path(parent) / name).relative_to(derived))
                              for name in directories if name.endswith(('.app', '.xctest')))
        provenance.update(stage='products-discovered', productCandidates=sorted(candidates),
                          xctestrunCandidates=[str(path.relative_to(derived)) for path in test_runs])
        (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')
    if len(test_runs) != 1:
        raise SystemExit(f'Expected one built test run, found {len(test_runs)}.')
    test_run = test_runs[0]
    if about_only:
        checked_product_path(test_run, derived)
        (artifacts / 'about.xctestrun').write_bytes(test_run.read_bytes())
    parameters = plistlib.loads(test_run.read_bytes())
    version = parameters['__xctestrun_metadata__']['FormatVersion']
    if version == 2:
        targets = [(target['BlueprintName'], target)
                   for configuration in parameters['TestConfigurations']
                   for target in configuration['TestTargets']]
    elif version == 1:
        # Schemes without a test plan produce the original keyed-target format.
        targets = [(name, target) for name, target in parameters.items()
                   if name != '__xctestrun_metadata__']
    else:
        raise SystemExit(f'Unsupported xctestrun format: {version}')
    if len(targets) != 1 or targets[0][0] != 'SigilSidebarHostTests':
        raise SystemExit('Expected only the sidebar app-hosted fixture target.')
    target = targets[0][1]
    if about_only:
        provenance.update(stage='paths-recorded', testHostPath=target.get('TestHostPath'),
                          testBundlePath=target.get('TestBundlePath'))
        (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')
    if 'SigilSidebarFixtureHost.app' not in target['TestHostPath']:
        raise SystemExit('The fixture must run inside the isolated SwiftUI app host.')
    # Documented xctestrun EnvironmentVariables apply to the actual test host process.
    target.setdefault('EnvironmentVariables', {}).update(isolated)
    test_run.write_bytes(plistlib.dumps(parameters))
    if about_only:
        require_clean_source(expected)
        (artifacts / 'about.xctestrun').write_bytes(test_run.read_bytes())
        identities = {}
        try:
            bundles = resolve_product_bundles(target, test_run, derived)
            provenance['resolvedProductPaths'] = {name: str(path) for name, path in bundles.items()}
            (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')
            for bundle, path in bundles.items():
                info = plistlib.loads(checked_product_path(path / 'Contents/Info.plist', derived).read_bytes())
                name = info['CFBundleExecutable']
                if not isinstance(name, str) or name in ('', '.', '..') or Path(name).name != name:
                    raise ValueError('Invalid diagnostic product executable.')
                binary = checked_product_path(path / 'Contents/MacOS' / name, derived)
                if not binary.is_file():
                    raise ValueError('Diagnostic product executable is not a regular file.')
                identities[bundle] = {'path': str(binary.relative_to(derived)), 'sha256': digest(binary)}
        except (KeyError, OSError, ValueError) as error:
            provenance.update(stage='product-path-failed', error=str(error))
            (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')
            raise SystemExit(f'Diagnostic product resolution failed: {error}')
        provenance.update(stage='built-source-pinned', products=identities,
                          testHostPath=target['TestHostPath'], testBundlePath=target['TestBundlePath'],
                          xctestrunSHA256=digest(test_run))
        (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')
    if build_only:
        print('Sidebar host: build-for-testing and app-host configuration passed; no app or test was launched.')
    else:
        if not about_only:
            artifacts = Path(os.environ.get('SIGIL_SIDEBAR_ARTIFACTS', root / '.build/sidebar-host-verification'))
            artifacts.mkdir(parents=True, exist_ok=True)
        # Run each suite separately so the existing exact-six sidebar gate is
        # unchanged and the new About check has its own mandatory one-case gate.
        suites = (
            ('SidebarVersionNoticeTests', 'sidebar-host', validate),
            ('AboutBuildIdentityHostTests', 'about-host', validate_about),
        )
        if about_only:
            suites = (suites[1],)
        for suite, prefix, validator in suites:
            result = artifacts / f'{prefix}-{time.time_ns()}.xcresult'
            test_status = run([
                'xcodebuild', '-xctestrun', str(test_run), '-destination', f'platform=macOS,arch={platform.machine()}',
                '-only-testing:SigilSidebarHostTests/' + suite,
                '-parallel-testing-enabled', 'NO',
                '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '120',
                '-resultBundlePath', str(result), 'test-without-building', '-quiet',
            ], environment, 240, require_success=False)
            summary = json.loads(subprocess.check_output([
                'xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)
            ], env=environment, timeout=30))
            print(json.dumps(summary, indent=2))
            tree = json.loads(subprocess.check_output([
                'xcrun', 'xcresulttool', 'get', 'test-results', 'tests', '--path', str(result)
            ], env=environment, timeout=30))
            if about_only:
                (artifacts / 'about-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
                (artifacts / 'about-tests.json').write_text(json.dumps(tree, indent=2) + '\n')
                if diagnostic_input.is_file():
                    if diagnostic_input.is_symlink() or diagnostic_input.stat().st_size > 65536:
                        raise SystemExit('Invalid About activation trace.')
                    diagnostic_log.write_bytes(diagnostic_input.read_bytes())
                require_clean_source(expected)
                for product in identities.values():
                    if digest(checked_product_path(derived / product['path'], derived)) != product['sha256']:
                        raise SystemExit('A diagnostic product changed after testing.')
            try:
                outcome = validator(summary, tree, test_status)
            except ValueError as error:
                raise SystemExit(f'{error}: {summary}')
            if about_only:
                if not diagnostic_log.is_file():
                    raise SystemExit('The passing About diagnostic did not retain its activation trace.')
                provenance.update(stage='validated-exact-one-pass', testExit=test_status,
                                  activationLogSHA256=digest(diagnostic_log))
                (artifacts / 'about-source.json').write_text(json.dumps(provenance, indent=2) + '\n')
            print(f'{suite}: {outcome}. Evidence: {result}')
PY
