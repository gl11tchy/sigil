#!/usr/bin/env bash
# Build locally with --build-only. Window-opening hosted tests execute only in CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-test}"
if [[ "$MODE" != --build-only && "$MODE" != test ]]; then
  echo "Usage: $0 [--build-only]" >&2
  exit 2
fi
if [[ "$MODE" == test && "${CI:-}" != true ]]; then
  echo "Sidebar app-hosted tests require CI; use --build-only locally." >&2
  exit 2
fi

python3 - "$ROOT" "$MODE" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import platform
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
build_only = sys.argv[2] == '--build-only'

def run(command, environment, timeout):
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
    if status:
        raise SystemExit(status)

with tempfile.TemporaryDirectory(prefix='sigil-sidebar-host-') as temporary:
    work = Path(temporary)
    home = work / 'home'
    for folder in ('tmp', '.codex', '.claude', '.grok', 'cache', 'config', 'bin'):
        (home / folder).mkdir(parents=True, exist_ok=True)
    for provider, version in (('grok', '1.0.40'), ('codex', '0.157.1'), ('claude', '2.1.283')):
        executable = home / 'bin' / provider
        executable.write_text(f'#!/bin/sh\nprintf "%s\\n" "{version}"\n')
        executable.chmod(0o700)
    isolated = {
        'HOME': str(home), 'CFFIXED_USER_HOME': str(home),
        'CODEX_HOME': str(home / '.codex'), 'CLAUDE_CONFIG_DIR': str(home / '.claude'),
        'GROK_HOME': str(home / '.grok'), 'TMPDIR': str(home / 'tmp') + '/',
        'XDG_CACHE_HOME': str(home / 'cache'), 'XDG_CONFIG_HOME': str(home / 'config'),
        'PATH': f'{home / "bin"}:/usr/bin:/bin:/usr/sbin:/sbin',
    }
    environment = os.environ.copy()
    environment.update(isolated)
    derived = work / 'DerivedData'
    run([
        'xcodebuild', '-project', str(root / 'Tests/SidebarHost/SigilSidebarHost.xcodeproj'),
        '-scheme', 'SigilSidebarHost', '-destination', f'platform=macOS,arch={platform.machine()}',
        '-derivedDataPath', str(derived), '-disableAutomaticPackageResolution', '-jobs', '2',
        'build-for-testing', '-quiet',
    ], environment, 900)
    test_runs = list((derived / 'Build/Products').glob('*.xctestrun'))
    if len(test_runs) != 1:
        raise SystemExit(f'Expected one built test run, found {len(test_runs)}.')
    test_run = test_runs[0]
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
    if 'SigilSidebarFixtureHost.app' not in target['TestHostPath']:
        raise SystemExit('The fixture must run inside the isolated SwiftUI app host.')
    # Documented xctestrun EnvironmentVariables apply to the actual test host process.
    target.setdefault('EnvironmentVariables', {}).update(isolated)
    test_run.write_bytes(plistlib.dumps(parameters))
    if build_only:
        print('Sidebar host: build-for-testing and app-host configuration passed; no app or test was launched.')
    else:
        artifacts = Path(os.environ.get('SIGIL_SIDEBAR_ARTIFACTS', root / '.build/sidebar-host-verification'))
        artifacts.mkdir(parents=True, exist_ok=True)
        result = artifacts / f'sidebar-host-{time.time_ns()}.xcresult'
        run([
            'xcodebuild', '-xctestrun', str(test_run), '-destination', f'platform=macOS,arch={platform.machine()}',
            '-parallel-testing-enabled', 'NO', '-test-iterations', '1',
            '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '120',
            '-resultBundlePath', str(result), 'test-without-building', '-quiet',
        ], environment, 240)
        summary = json.loads(subprocess.check_output([
            'xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result)
        ], env=environment, timeout=30))
        if summary.get('passedTests') != 1 or summary.get('failedTests') != 0 or summary.get('skippedTests') != 0:
            raise SystemExit(f'Expected one passed fixture with no failures or skips: {summary}')
        print(f'Sidebar host: one fixture passed, no retries or skips. Evidence: {result}')
PY
