import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
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

test('app downloads survive manual runs and failed release publishing without duplicating releases', () => {
  const upload = step('Upload app zip');
  const publish = step('Publish latest GitHub Release');
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
