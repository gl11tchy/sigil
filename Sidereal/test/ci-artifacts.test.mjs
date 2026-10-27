import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename, relative, isAbsolute, normalize } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const workflow = readFileSync(new URL('../../.github/workflows/github-hosted-ci.yml', import.meta.url), 'utf8');
const steps = workflow.split('\n      - name: ').slice(1);
const step = name => steps.find(block => block.split('\n')[0] === name);

test('REA-1202 request identities are retained with browser screenshots on failure', () => {
  const upload = step('Upload Sidereal browser screenshots');
  assert.match(upload, /\n        if: always\(\)\n/);
  assert.match(upload, /\n          retention-days: 7\n/);
  const paths = upload.match(/\n          path: \|\n((?:            [^\n]+\n)+)/)?.[1]
    .trim().split('\n').map(path => path.trim());
  assert.deepEqual(paths, ['Sidereal/test-results/**/*.png', 'Sidereal/test-results/**/short-return-identities.json']);
});

test('public fork verification uses a disposable hosted runner without a write credential or secrets', () => {
  assert.match(workflow, /^permissions:\n  contents: read\n/m);
  const verify = workflow.split('\n  verify:\n')[1]?.split('\n  release:\n')[0];
  assert.ok(verify);
  assert.match(verify, /\n    runs-on: macos-26\n/);
  assert.match(verify, /DEVELOPER_DIR: \/Applications\/Xcode_26\.6\.app\/Contents\/Developer/);
  assert.match(verify, /Expected Xcode 26\.6/);
  assert.match(verify, /SIGIL_RUNNER_ENVIRONMENT: \$\{\{ runner\.environment \}\}/);
  assert.match(verify, /if \[\[ "\$SIGIL_RUNNER_ENVIRONMENT" != github-hosted \]\]; then/);
  assert.doesNotMatch(verify, /github\.event\.pull_request\.head\.repo\.full_name/);
  assert.match(verify, /persist-credentials: false/);
  assert.doesNotMatch(verify, /contents: write|secrets(?:\.|\[)|GH_TOKEN:|GITHUB_TOKEN:|gh release/);
});

test('REA-1224 publishing has its own main-push job and exact artifact boundary', () => {
  const release = workflow.split('\n  release:\n')[1];
  assert.ok(release, 'publication still runs with PR verification');
  assert.match(release, /needs: verify/);
  assert.match(release, /\n    runs-on: ubuntu-latest\n/);
  assert.match(release, /SIGIL_RUNNER_ENVIRONMENT: \$\{\{ runner\.environment \}\}/);
  assert.match(release, /if \[\[ "\$SIGIL_RUNNER_ENVIRONMENT" != github-hosted \]\]; then/);
  assert.match(release, /if: github\.event_name == 'push' && github\.ref == 'refs\/heads\/main'/);
  assert.match(release, /permissions:\n      contents: write/);
  assert.match(release, /artifact-ids: .*needs\.verify\.outputs\.artifact_id/);
  assert.match(release, /EXPECTED_ZIP_SHA256: .*needs\.verify\.outputs\.zip_sha256/);
  assert.match(release, /persist-credentials: false/);
  assert.equal((workflow.match(/contents: write/g) || []).length, 1);
});

test('restored result bundles are removed before any check without deleting build caches', t => {
  const cleanup = step('Clear restored native verification evidence');
  assert.ok(cleanup);
  assert.equal(steps.indexOf(cleanup), steps.indexOf(step('Restore Swift build cache')) + 1);
  assert.match(cleanup, /\n        if: always\(\)\n/);
  assert.ok(steps.indexOf(cleanup) < steps.indexOf(step('Verify')));
  const directory = mkdtempSync(join(tmpdir(), 'sigil-ci-artifacts-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  mkdirSync(join(directory, '.build/native-verification/stale.xcresult'), { recursive: true });
  writeFileSync(join(directory, '.build/keep-cache'), 'build cache');
  const command = cleanup.match(/\n        run: ([^\n]+)/)?.[1];
  assert.ok(command);
  execFileSync('bash', ['-e', '-c', command], { cwd: directory });
  assert.equal(existsSync(join(directory, '.build/native-verification')), false);
  assert.equal(existsSync(join(directory, '.build/keep-cache')), true);
});

test('native result uploads are isolated from build caches and other run attempts', () => {
  const producerStep = step('iPhone app, shipping extensions, and native relay tests');
  const output = producerStep.match(/\n          SIGIL_NATIVE_ARTIFACTS: (.+)\n/)?.[1];
  const upload = step('Upload native verification evidence');
  const path = upload.match(/\n          path: (.+)\n/)?.[1];
  assert.ok(output);
  assert.ok(path);
  assert.match(producerStep, /\n        id: native_verification\n/);
  assert.match(upload, /\n        if: always\(\) && steps\.native_verification\.outcome != 'skipped'\n/);
  assert.match(upload, /\n          if-no-files-found: error\n/);
  const condition = upload.match(/\n        if: (.+)\n/)?.[1];
  const runs = new Function('steps', 'always', `return (${condition})`);
  for (const outcome of ['success', 'failure', 'cancelled', 'skipped']) {
    assert.equal(runs({ native_verification: { outcome } }, () => true), outcome !== 'skipped');
  }
  assert.match(upload, /\n          retention-days: 7\n/);
  const render = (value, run, attempt) => value.replace(/\$\{\{ ([^}]+) \}\}/g, (_, context) => {
    const contexts = { 'runner.temp': '/tmp/sigil-ci-results', 'github.run_id': run, 'github.run_attempt': attempt };
    assert.ok(Object.hasOwn(contexts, context), `Unexpected context: ${context}`);
    return contexts[context];
  });
  const first = render(output, '100', '1');
  assert.equal(dirname(render(path, '100', '1')), first);
  assert.equal(basename(render(path, '100', '1')), '*.xcresult');
  assert.notEqual(first, render(output, '101', '1'));
  assert.notEqual(first, render(output, '100', '2'));
  assert.ok(first.startsWith('/tmp/sigil-ci-results/'));
  const cached = relative('/workspace/.build', first);
  assert.ok(cached.startsWith('..') || isAbsolute(cached));
  const producer = readFileSync(new URL('../../iOS/scripts/native-test.sh', import.meta.url), 'utf8');
  assert.match(producer, /ARTIFACTS="\$\{SIGIL_NATIVE_ARTIFACTS:-/);
});

test('app downloads are retained before a separate publisher, including manual runs and publish failure', () => {
  const upload = step('Upload app zip');
  const publish = step('Publish latest GitHub Release');
  assert.match(upload, /\n          retention-days: 7\n/);
  assert.ok(steps.indexOf(upload) < steps.indexOf(publish));
  assert.match(step('Zip the app'), /\n        id: zip_app\n/);
  assert.match(upload, /\n        id: app_artifact\n/);
  assert.match(upload, /name: Sigil\.app-.*github\.run_id.*github\.run_attempt/);
  assert.match(upload, /dist\/Sigil\.zip\n            dist\/release\.json/);
  assert.doesNotMatch(upload, /overwrite:|publish_release/);
  const condition = upload.match(/\n        if: \$\{\{ (.+) \}\}/)?.[1];
  assert.ok(condition);
  const runs = new Function('steps', 'cancelled', 'return (' + condition + ')');
  for (const [zip, metadata, cancelled, expected] of [
    ['success', 'success', false, true],
    ['failure', 'skipped', false, false],
    ['success', 'failure', false, false],
    ['skipped', 'skipped', false, false],
    ['success', 'success', true, false],
  ]) {
    assert.equal(runs({ zip_app: { outcome: zip }, release_metadata: { outcome: metadata } }, () => cancelled), expected);
  }
  const verify = workflow.split('\n  verify:\n')[1].split('\n  release:\n')[0];
  const release = workflow.split('\n  release:\n')[1];
  const verifyIf = verify.match(/\n    if: (.+)\n/)?.[1];
  const releaseIf = release.match(/\n    if: (.+)\n/)?.[1];
  assert.equal(verifyIf, undefined, 'hosted verification must not filter fork PRs');
  // A job without an if condition runs on every admitted event.
  const allowed = expression => new Function('github', 'return (' + (expression ?? 'true') + ')');
  const github = (event, ref, repository) => ({
    event_name: event, ref, repository: 'fixture/sigil',
    event: { pull_request: { head: { repo: { full_name: repository } } } },
  });
  for (const [event, ref, repository, verifies, publishes] of [
    ['push', 'refs/heads/main', 'fixture/sigil', true, true],
    ['push', 'refs/heads/feature', 'fixture/sigil', true, false],
    ['workflow_dispatch', 'refs/heads/main', 'fixture/sigil', true, false],
    ['workflow_dispatch', 'refs/heads/feature', 'fixture/sigil', true, false],
    ['pull_request', 'refs/pull/1/merge', 'fixture/sigil', true, false],
    ['pull_request', 'refs/pull/2/merge', 'outside/fork', true, false],
  ]) {
    const context = github(event, ref, repository);
    assert.equal(allowed(verifyIf)(context), verifies);
    assert.equal(allowed(releaseIf)(context), publishes);
  }
  assert.match(release, /ref: .*github\.sha/);
  assert.match(release, /merge-multiple: true/);
  assert.doesNotMatch(release, /Scripts\/(verify|build-app|smoke-launch)\.sh|npm |swift build|swift test/);
});


test('the exact release bundle must survive smoke launch before zip or publication', () => {
  const build = step('Build release bundle');
  const smoke = step('Smoke-launch release bundle');
  const zip = step('Zip the app');
  const publish = step('Publish latest GitHub Release');
  assert.ok(smoke, 'release bundle currently goes straight from build to zip');
  assert.equal(steps.indexOf(smoke), steps.indexOf(build) + 1);
  assert.equal(steps.indexOf(zip), steps.indexOf(smoke) + 1);
  const condition = block => block.match(/\n        if: (.+)\n/)?.[1];
  assert.equal(condition(smoke), condition(build));
  assert.equal(condition(zip), condition(build));
  assert.equal(condition(smoke), undefined, 'release architecture/smoke checks also gate PRs');
  assert.doesNotMatch(smoke, /continue-on-error|always\(/);
  assert.match(smoke, /run: Scripts\/smoke-launch.sh dist\/Sigil.app\n/);
  assert.match(zip, /run: ditto -c -k --keepParent dist\/Sigil.app dist\/Sigil.zip\n/);
  assert.match(workflow.split('\n  release:\n')[1], /if: github.event_name == 'push' && github.ref == 'refs\/heads\/main'\n/);
  assert.match(publish, /run: python3 Scripts\/ci-release\.py publish release/);
  const verify = readFileSync(new URL('../../Scripts/verify.sh', import.meta.url), 'utf8');
  assert.match(verify, /"\$SCRIPT_DIR\/smoke-launch.sh" "\$APP"/);
  assert.doesNotMatch(verify, /SIGIL_SMOKE_TEST=1/);
});

test('smoke helper isolates a generated bundle, stops it and preserves its bytes', t => {
  const helper = fileURLToPath(new URL('../../Scripts/smoke-launch.sh', import.meta.url));
  assert.ok(existsSync(helper), 'shared smoke helper is missing');
  const root = mkdtempSync(join(tmpdir(), 'sigil-smoke-fixture-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const app = join(root, 'bundle with spaces', 'Sigil.app');
  const bin = join(app, 'Contents/MacOS/Sigil');
  mkdirSync(dirname(bin), { recursive: true });
  const receipt = join(root, 'receipt');
  const stopped = join(root, 'stopped');
  writeFileSync(bin, `#!/bin/bash
set -eu
printf '%s\\n' "$HOME" "$CFFIXED_USER_HOME" "$GROK_HOME" "$TMPDIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$SIGIL_SMOKE_TEST" "$1" "$PWD" > "$SIGIL_FIXTURE_RECEIPT"
trap 'printf stopped > "$SIGIL_FIXTURE_STOPPED"; exit 0' TERM
while :; do sleep 0.1; done
`, { mode: 0o755 });
  const hash = () => createHash('sha256').update(readFileSync(bin)).digest('hex');
  const before = hash();
  const result = spawnSync('bash', [helper, relative(root, app)], {
    cwd: root, encoding: 'utf8', timeout: 15000,
    env: { ...process.env, SIGIL_FIXTURE_RECEIPT: receipt, SIGIL_FIXTURE_STOPPED: stopped },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /alive after 3s/);
  assert.ok(result.stdout.includes(before), 'receipt identifies the launched executable');
  const [home, fixed, grok, tmp, cache, config, flag, arg, cwd] = readFileSync(receipt, 'utf8').trim().split('\n');
  assert.notEqual(home, process.env.HOME);
  assert.equal(fixed, home);
  for (const path of [grok, tmp, cache, config]) assert.equal(normalize(dirname(path)), normalize(home));
  assert.equal(flag, '1');
  assert.equal(arg, '--smoke-test');
  assert.equal(cwd, normalize(home));
  assert.equal(existsSync(home), false, 'temporary smoke state is removed');
  assert.equal(readFileSync(stopped, 'utf8'), 'stopped');
  assert.equal(hash(), before);
});

test('an early clean exit fails the release gate and retains crash output', t => {
  const helper = fileURLToPath(new URL('../../Scripts/smoke-launch.sh', import.meta.url));
  assert.ok(existsSync(helper), 'shared smoke helper is missing');
  const root = mkdtempSync(join(tmpdir(), 'sigil-smoke-exit-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const app = join(root, 'Sigil.app');
  const bin = join(app, 'Contents/MacOS/Sigil');
  mkdirSync(dirname(bin), { recursive: true });
  const receipt = join(root, 'home');
  writeFileSync(bin, '#!/bin/bash\nprintf "%s" "$HOME" > "$SIGIL_FIXTURE_RECEIPT"\necho generated-startup-failure >&2\nexit 0\n', { mode: 0o755 });
  const zip = join(root, 'zipped');
  const release = join(root, 'published');
  const result = spawnSync('bash', ['-e', '-c', 'bash "$1" "$2"\ntouch "$3"\ntouch "$4"', 'fixture', helper, app, zip, release], {
    encoding: 'utf8', timeout: 15000, env: { ...process.env, SIGIL_FIXTURE_RECEIPT: receipt },
  });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /generated-startup-failure/);
  assert.match(result.stderr, /exited during the smoke check/);
  assert.equal(existsSync(readFileSync(receipt, 'utf8')), false);
  assert.equal(existsSync(zip), false);
  assert.equal(existsSync(release), false);
});

test('smoke helper rejects invalid input before creating smoke state', t => {
  const helper = fileURLToPath(new URL('../../Scripts/smoke-launch.sh', import.meta.url));
  const root = mkdtempSync(join(tmpdir(), 'sigil-smoke-invalid-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const app = join(root, 'MissingExecutable.app');
  mkdirSync(app);
  for (const args of [[], [root], [app], [app, app]]) {
    const result = spawnSync('bash', [helper, ...args], { encoding: 'utf8', timeout: 5000 });
    assert.equal(result.error, undefined);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /usage:|executable is missing/);
    assert.doesNotMatch(result.stderr, /unbound variable/);
  }
});

test('smoke launch refuses an executable that changed while running', t => {
  const helper = fileURLToPath(new URL('../../Scripts/smoke-launch.sh', import.meta.url));
  const root = mkdtempSync(join(tmpdir(), 'sigil-smoke-mutated-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const app = join(root, 'Sigil.app');
  const bin = join(app, 'Contents/MacOS/Sigil');
  mkdirSync(dirname(bin), { recursive: true });
  writeFileSync(bin, '#!/bin/bash\necho "# mutation" >> "$0"\ntrap "exit 0" TERM\nwhile :; do sleep 0.1; done\n', { mode: 0o755 });
  const result = spawnSync('bash', [helper, app], { encoding: 'utf8', timeout: 15000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /executable changed during the smoke check/);
});
