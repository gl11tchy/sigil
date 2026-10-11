import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, basename, relative, isAbsolute } from 'node:path';
import { execFileSync } from 'node:child_process';

const workflow = readFileSync(new URL('../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const steps = workflow.split('\n      - name: ').slice(1);
const step = name => steps.find(block => block.split('\n')[0] === name);

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

test('app downloads survive manual runs and failed release publishing without duplicating releases', () => {
  const upload = step('Upload app zip');
  const publish = step('Publish latest GitHub Release');
  assert.match(upload, /\n          retention-days: 7\n/);
  assert.ok(steps.indexOf(publish) < steps.indexOf(upload));
  assert.match(step('Zip the app'), /\n        id: zip_app\n/);
  assert.match(publish, /\n        id: publish_release\n/);
  const condition = upload.match(/\n        if: \$\{\{ (.+) \}\}/)?.[1];
  assert.ok(condition);
  const runs = new Function('steps', 'cancelled', `return (${condition})`);
  for (const [zip, release, cancelled, expected] of [
    ['success', 'success', false, false],
    ['success', 'skipped', false, true],
    ['success', 'failure', false, true],
    ['failure', 'skipped', false, false],
    ['skipped', 'skipped', false, false],
    ['success', 'failure', true, false],
  ]) {
    assert.equal(runs({ zip_app: { outcome: zip }, publish_release: { outcome: release } }, () => cancelled), expected);
  }
});
